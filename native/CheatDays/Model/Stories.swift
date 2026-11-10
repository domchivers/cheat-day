import AVFoundation
import SwiftUI

/// Stories people post: a photo or a video for 24 hours, with text and food stickers placed on it, for friends only
/// ("Close friends") or friends and followers ("Your story"). On a ring they play before the day from the log.
@Observable @MainActor
final class Stories {
    static let shared = Stories()

    private(set) var all: [JSON] = []      // live stories I can see, oldest first
    private(set) var views: [JSON] = []    // who's watched mine
    private(set) var watched: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "stories.watched") ?? [])
    private(set) var posting = false
    var error: String?
    private var api: Supabase { Supabase.shared }
    var me: String { api.userId ?? "" }

    private func rows(_ path: String, method: String = "GET", body: Any? = nil, prefer: String? = nil) async throws -> [JSON] {
        let d = try await api.rest(path, method: method, body: body, prefer: prefer)
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    func load() async {
        guard !me.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        guard let got = try? await rows("/rest/v1/stories?expires_at=gt.\(now)&select=*&order=created_at.asc&limit=300") else { return }
        all = got
        let mine = got.filter { str($0["owner"]) == me }.map { str($0["id"]) }
        views = mine.isEmpty ? [] : ((try? await rows("/rest/v1/story_views?story_id=in.(\(mine.joined(separator: ",")))&select=*&order=created_at.desc")) ?? [])
        await Profiles.shared.load(got.map { str($0["owner"]) } + views.map { str($0["viewer"]) })
    }

    func of(_ id: String) -> [JSON] { all.filter { str($0["owner"]) == id } }
    func unwatched(_ id: String) -> Bool { of(id).contains { !watched.contains(str($0["id"])) } }
    func viewers(_ story: JSON) -> [JSON] { views.filter { str($0["story_id"]) == str(story["id"]) } }

    /// Seen: theirs hear about it in "Seen by", and the ring goes grey once all are watched.
    func watch(_ story: JSON) {
        let id = str(story["id"])
        guard !watched.contains(id) else { return }
        watched.insert(id); UserDefaults.standard.set(Array(watched.suffix(500)), forKey: "stories.watched")
        guard str(story["owner"]) != me else { return }
        Task { _ = try? await api.rest("/rest/v1/story_views", method: "POST", body: [["story_id": id, "viewer": me]], prefer: "resolution=ignore-duplicates") }
    }

    func react(_ story: JSON, _ emoji: String) async {
        let id = str(story["id"])
        _ = try? await api.rest("/rest/v1/story_views", method: "POST", body: [["story_id": id, "viewer": me, "reaction": emoji]], prefer: "resolution=merge-duplicates")
    }

    func delete(_ story: JSON) async {
        _ = try? await api.rest("/rest/v1/stories?id=eq.\(str(story["id"]))&owner=eq.\(me)", method: "DELETE")
        all.removeAll { str($0["id"]) == str(story["id"]) }
    }

    /// Upload the picture or video, then the story with its overlays.
    func post(image: UIImage?, video: URL?, overlays: [JSON], audience: String) async -> Bool {
        posting = true; defer { posting = false }
        do {
            var row: JSON = ["owner": me, "overlays": overlays, "audience": audience]
            if let video {
                let (data, seconds) = try await Self.compress(video)
                row["kind"] = "video"; row["seconds"] = seconds
                row["media"] = try await api.upload(data, ext: "mp4", type: "video/mp4")
            } else if let image, let jpeg = Feed.prepare(image) {
                row["kind"] = "photo"; row["media"] = try await api.uploadPhoto(jpeg)
            } else { return false }
            let made = try await rows("/rest/v1/stories", method: "POST", body: [row], prefer: "return=representation")
            all += made
            made.forEach { watched.insert(str($0["id"])) }   // your own don't light your ring
            error = nil
            return true
        } catch {
            self.error = "Couldn't post your story: stories need setting up (supabase/stories.sql), or the photos bucket doesn't take videos yet."
            return false
        }
    }

    /// A video as a smaller mp4, at most 30 seconds, and how long it is.
    static func compress(_ url: URL) async throws -> (Data, Double) {
        let asset = AVURLAsset(url: url)
        let length = min(30, (try? await asset.load(.duration).seconds) ?? 15)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return (try Data(contentsOf: url), length) }
        export.outputURL = out; export.outputFileType = .mp4; export.shouldOptimizeForNetworkUse = true
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
        await export.export()
        defer { try? FileManager.default.removeItem(at: out) }
        return (try Data(contentsOf: export.status == .completed ? out : url), length)
    }
}

/// A video that plays on its own, filling its frame, without controls: stories.
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    var paused = false
    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.playerLayer.player = AVPlayer(url: url)
        v.playerLayer.player?.play()
        return v
    }
    func updateUIView(_ v: PlayerView, context: Context) {
        if (v.playerLayer.player?.currentItem?.asset as? AVURLAsset)?.url != url { v.playerLayer.player = AVPlayer(url: url) }
        if paused { v.playerLayer.player?.pause() } else { v.playerLayer.player?.play() }
    }
    static func dismantleUIView(_ v: PlayerView, coordinator: ()) { v.playerLayer.player?.pause() }
}

/// What's placed on a story: text, or a food sticker (name, calories, protein), at a spot given as fractions of the
/// picture so it lands in the same place on any phone.
struct StoryOverlays: View {
    let items: [JSON]
    var body: some View {
        GeometryReader { g in
            ForEach(items.indices, id: \.self) { i in
                let o = items[i]
                Self.view(o)
                    .scaleEffect(num(o["scale"]) ?? 1)
                    .position(x: (num(o["x"]) ?? 0.5) * g.size.width, y: (num(o["y"]) ?? 0.5) * g.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder static func view(_ o: JSON) -> some View {
        if str(o["type"]) == "food" {
            VStack(alignment: .leading, spacing: 2) {
                Text(str(o["name"])).font(.subheadline.weight(.heavy)).foregroundStyle(.black).lineLimit(2)
                (Text("\(Fmt.int(num(o["kcal"]) ?? 0)) kcal") + Text(num(o["p"]).map { " · \(Int($0)) g protein" } ?? "").foregroundStyle(Color(red: 0.12, green: 0.6, blue: 0.34)))
                    .font(.caption.weight(.bold)).foregroundStyle(Color(white: 0.35))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .rotationEffect(.degrees(-4)).shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            .frame(maxWidth: 240)
        } else {
            Text(str(o["text"])).font(.system(size: 28, weight: .heavy)).foregroundStyle(.white).multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.7), radius: 6).frame(maxWidth: 300)
        }
    }
}
