import AVFoundation
import SwiftUI

/// Stories people post: a photo or a video for 24 hours, with text and food stickers placed on it, for friends only
/// ("Close friends") or friends and followers ("Your story"). On a ring they play before the day from the log.
@Observable @MainActor
final class Stories {
    static let shared = Stories()

    private(set) var all: [JSON] = []      // live stories I can see, oldest first
    private(set) var views: [JSON] = []    // who's watched mine
    private(set) var votes: [JSON] = []    // poll votes on the stories I can see
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
        let polled = got.filter { list($0["overlays"]).contains { str($0["type"]) == "poll" } }.map { str($0["id"]) }
        votes = polled.isEmpty ? [] : ((try? await rows("/rest/v1/story_poll_votes?story_id=in.(\(polled.joined(separator: ",")))&select=*")) ?? [])
        await Profiles.shared.load(got.map { str($0["owner"]) } + views.map { str($0["viewer"]) })
    }

    func owner(_ story: String) -> String { str(all.first { str($0["id"]) == story }?["owner"]) }

    /// A poll's split, and my answer if I've voted.
    func tally(_ story: String, _ poll: String) -> (a: Int, b: Int, mine: Int?) {
        let v = votes.filter { str($0["story_id"]) == story && str($0["poll"]) == poll }
        let mine = v.first { str($0["voter"]) == me }.flatMap { num($0["choice"]).map(Int.init) }
        return (v.filter { num($0["choice"]) == 0 }.count, v.filter { num($0["choice"]) == 1 }.count, mine)
    }

    func vote(_ story: String, poll: String, _ choice: Int) async {
        guard tally(story, poll).mine == nil else { return }
        votes.append(["story_id": story, "poll": poll, "voter": me, "choice": choice])
        do { _ = try await api.rest("/rest/v1/story_poll_votes", method: "POST", body: [["story_id": story, "poll": poll, "voter": me, "choice": choice]]) }
        catch { votes.removeAll { str($0["story_id"]) == story && str($0["poll"]) == poll && str($0["voter"]) == me }; self.error = "Polls need setting up (supabase/story_polls.sql)." }
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

    /// Take a story down; false if the server didn't (it stays, rather than vanishing here and coming back).
    @discardableResult
    func delete(_ story: JSON) async -> Bool {
        do {
            _ = try await api.rest("/rest/v1/stories?id=eq.\(str(story["id"]))&owner=eq.\(me)", method: "DELETE")
            all.removeAll { str($0["id"]) == str(story["id"]) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Upload the picture (already framed and filtered) or the video (trimmed, filtered, with or without its sound),
    /// then the story with what's placed on it. People mentioned hear about it in your chat.
    func post(image: UIImage?, video: URL?, overlays: [JSON], audience: String, filter: String = "Normal", range: ClosedRange<Double>? = nil, muted: Bool = false) async -> Bool {
        posting = true; defer { posting = false }
        do {
            var row: JSON = ["owner": me, "overlays": overlays, "audience": audience]
            if let video {
                let (data, seconds) = try await Self.compress(video, filter: filter, range: range, muted: muted)
                row["kind"] = "video"; row["seconds"] = seconds
                row["media"] = try await api.upload(data, ext: "mp4", type: "video/mp4")
            } else if let image, let jpeg = Feed.prepare(image) {
                row["kind"] = "photo"; row["media"] = try await api.uploadPhoto(jpeg)
            } else { return false }
            let made = try await rows("/rest/v1/stories", method: "POST", body: [row], prefer: "return=representation")
            all += made
            made.forEach { watched.insert(str($0["id"])) }   // your own don't light your ring
            for m in overlays where str(m["type"]) == "mention" && Friends.shared.people.contains(where: { $0.id == str(m["user"]) }) {
                await Messages.shared.send(to: str(m["user"]), text: "Mentioned you in their story 📸")
            }
            error = nil
            return true
        } catch {
            self.error = "Couldn't post your story: stories need setting up (supabase/stories.sql), or the photos bucket doesn't take videos yet."
            return false
        }
    }

    /// A video as a smaller mp4: the trimmed part (at most 30 seconds), through the filter, with or without sound.
    static func compress(_ url: URL, filter: String = "Normal", range: ClosedRange<Double>? = nil, muted: Bool = false) async throws -> (Data, Double) {
        let asset = AVURLAsset(url: url)
        let full = (try? await asset.load(.duration).seconds) ?? 15
        let start = range?.lowerBound ?? 0, end = min(range?.upperBound ?? full, start + 30)
        let span = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        // the picture, and the sound unless it's off, cut to the part kept
        let comp = AVMutableComposition()
        if let v = try? await asset.loadTracks(withMediaType: .video).first, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try t.insertTimeRange(span, of: v, at: .zero)
            t.preferredTransform = (try? await v.load(.preferredTransform)) ?? .identity
        }
        if !muted, let a = try? await asset.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? t.insertTimeRange(span, of: a, at: .zero)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPreset1280x720) else { return (try Data(contentsOf: url), end - start) }
        export.outputURL = out; export.outputFileType = .mp4; export.shouldOptimizeForNetworkUse = true
        if filter != "Normal" {
            export.videoComposition = AVVideoComposition(asset: comp) { req in
                req.finish(with: StoryArt.filtered(req.sourceImage.clampedToExtent(), filter).cropped(to: req.sourceImage.extent), context: nil)
            }
        }
        await export.export()
        defer { try? FileManager.default.removeItem(at: out) }
        return (try Data(contentsOf: export.status == .completed ? out : url), end - start)
    }
}

/// A video that loops on its own, filling its frame, without controls: in stories and the editor. It can play a
/// trimmed part, silently, and through a filter, so the editor shows what friends will see.
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    var paused = false
    var muted = false
    var filter = "Normal"
    var range: ClosedRange<Double>? = nil

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
        var key = ""
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        setUp(v)
        return v
    }

    func updateUIView(_ v: PlayerView, context: Context) {
        if v.key != key { setUp(v) }
        v.playerLayer.player?.isMuted = muted
        if paused { v.playerLayer.player?.pause() } else { v.playerLayer.player?.play() }
    }

    private var key: String { "\(url.absoluteString)|\(filter)|\(range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "")" }

    private func setUp(_ v: PlayerView) {
        v.key = key
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        if filter != "Normal" {
            let name = filter
            item.videoComposition = AVVideoComposition(asset: asset) { req in
                req.finish(with: StoryArt.filtered(req.sourceImage.clampedToExtent(), name).cropped(to: req.sourceImage.extent), context: nil)
            }
        }
        let player = AVQueuePlayer()
        player.isMuted = muted
        if let r = range {
            v.looper = AVPlayerLooper(player: player, templateItem: item, timeRange: CMTimeRange(start: CMTime(seconds: r.lowerBound, preferredTimescale: 600), end: CMTime(seconds: r.upperBound, preferredTimescale: 600)))
        } else {
            v.looper = AVPlayerLooper(player: player, templateItem: item)
        }
        v.playerLayer.player = player
        if !paused { player.play() }
    }

    static func dismantleUIView(_ v: PlayerView, coordinator: ()) { v.playerLayer.player?.pause(); v.looper = nil }
}
