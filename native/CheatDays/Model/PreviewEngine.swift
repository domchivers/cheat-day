import AVFoundation
import CoreImage
import QuartzCore

/// The clip editor's own player (21 Nov, stage 2 of "build it properly like CapCut"): it plays the edit straight from
/// the clips, as the edit is now, with nothing made in between. Each clip in view has a reader decoding its frames a
/// little ahead; each frame is drawn by EditCompositor.frame, as the finished video's are; every clip's and bar's sound
/// plays through a mixer of its own, its level set as it plays. So an edit changes only what's drawn and heard next:
/// a trim, a split, a filter, a mute or a sound moved shows at once, with nothing made again and nothing to flash.
/// The finished video is still made by ClipJoin.join, as before.
///
/// Called as AVPlayer is (play, pause, rate, seek, currentTime), from the main thread.
final class PreviewEngine {
    // the edit as it is now
    private var clips: [Clip] = []
    private var soundOf: UUID?
    private var look = EditLook()
    private var sounds: [EditSound] = []
    private var pips: [EditPip] = []
    private var swap: [URL: URL] = [:]
    private var starts: [Double] = []
    private(set) var total = 0.0
    /// Whether it's been given an edit yet.
    private(set) var loaded = false
    /// The finished video's size (the first clip's shape, or the shape picked).
    private(set) var frameSize = CGSize(width: 1080, height: 1920)
    var isMuted = false { didSet { mixer.muted = isMuted } }

    /// Told where it's got to, about twenty times a second while it plays.
    var onTime: ((Double) -> Void)?
    /// Told when the finished video's size is known or changes.
    var onSize: ((CGSize) -> Void)?

    // the clock: while it plays, the edit's time is where it started plus how long since
    private var anchorHost = 0.0, anchorTime = 0.0, held = 0.0
    private(set) var rate: Float = 0
    private var lastTold = -1.0

    private var readers: [String: FrameReader] = [:]
    private var info: [URL: (turn: CGImagePropertyOrientation, size: CGSize)] = [:]
    private var asked: Set<URL> = []
    private let mixer = SoundMixer()
    private var audioKey = ""
    private var dirty = true
    private var drawnKey = ""

    init() {
        mixer.onLoaded = { [weak self] in
            guard let self, self.rate != 0 else { return }
            self.restartSound()
        }
        // a call or another app's sound over it, then let go; or the sound's way out changed (headphones): the
        // sound engine started afresh
        let c = NotificationCenter.default
        watching.append(c.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.wake() }
        })
        watching.append(c.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in self?.wake() })
    }

    private var watching: [NSObjectProtocol] = []

    /// The sound engine started afresh (back in the app, after a call): the phone may have stopped it meanwhile, and
    /// a stopped engine still reported running now and then, so it's stopped here and started again as it plays.
    func wake() {
        mixer.reset()
        if rate != 0 { restartSound() }
    }

    // MARK: as AVPlayer is called

    func time(at host: Double = CACurrentMediaTime()) -> Double {
        rate == 0 ? held : min(total, anchorTime + max(0, host - anchorHost))
    }

    func currentTime() -> CMTime { CMTime(seconds: time(), preferredTimescale: 600) }

    func play() {
        guard rate == 0, total > 0.05 else { return }
        let from = held >= total - 0.05 ? 0 : held
        mixer.warm()   // (started before the moment's set: a cold start took longer than the moment)
        let host = CACurrentMediaTime() + 0.05   // (a moment for the sound to be ready to start with the picture)
        anchorHost = host; anchorTime = from; rate = 1
        audioKey = soundKey
        mixer.play(from: from, host: host, pieces: soundPieces())
        dirty = true
    }

    func pause() {
        guard rate != 0 else { return }
        held = time(); rate = 0
        mixer.stop()
        dirty = true
    }

    func seek(to t: CMTime, toleranceBefore: CMTime = .zero, toleranceAfter: CMTime = .zero, completionHandler: ((Bool) -> Void)? = nil) {
        let s = min(max(0, t.seconds.isFinite ? t.seconds : 0), max(0, total))
        if rate != 0 { rate = 0; mixer.stop(); held = s; play() } else { held = s }
        dirty = true
        if let completionHandler { DispatchQueue.main.async { completionHandler(true) } }
    }

    /// Everything let go: the editor's closed.
    func shutdown() {
        pause()
        mixer.shutdown()
        for r in readers.values { r.cancel() }
        readers.removeAll()
        onTime = nil; onSize = nil   // (they hold the editor)
        for w in watching { NotificationCenter.default.removeObserver(w) }
        watching = []
    }

    // MARK: the edit

    func update(clips: [Clip], soundOf: UUID?, look: EditLook, sounds: [EditSound], pips: [EditPip], swap: [URL: URL]) {
        self.clips = clips; self.soundOf = soundOf; self.look = look; self.sounds = sounds; self.pips = pips; self.swap = swap
        starts = ClipJoin.starts(clips)
        total = ClipJoin.total(clips)
        loaded = true
        held = min(held, total)
        for u in Set(clips.map { $0.source } + pips.map { $0.source }) { learn(u) }
        resize()
        dirty = true
        let urls = soundPieces().map { $0.url }
        mixer.prepare(urls)
        // the sound playing made again only if what's heard where has changed (a level is set as it plays)
        if rate != 0, soundKey != audioKey { restartSound() }
    }

    private func restartSound() {
        let host = CACurrentMediaTime() + 0.03
        audioKey = soundKey
        mixer.play(from: time(at: host), host: host, pieces: soundPieces())
    }

    /// Which way up a file's frames go and how big they are, found once.
    private func learn(_ u: URL) {
        guard !asked.contains(u) else { return }
        asked.insert(u)
        Task { @MainActor [weak self] in
            let asset = AVURLAsset(url: u)
            guard let v = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let tf = (try? await v.load(.preferredTransform)) ?? .identity
            let n = (try? await v.load(.naturalSize)) ?? .zero
            self?.info[u] = (EditCompositor.orientation(tf), n.applying(tf))
            self?.resize(); self?.dirty = true
        }
    }

    /// The finished video's size, as ClipJoin.compose works it out.
    private func resize() {
        var size = CGSize(width: 1080, height: 1920)
        if let r = look.ratio {
            size = CGSize(width: 1080, height: (1080 / r / 2).rounded() * 2)
        } else if let first = clips.first, let i = info[first.source] {
            let w = abs(i.size.width), h = abs(i.size.height)
            if w > 0, h > 0 { let k = min(1, 1080 / w); size = CGSize(width: (w * k / 2).rounded() * 2, height: (h * k / 2).rounded() * 2) }
        }
        if size != frameSize { frameSize = size; onSize?(size) }
    }

    // MARK: the picture

    /// The frame to show at `host` (the screen's clock), or nil when there's nothing new to draw (the last one stays
    /// up). While it plays, it also sets the sound's levels and tells the editor where it's got to.
    func picture(host: Double) -> CIImage? {
        guard loaded, !clips.isEmpty else { return nil }
        var t = time(at: host)
        if rate != 0 {
            // round again at the end
            if t >= total - 0.01 { pause(); held = 0; play(); t = 0 }
            mixer.levels(at: t)
            if abs(t - lastTold) >= 0.05 { lastTold = t; onTime?(t) }
        }
        let full = frameSize
        let k = min(1, 720 / max(full.width, 1))   // drawn at most 720 across: the screen's preview is no bigger
        let size = CGSize(width: (full.width * k).rounded(), height: (full.height * k).rounded())
        var key = "\(size)"
        var pics: [(CIImage, EditLayer)] = []
        let showing = clipsAt(t)
        for (i, s) in showing {
            let c = clips[i]
            guard let (pts, px) = reader("c\(c.id)", c.source).frame(at: s) else { return nil }   // (not yet: the last frame stays up)
            key += "|\(i):\(pts)"
            let turn = info[c.source]?.turn ?? .up
            pics.append((CIImage(cvPixelBuffer: px), EditLayer(track: 0, orientation: turn, look: c.look, moves: c.moves, begins: starts[i])))
        }
        var progress: CGFloat = 0, kind: ClipTransition?
        if showing.count == 2 {
            let a = showing[0].0
            kind = clips[a].transition
            let join = max(ClipJoin.overlap(clips, after: a), 0.01)
            progress = CGFloat(min(1, max(0, (t - starts[a + 1]) / join)))
        }
        var over: [(CIImage, PipLayer)] = []
        for p in pips where t >= p.from && t < p.from + p.length {
            guard let (pts, px) = reader("p\(p.id)", p.source).frame(at: p.start + (t - p.from)) else { continue }
            key += "|p:\(pts)"
            let turn = info[p.source]?.turn ?? .up
            over.append((CIImage(cvPixelBuffer: px), PipLayer(track: 0, orientation: turn, from: p.from, to: p.from + p.length,
                                                              base: MoveKey(at: 0, x: p.x, y: p.y, size: p.size, opacity: p.opacity), keys: p.keys)))
        }
        prepareNext(after: t)
        tidy()
        // held still and nothing changed: nothing to draw again
        if rate == 0, !dirty, key == drawnKey { return nil }
        if rate != 0 { key += "|\(t)" }
        dirty = false; drawnKey = key
        // (the picture's moves and keyframes are timed in the finished video's seconds, its size in fractions)
        return EditCompositor.frame(pics, transition: kind, progress: progress, fill: look.fill, pips: over, overlays: [], at: t,
                                    size: size)
    }

    /// The clips showing at `t`, each with the moment of its own file: one, or two while one turns into the next.
    func clipsAt(_ t: Double) -> [(Int, Double)] {
        var out: [(Int, Double)] = []
        for (i, c) in clips.enumerated() where i < starts.count {
            let a = starts[i], b = a + c.span
            guard t >= a - 0.0001, t < b || (i == clips.count - 1 && t <= b + 0.05) else { continue }
            out.append((i, min(c.end, c.start + max(0, t - a) * max(c.speed, 0.01))))
        }
        return Array(out.prefix(2))
    }

    /// A reader for a clip or overlay, from its smaller copy if it has one (a 4K clip's).
    private func reader(_ id: String, _ source: URL) -> FrameReader {
        let url = swap[source] ?? source, key = id + "|" + url.path
        if let r = readers[key] { return r }
        let r = FrameReader(url: url)
        readers[key] = r
        return r
    }

    /// While it plays, the next clip's reader started a second before it's needed.
    private func prepareNext(after t: Double) {
        guard rate != 0 else { return }
        for (i, c) in clips.enumerated() where i < starts.count && starts[i] > t && starts[i] - t < 1.2 {
            reader("c\(c.id)", c.source).prepare(at: c.start)
        }
    }

    /// Readers not used for a few seconds let go (what they hold is a few frames each).
    private func tidy() {
        let now = CACurrentMediaTime()
        for (k, r) in readers where now - r.lastUsed > 4 { r.cancel(); readers[k] = nil }
    }

    // MARK: the sound

    /// What's heard where, not how loud: when it changes while playing, the sound's started again.
    private var soundKey: String {
        soundPieces().map { "\($0.url.path),\($0.from),\($0.fileStart),\($0.length),\($0.rate)" }.joined(separator: "|")
    }

    /// Every sound in the edit, each with its level at a moment of the video: each clip's own (or one clip's for
    /// all of it), the voiceovers, effects, song and separated sound, as ClipJoin.compose lays them in.
    func soundPieces() -> [SoundPiece] {
        var dips: [(Double, Double)] = []
        for v in sounds.filter({ $0.kind == "voice" }).sorted(by: { $0.from < $1.from }) {
            if let lastDip = dips.last, v.from <= lastDip.1 + 0.4 { dips[dips.count - 1].1 = max(lastDip.1, v.to) } else { dips.append((v.from, v.to)) }
        }
        let ease = 0.2, low: Float = 0.3
        let dip = { (v: Double) -> Float in
            var k: Float = 1
            for (a, b) in dips {
                if v >= a && v <= b { k = min(k, low) }
                else if v > a - ease && v < a { k = min(k, 1 - (1 - low) * Float((v - (a - ease)) / ease)) }
                else if v > b && v < b + ease { k = min(k, low + (1 - low) * Float((v - b) / ease)) }
            }
            return k
        }
        var out: [SoundPiece] = []
        if let id = soundOf, let c = clips.first(where: { $0.id == id }), !c.still {
            let span = c.heardEnd - c.heardStart
            var put = 0.0, n = 0
            while span > 0.2, put < total - 0.01 {
                let piece = min(span, total - put)
                let vol = c.volume
                out.append(SoundPiece(key: "all\(n)", url: c.clean ?? c.source, from: put, fileStart: c.heardStart, length: piece, rate: 1,
                                      level: { v in vol * dip(v) }))
                put += piece; n += 1
            }
        } else {
            for (i, c) in clips.enumerated() where i < starts.count && !c.still && c.heardEnd - c.heardStart > 0.05 {
                let r = max(c.speed, 0.01)
                var heard = c
                // across a transition it fades out as the next fades in
                let before = i > 0 ? ClipJoin.overlap(clips, after: i - 1) : 0, after = ClipJoin.overlap(clips, after: i)
                if before > 0 { heard.fadeIn = max(heard.fadeIn, before * r) }
                if after > 0 { heard.fadeOut = max(heard.fadeOut, after * r) }
                let from = starts[i] + (heard.heardStart - c.start) / r
                let length = (min(heard.heardEnd, c.end) - heard.heardStart) / r
                let on: Float = c.soundOn ? 1 : 0, h = heard
                out.append(SoundPiece(key: "c\(c.id)", url: c.clean ?? c.source, from: from, fileStart: heard.heardStart, length: length, rate: r,
                                      level: { v in h.level(at: h.heardStart + (v - from) * r) * dip(v) * on }))
            }
        }
        for s in sounds {
            guard let url = s.url else { continue }
            let ducks = s.kind == "clip", snd = s
            let parts: [EditSound.Stretch] = s.stretches(until: total)
            for (n, part) in parts.enumerated() {
                let level: (Double) -> Float = { (v: Double) -> Float in snd.level(at: v) * (ducks ? dip(v) : 1) }
                out.append(SoundPiece(key: "s\(s.id)-\(n)", url: url, from: part.from, fileStart: part.fileStart, length: part.length,
                                      rate: s.speed, level: level))
            }
        }
        return out
    }
}

/// One sound in the edit: from where in its file, played from where in the video, for how long (the video's seconds),
/// at what speed, and how loud at each moment of the video.
struct SoundPiece {
    var key: String
    var url: URL
    var from: Double
    var fileStart: Double
    var length: Double
    var rate: Double
    var level: (Double) -> Float
}

/// A clip's frames read a few ahead of where they're wanted, on a queue of its own. Asked for a moment that isn't
/// near what it's read (a seek, a jump back, a trim), it starts again from there.
final class FrameReader {
    let url: URL
    private let asset: AVURLAsset
    private let queue = DispatchQueue(label: "preview-frames", qos: .userInitiated)
    private let lock = NSLock()
    private var track: AVAssetTrack?
    private var frames: [(Double, CVPixelBuffer)] = []
    private var generation = 0
    private var from = -1.0            // where the reading started (-1: not yet)
    private var waiting: Double?       // a start asked for before the file was open
    private var startedAt = 0.0        // when the reading last started (they're kept a twelfth of a second apart)
    private let ahead = 5
    var lastUsed = CACurrentMediaTime()

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        let a = asset
        Task { [weak self] in
            let t = try? await a.loadTracks(withMediaType: .video).first
            self?.opened(t)
        }
    }

    private func opened(_ t: AVAssetTrack?) {
        lock.lock(); track = t; let w = waiting; waiting = nil; lock.unlock()
        if let w { start(at: w) }
    }

    /// Reading started there if it isn't reading near it already.
    func prepare(at s: Double) {
        lastUsed = CACurrentMediaTime()
        lock.lock()
        let oldest = frames.first?.0 ?? from
        let near = from >= 0 && s >= oldest - 0.05 && s <= (frames.last?.0 ?? from) + 0.75
        lock.unlock()
        if !near { start(at: s) }
    }

    /// Stopped for good: its reading ends at its next frame (it's being let go).
    func cancel() {
        lock.lock(); generation += 1; frames.removeAll(); waiting = nil; lock.unlock()
    }

    /// The frame to show at `s` (its file's seconds) and its time, or nil while there's none read yet.
    func frame(at s: Double) -> (Double, CVPixelBuffer)? {
        lastUsed = CACurrentMediaTime()
        lock.lock()
        let last = frames.last?.0 ?? from, oldest = frames.first?.0 ?? from
        // behind the oldest frame it still has (a jump back, round again at the end), or well past what it's read:
        // start again there
        if from < 0 || s < oldest - 0.05 || s > last + 0.75 {
            // not again within a twelfth of a second of the last start: a finger scrubbing back started it again on
            // every move and threw away what it had, so nothing came through until it stopped (21 Nov recording).
            // Till then the nearest it has shows.
            if from >= 0, CACurrentMediaTime() - startedAt < 0.08 {
                let near = frames.first
                lock.unlock()
                return near
            }
            lock.unlock()
            start(at: s)
            return nil
        }
        // the ones already past let go (the last always kept: a clip's end holds its last frame)
        while frames.count >= 2 && frames[1].0 <= s + 0.008 { frames.removeFirst() }
        let shown = frames.first
        lock.unlock()
        return shown
    }

    private func start(at s: Double) {
        lock.lock()
        generation += 1
        let g = generation
        frames.removeAll()
        from = max(0, s)
        startedAt = CACurrentMediaTime()
        guard track != nil else { waiting = s; lock.unlock(); return }
        lock.unlock()
        queue.async { [weak self] in self?.read(from: max(0, s), generation: g) }
    }

    private func read(from s: Double, generation g: Int) {
        lock.lock()
        let current = g == generation, tr = track
        lock.unlock()
        guard current, let tr, let reader = try? AVAssetReader(asset: asset) else { return }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), duration: .positiveInfinity)
        let out = AVAssetReaderTrackOutput(track: tr, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return }
        reader.add(out)
        guard reader.startReading() else { return }
        defer { reader.cancelReading() }
        var first = true, skipped: (Double, CVPixelBuffer)?
        while true {
            // room for more, or a newer start asked for
            while true {
                lock.lock()
                let stale = g != generation, full = frames.count >= ahead
                lock.unlock()
                if stale { return }
                if !full { break }
                usleep(3_000)
            }
            guard let sb = out.copyNextSampleBuffer() else {
                // the end: if every frame was before the moment asked for (a clip's very end), its last one
                lock.lock()
                if g == generation, frames.isEmpty, let skipped { frames.append(skipped) }
                lock.unlock()
                return
            }
            guard let px = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            // the frames from the keyframe before the moment asked for aren't kept, only decoded on the way: kept,
            // they came out one a screen frame, and a jump took a while to catch up
            if first, pts < s - 0.02 { skipped = (pts, px); continue }
            lock.lock()
            // the frame on screen at the moment asked for is the last one before it, when the next is still to come:
            // kept first. A photo is two frames, its start and its end; without this, asked for its middle, it had
            // only the end, behind which the moment fell, so it started again and again and never showed (21 Nov:
            // a photo overlay put on, and hidden)
            if first, pts > s + 0.02, let skipped, g == generation { frames.append(skipped) }
            first = false
            if g == generation { frames.append((pts, px)) }
            lock.unlock()
        }
    }
}

/// The edit's sound, mixed as it plays: each piece on a player of its own, through a speed change for a clip that
/// isn't at normal speed, its level set many times a second from the edit as it is now (so a mute, a volume, a fade
/// takes at once, with nothing made again). Each file's sound is read once into memory.
final class SoundMixer {
    private let engine = AVAudioEngine()
    private var players: [(AVAudioPlayerNode, AVAudioUnitTimePitch)] = []
    private var playing: [(SoundPiece, Int)] = []
    private var buffers: [URL: AVAudioPCMBuffer] = [:]
    private var loading: Set<URL> = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    /// Silent: stopped altogether, so it's out of the way while a voiceover's recorded (which has the sound of its own).
    var muted = false { didSet { if muted { stop(); engine.stop() } } }
    /// Told when a file's sound has been read (to start the sound again with it).
    var onLoaded: (() -> Void)?

    /// Each file's sound read, if it isn't already.
    func prepare(_ urls: [URL]) {
        for u in Set(urls) where buffers[u] == nil && !loading.contains(u) {
            loading.insert(u)
            let f = format
            Task.detached(priority: .utility) { [weak self] in
                let b = await SoundMixer.read(u, f)
                await MainActor.run {
                    guard let self else { return }
                    self.loading.remove(u)
                    if let b { self.buffers[u] = b; self.onLoaded?() }
                }
            }
        }
    }

    /// Everything from `t` on, started together at `host` (the screen's clock), so it's in time with the picture.
    func play(from t: Double, host: Double, pieces: [SoundPiece]) {
        stop()
        playing = []
        guard !muted else { return }
        var n = 0
        let rate = format.sampleRate
        for p in pieces where p.from + p.length > t + 0.01 {
            guard let all = buffers[p.url] else { continue }
            let into = max(0, t - p.from)                     // the video's seconds of it already gone
            let a = AVAudioFramePosition(((p.fileStart + into * p.rate) * rate).rounded())
            let want = (p.length - into) * p.rate * rate
            guard a >= 0, a < AVAudioFramePosition(all.frameLength) else { continue }
            let count = AVAudioFrameCount(max(0, min(Double(AVAudioFramePosition(all.frameLength) - a), want)))
            guard count > 64, let part = Self.slice(all, from: a, count: count) else { continue }
            let (node, pitch) = player(n)
            // (a player played on an engine that isn't running throws, and can't be caught: none played then)
            guard engine.isRunning || (try? engine.start()) != nil else { return }
            pitch.rate = Float(min(32, max(1.0 / 32, p.rate)))
            node.volume = muted ? 0 : p.level(max(t, p.from))
            node.scheduleBuffer(part, at: nil, options: [], completionHandler: nil)
            let delay = max(0, p.from - t)
            node.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host + delay)))
            playing.append((p, n))
            n += 1
        }
    }

    /// Each piece's level at `t`, as the edit is now.
    func levels(at t: Double) {
        for (p, k) in playing where k < players.count {
            players[k].0.volume = muted ? 0 : p.level(min(max(t, p.from), p.from + p.length))
        }
    }

    func stop() {
        for (node, _) in players { node.stop() }
        playing = []
    }

    /// The engine running, with a player on it, ready to start sound in time.
    func warm() {
        guard !muted else { return }
        _ = player(0)
        if !engine.isRunning { try? engine.start() }
    }

    func shutdown() {
        stop()
        engine.stop()
    }

    /// Stopped altogether, to be started again the next time it plays.
    func reset() {
        stop()
        engine.stop()
        engine.reset()
    }

    private func player(_ k: Int) -> (AVAudioPlayerNode, AVAudioUnitTimePitch) {
        while players.count <= k {
            let node = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
            engine.attach(node); engine.attach(pitch)
            engine.connect(node, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
            players.append((node, pitch))
        }
        return players[k]
    }

    private static func slice(_ b: AVAudioPCMBuffer, from a: AVAudioFramePosition, count n: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: n), let src = b.floatChannelData, let dst = out.floatChannelData else { return nil }
        for ch in 0..<Int(b.format.channelCount) { memcpy(dst[ch], src[ch] + Int(a), Int(n) * MemoryLayout<Float>.size) }
        out.frameLength = n
        return out
    }

    /// A file's sound (a video's, a voiceover's, the song's), as two channels at 44.1 kHz in memory.
    static func read(_ url: URL, _ format: AVAudioFormat) async -> AVAudioPCMBuffer? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let length = try? await asset.load(.duration).seconds, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false])
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        let room = Int((max(0.1, length) + 1) * format.sampleRate)
        guard let all = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(room)), let dst = all.floatChannelData else { return nil }
        var at = 0
        while let sb = out.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, at + n <= room, let tmp = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
            tmp.frameLength = AVAudioFrameCount(n)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: tmp.mutableAudioBufferList) == noErr,
                  let src = tmp.floatChannelData else { continue }
            for ch in 0..<Int(format.channelCount) { memcpy(dst[ch] + at, src[ch], n * MemoryLayout<Float>.size) }
            at += n
        }
        all.frameLength = AVAudioFrameCount(at)
        return at > 0 ? all : nil
    }
}
