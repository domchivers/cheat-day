import AVFoundation
import SwiftUI

/// Stories people post: a photo or a video for 24 hours, with text and food stickers placed on it, for friends only
/// ("Friends only") or friends and followers ("Your story"). On a ring they play before the day from the log.
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
        // carries on for a while if the app's left (see Feed.send)
        let keep = KeepAlive("Story")
        defer { keep.end() }
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
    /// Crop is the part of the picture to keep, as fractions of it from the top left (a post's video, zoomed and moved in the editor).
    static func compress(_ url: URL, filter: String = "Normal", range: ClosedRange<Double>? = nil, muted: Bool = false, crop: CGRect? = nil, overlay: UIImage? = nil, turns: Int = 0, placed: ClipEdit? = nil) async throws -> (Data, Double) {
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
        let quarter = ((turns % 4) + 4) % 4   // quarter turns to the right
        let spun = placed.flatMap { $0.loose ? $0 : nil }   // turned freely: laid into its frame, not cut from the picture
        if crop != nil || overlay != nil || quarter != 0 || spun != nil {
            let crop = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            // text, stickers and drawing: one see-through picture, stretched over the part kept
            let top = overlay.flatMap { CIImage(image: $0) }
            // the picture the right way up, and the piece of it kept, in its pixels (Core Image counts up from the bottom)
            var size = CGSize.zero
            if let v = try? await comp.loadTracks(withMediaType: .video).first {
                let n = (try? await v.load(.naturalSize)) ?? .zero, t = (try? await v.load(.preferredTransform)) ?? .identity
                let r = CGRect(origin: .zero, size: n).applying(t)
                size = CGSize(width: abs(r.width), height: abs(r.height))
            }
            if quarter % 2 == 1 { size = CGSize(width: size.height, height: size.width) }
            var area = CGRect(x: crop.minX * size.width, y: (1 - crop.maxY) * size.height, width: crop.width * size.width, height: crop.height * size.height).integral
            var laying: CGAffineTransform?
            if let e = spun, size.width > 0, size.height > 0 {
                // the frame, in the picture's own pixels at its plain size (no more than 1280 on its longer side)
                let own = size.width / size.height, shape = e.shape ?? own
                let fw = shape > own ? size.width : size.height * shape
                let cap = min(1, 1280 / max(fw, fw / shape))
                let w = (fw * cap / 2).rounded(.down) * 2, h = (fw / shape * cap / 2).rounded(.down) * 2
                area = CGRect(x: 0, y: 0, width: w, height: h)
                // from its middle: made its size, turned (to the right is backwards here), carried to its place (down is backwards too)
                laying = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                    .concatenating(CGAffineTransform(scaleX: cap * e.zoom, y: cap * e.zoom))
                    .concatenating(CGAffineTransform(rotationAngle: -CGFloat(e.spin) * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: w / 2 + e.move.width * w, y: h / 2 - e.move.height * h))
            }
            let cut = area, lay = laying
            if cut.width >= 16, cut.height >= 16 {
                let vc = AVMutableVideoComposition(asset: comp) { req in
                    var img = req.sourceImage
                    if quarter != 0 {
                        // turned (to the right is backwards to Core Image, which counts up), then slid back to the corner
                        img = img.transformed(by: CGAffineTransform(rotationAngle: -CGFloat.pi / 2 * CGFloat(quarter)))
                        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                    }
                    let whole = img.extent
                    if filter != "Normal" { img = StoryArt.filtered(img.clampedToExtent(), filter, frame: whole).cropped(to: whole) }
                    var done = img.cropped(to: cut).transformed(by: CGAffineTransform(translationX: -cut.minX, y: -cut.minY))
                    if let lay { done = img.transformed(by: lay).cropped(to: cut).composited(over: CIImage(color: .black).cropped(to: cut)) }
                    if let top, top.extent.width > 0, top.extent.height > 0 {
                        done = top.transformed(by: CGAffineTransform(scaleX: cut.width / top.extent.width, y: cut.height / top.extent.height)).composited(over: done)
                    }
                    req.finish(with: done, context: nil)
                }
                vc.renderSize = CGSize(width: (cut.width / 2).rounded(.down) * 2, height: (cut.height / 2).rounded(.down) * 2)   // even, as the encoder wants
                export.videoComposition = vc
            }
        } else if filter != "Normal" {
            export.videoComposition = AVVideoComposition(asset: comp) { req in
                req.finish(with: StoryArt.filtered(req.sourceImage.clampedToExtent(), filter, frame: req.sourceImage.extent).cropped(to: req.sourceImage.extent), context: nil)
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
    /// A moment to hold on, in seconds: the clip stops there while a finger looks through it, and plays on from
    /// there once this is nil again.
    var scrub: Double? = nil
    /// The editor's clip: its frames go through the look from the very start, even while the look is "Normal", so
    /// picking the first filter doesn't mean a new player (a black blink and a stutter each time).
    var always = false
    /// The look, kept by whoever shows the clip and changed by them directly: a slider can then change what's
    /// drawn without the screen around the clip being worked out again for every step, which was what stuttered.
    var box: Look? = nil
    /// Told many times a second where the clip has got to and how long it is, in seconds: for a line along the
    /// bottom of the full-screen viewer.
    var tick: ((Double, Double) -> Void)? = nil
    /// How loud its own sound is, from 0 to 1 (a post with a song can have the two set against each other).
    var volume: Float = 1

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
        var key = ""
        var held: Double?
        let look = Look()
        var ender: NSObjectProtocol?   // a clip with a look goes round by being sent back to its start: this hears its end
        var playing = true
        var tick: ((Double, Double) -> Void)?
        var watch: Any?              // the player's own clock, watched for `tick`
        weak var watched: AVPlayer?
        func unwatch() { if let watch, let watched { watched.removeTimeObserver(watch) }; watch = nil; watched = nil }
        deinit { if let ender { NotificationCenter.default.removeObserver(ender) }; unwatch() }
    }

    /// How much smaller than the clip its frames are drawn while it plays with a look (1 for as they are).
    final class Shrink: @unchecked Sendable { var by: CGFloat = 1 }

    /// The look the frames are being drawn through, read by the player for each frame as it comes: a slider can
    /// change it many times a second and the clip just carries on (setting the player up again for each change
    /// started the clip over, which is why Adjust on a video only showed when the finger lifted).
    final class Look: @unchecked Sendable {
        private let lock = NSLock()
        private var value = "Normal"
        var name: String {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        setUp(v)
        return v
    }

    func updateUIView(_ v: PlayerView, context: Context) {
        if box == nil { v.look.name = filter }
        v.playing = !paused && scrub == nil
        v.tick = tick
        if v.key != key { setUp(v) }
        v.playerLayer.player?.isMuted = muted
        if v.playerLayer.player?.volume != volume { v.playerLayer.player?.volume = volume }
        if let at = scrub {
            v.playerLayer.player?.pause()
            // only when the finger has moved on: a seek for every redraw made it stutter
            if v.held.map({ abs($0 - at) > 0.03 }) ?? true {
                v.held = at
                let near = CMTime(seconds: 0.05, preferredTimescale: 600)
                v.playerLayer.player?.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: near, toleranceAfter: near)
            }
            return
        }
        v.held = nil
        // only told to play when it isn't: told again on every redraw, it hitched
        if paused { v.playerLayer.player?.pause() } else if v.playerLayer.player?.rate == 0 { v.playerLayer.player?.play() }
    }

    // whether there's a look at all, not which: going from none to one is the only change that needs a new player
    private var key: String { "\(url.absoluteString)|\(always || filter != "Normal")|\(range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "")" }

    private func setUp(_ v: PlayerView) {
        v.key = key
        // The player before this one, taken right down first. Left to be let go in its own time, its items still
        // held their decoders while the new item tried to get ready, and a phone (and the simulator more so) only
        // has so many: the new one then failed to build its pipeline and the clip froze.
        v.unwatch()
        if let old = v.playerLayer.player {
            old.pause()
            v.looper?.disableLooping(); v.looper = nil
            (old as? AVQueuePlayer)?.removeAllItems()
            old.replaceCurrentItem(with: nil)
            v.playerLayer.player = nil
        }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        if box == nil { v.look.name = filter }
        if always || filter != "Normal" {
            // Every frame goes through the look as it's shown. A phone's video is 4K, eight million dots a frame,
            // and that many through a filter sixty times a second is what made a slider stutter. For looking at
            // in the editor each frame is made small first (1280 on its longer side), a ninth of the work; the
            // video that's posted is still made from the full frames.
            let look = box ?? v.look
            let shrink = Shrink()
            let comp = AVMutableVideoComposition(asset: asset) { req in
                let name = look.name, k = shrink.by
                var img = req.sourceImage
                if k < 1 { img = img.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
                let whole = img.extent
                if name != "Normal" { img = StoryArt.filtered(img.clampedToExtent(), name, frame: whole).cropped(to: whole) }
                req.finish(with: img, context: nil)
            }
            let full = comp.renderSize
            if full.width > 0, full.height > 0 {
                let k = min(1, 1600 / max(full.width, full.height))
                if k < 1 {
                    shrink.by = k
                    comp.renderSize = CGSize(width: max(2, (full.width * k / 2).rounded(.down) * 2), height: max(2, (full.height * k / 2).rounded(.down) * 2))
                }
            }
            item.videoComposition = comp
        }
        if let ender = v.ender { NotificationCenter.default.removeObserver(ender); v.ender = nil }
        // (For a while a clip with a look was one item sent back to its start, a guess at a freeze that turned out
        // to be the simulator's alone; on a phone the looper's copies play it round without a gap.)
        let player = AVQueuePlayer()
        player.isMuted = muted
        player.volume = volume
        if let r = range {
            v.looper = AVPlayerLooper(player: player, templateItem: item, timeRange: CMTimeRange(start: CMTime(seconds: r.lowerBound, preferredTimescale: 600), end: CMTime(seconds: r.upperBound, preferredTimescale: 600)))
        } else {
            v.looper = AVPlayerLooper(player: player, templateItem: item)
        }
        v.playerLayer.player = player
        if tick != nil {
            v.tick = tick
            v.watched = player
            v.watch = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak v, weak player] t in
                guard let length = player?.currentItem?.duration.seconds, length.isFinite, length > 0 else { return }
                v?.tick?(min(length, max(0, t.seconds)), length)
            }
        }
        if !paused { player.play() }
    }

    static func dismantleUIView(_ v: PlayerView, coordinator: ()) { v.unwatch(); v.playerLayer.player?.pause(); v.looper = nil }
}
