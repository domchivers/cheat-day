import AVFoundation

/// A sound laid over an edit (Stage C, 20 Nov; design/editor-all-tools-mockup.html, 4): a voiceover take, or a sound
/// effect. Each is a bar on the timeline: where it starts in the video, how much of it, how loud. While a voiceover
/// plays, the clips' own sound dips under it.
struct EditSound: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: String            // "voice", "effect", "song", or "clip": a clip's own sound, separated from it
    var name: String            // an effect's name, or "Voice 1"
    var file: URL?              // a voiceover's recording, the song, or the clip's video (an effect's is made when wanted)
    var from: Double            // where it starts in the video
    var start = 0.0             // where in its own sound it starts (trimmed off the front)
    var length: Double          // how much of the video it plays over
    var volume: Float = 1
    var full = 0.0              // how long its sound is in all (0: not known)
    var beats: [Double]? = nil  // a song's beats, in its file's own seconds (Stage E)
    // (21 Nov, design/separate-audio-mockup.html; optional, so older drafts still read)
    var fadeIn: Double? = nil   // seconds of the video it fades in over
    var fadeOut: Double? = nil
    var keys: [VolumeKey]? = nil  // its volume at moments of its own sound (its file's seconds), eased between
    var clip: UUID? = nil       // kind "clip": the clip its sound was separated from, to put it back
    var rate: Double? = nil     // kind "clip": that clip's speed, which its sound keeps
    var to: Double { from + length }

    /// The file it plays from.
    var url: URL? { kind == "effect" ? SoundEffects.url(name) : file }

    var speed: Double { max(rate ?? 1, 0.01) }
    /// Its own sound's seconds at a moment of the video, and back.
    func fileTime(_ v: Double) -> Double { start + (v - from) * speed }
    func videoTime(_ p: Double) -> Double { from + (p - start) / speed }

    /// Its volume from its keyframes alone, at a moment of its own sound.
    func keyLevel(at p: Double) -> Float {
        let k = (keys ?? []).sorted { $0.at < $1.at }
        guard let first = k.first, let last = k.last else { return volume }
        if p <= first.at { return first.volume }
        if p >= last.at { return last.volume }
        guard let i = k.firstIndex(where: { $0.at > p }) else { return last.volume }
        let a = k[i - 1], b = k[i], f = Float((p - a.at) / max(b.at - a.at, 0.001))
        return a.volume + (b.volume - a.volume) * f
    }

    /// Its volume at a moment of the video: its keyframes (or its one volume), and its fades.
    func level(at v: Double) -> Float {
        var x = (keys ?? []).isEmpty ? volume : keyLevel(at: fileTime(v))
        let fi = fadeIn ?? 0, fo = fadeOut ?? 0
        if fi > 0.01, v - from < fi { x *= Float(max(0, v - from) / fi) }
        if fo > 0.01, to - v < fo { x *= Float(max(0, to - v) / fo) }
        return max(0, min(1, x))
    }

    /// The moments of the video its level turns at, start and end included: between them it's a straight ramp.
    var turns: [Double] {
        var at = [from, to]
        if let fi = fadeIn, fi > 0.01 { at.append(from + fi) }
        if let fo = fadeOut, fo > 0.01 { at.append(to - fo) }
        at += (keys ?? []).map { videoTime($0.at) }
        return Array(Set(at.map { min(to, max(from, $0)) })).sorted()
    }
}

/// A few short sounds for edits, made here from tones and noise (nothing downloaded, nobody else's sound): each made
/// once into a file in Caches.
enum SoundEffects {
    static let names = ["Pop", "Ding", "Whoosh", "Boom", "Click", "Ta-da", "Sizzle", "Rise"]
    private static let rate = 44_100.0

    static func url(_ name: String) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("effects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(name.lowercased().replacingOccurrences(of: " ", with: "-") + "-v1.caf")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let samples = make(name)
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { ch[i] = samples[i] }
        guard let file = try? AVAudioFile(forWriting: out, settings: format.settings) else { return nil }
        do { try file.write(from: buffer) } catch { return nil }
        return out
    }

    /// How long each is, seconds.
    static func length(_ name: String) -> Double { Double(make(name).count) / rate }

    private static func make(_ name: String) -> [Float] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
        }
        func tone(_ seconds: Double, _ f: (Double) -> Double, _ amp: (Double) -> Double) -> [Float] {
            let n = Int(seconds * rate)
            var phase = 0.0, out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Double(i) / rate
                phase += 2 * .pi * f(t) / rate
                out[i] = Float(sin(phase) * amp(t))
            }
            return out
        }
        func mix(_ a: [Float], _ b: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: max(a.count, b.count))
            for i in out.indices { out[i] = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0) }
            return out
        }
        switch name {
        case "Pop":
            return tone(0.12, { 900 - 5000 * $0 }, { 0.8 * exp(-$0 * 40) })
        case "Ding":
            let a = tone(1.2, { _ in 1318.5 }, { 0.45 * exp(-$0 * 3.5) })
            let b = tone(1.2, { _ in 2637 }, { 0.18 * exp(-$0 * 5) })
            return mix(a, b)
        case "Whoosh":
            // noise swelling and falling away, smoothed so it's soft rather than hissy
            let n = Int(0.7 * rate)
            var out = [Float](repeating: 0, count: n), low: Float = 0
            for i in 0..<n {
                let t = Double(i) / Double(n)
                let k = Float(0.04 + 0.25 * sin(t * .pi))
                low += k * (noise() - low)
                out[i] = low * Float(sin(t * .pi)) * 1.6
            }
            return out
        case "Boom":
            let body = tone(0.9, { 110 * exp(-$0 * 3) + 35 }, { 0.9 * exp(-$0 * 4) })
            var hit = [Float](repeating: 0, count: Int(0.05 * rate))
            for i in hit.indices { hit[i] = noise() * 0.5 * Float(exp(-Double(i) / rate * 80)) }
            return mix(body, hit)
        case "Click":
            return tone(0.03, { _ in 2500 }, { 0.6 * exp(-$0 * 200) })
        case "Ta-da":
            // a rising major chord, each note a moment after the last
            let notes = [523.25, 659.25, 783.99, 1046.5]
            var out = [Float](repeating: 0, count: Int(1.3 * rate))
            for (k, f) in notes.enumerated() {
                let start = Int(Double(k) * 0.09 * rate)
                let t = tone(1.3 - Double(k) * 0.09, { _ in f }, { 0.22 * exp(-$0 * 2.2) })
                for i in t.indices where start + i < out.count { out[start + i] += t[i] }
            }
            return out
        case "Sizzle":
            let n = Int(1.4 * rate)
            var out = [Float](repeating: 0, count: n), last: Float = 0
            for i in 0..<n {
                let t = Double(i) / rate
                let crackle: Float = noise() > 0.985 ? noise() * 0.8 : 0
                let hiss = noise() - last; last = noise()
                out[i] = (hiss * 0.12 + crackle) * Float(min(1, t * 8) * min(1, (1.4 - t) * 3))
            }
            return out
        case "Rise":
            return tone(0.9, { 300 + 900 * $0 * $0 }, { 0.35 * min(1, $0 * 4) * max(0, 1 - pow($0 / 0.9, 6)) })
        default:
            return []
        }
    }
}

/// Recording a voiceover (Stage C): from the microphone, with the phone's own voice processing on (it takes out
/// background noise and the edit's sound coming from the speaker), into a file of its own.
final class VoiceRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var url: URL?
    private var began = Date()

    static func allowed() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    func start(clear: Bool) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try s.setActive(true)
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(clear)
        let format = input.outputFormat(forBus: 0)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("voice-" + UUID().uuidString + ".caf")
        file = try AVAudioFile(forWriting: out, settings: format.settings)
        url = out
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in try? self?.file?.write(from: buffer) }
        engine.prepare()
        try engine.start()
        began = Date()
    }

    /// Stopped: the recording, and how long it is.
    func stop() -> (URL, Double)? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        file = nil
        let length = Date().timeIntervalSince(began)
        guard let url, length > 0.25 else { return nil }
        return (url, length)
    }
}

/// A clip's sound made clearer (Stage C): the low rumble and hum cut, voices lifted, the level evened out. Not a full
/// noise remover: it helps speech stand out of wind, traffic and a kitchen fan, not a crowd.
enum Clarity {
    static func clearer(_ c: Clip) async -> URL? {
        // its sound as a file of its own first (AVAudioFile reads audio, not a video's sound)
        let asset = AVURLAsset(url: c.source)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        _ = track
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: raw) }
        export.outputURL = raw; export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed, let input = try? AVAudioFile(forReading: raw) else { return nil }
        let format = input.processingFormat
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 4)
        let bands: [(AVAudioUnitEQFilterType, Float, Float, Float)] = [
            (.highPass, 90, 0, 0.7),        // rumble, wind, handling
            (.parametric, 50, -12, 4),      // mains hum
            (.parametric, 3200, 4, 1),      // voices' clarity
            (.lowPass, 12_000, 0, 0.7)]     // hiss
        for (k, b) in bands.enumerated() {
            let band = eq.bands[k]
            band.filterType = b.0; band.frequency = b.1; band.gain = b.2; band.bandwidth = b.3; band.bypass = false
        }
        let comp = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(player); engine.attach(eq); engine.attach(comp)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: comp, format: format)
        engine.connect(comp, to: engine.mainMixerNode, format: format)
        do { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) } catch { return nil }
        do { try engine.start() } catch { return nil }
        player.scheduleFile(input, at: nil, completionHandler: nil)
        player.play()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("clear-" + UUID().uuidString + ".caf")
        guard let written = try? AVAudioFile(forWriting: out, settings: engine.manualRenderingFormat.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { return nil }
        while engine.manualRenderingSampleTime < input.length {
            let left = AVAudioFrameCount(input.length - engine.manualRenderingSampleTime)
            guard let status = try? engine.renderOffline(min(buffer.frameCapacity, left), to: buffer) else { break }
            if status == .success { try? written.write(from: buffer) } else if status == .error { break }
        }
        player.stop(); engine.stop()
        return out
    }
}

/// A song's beats (Stage E): its sound read small, where it gets suddenly louder found, the steady pulse through
/// those (its tempo, 70 to 180 a minute, and where the first beat falls), and every beat of it.
enum Beats {
    static let rate = 11_025.0

    /// The beats of a part of a song, in the song file's own seconds.
    static func find(_ url: URL, from: Double, length: Double) async -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var samples: [Float] = []
        while let sb = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: n / 4)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: &chunk)
            samples += chunk
        }
        return grid(samples, rate: rate).map { $0 + from }
    }

    /// The beats in some sound, seconds from its start.
    static func grid(_ samples: [Float], rate: Double) -> [Double] {
        let hop = 128, step = Double(hop) / rate
        var energy: [Float] = []
        var i = 0
        while i + hop <= samples.count {
            var e: Float = 0
            for j in i..<(i + hop) { e += samples[j] * samples[j] }
            energy.append((e / Float(hop)).squareRoot())
            i += hop
        }
        guard energy.count > 100 else { return [] }
        // how suddenly it gets louder, moment to moment
        var onset = [Float](repeating: 0, count: energy.count)
        for k in 1..<energy.count { onset[k] = max(0, log(1 + 100 * energy[k]) - log(1 + 100 * energy[k - 1])) }
        // spread a step either side, so a pulse a hair off the true beat length still lands on its hits (20 Nov: a
        // 150 a minute click drifted off its beats over 12 s and was heard at half speed)
        var spread = onset
        for k in onset.indices {
            let before = k > 0 ? onset[k - 1] : 0, after = k + 1 < onset.count ? onset[k + 1] : 0
            spread[k] = max(onset[k], 0.6 * before, 0.6 * after)
        }
        onset = spread
        func at(_ x: Double) -> Float {
            let k = Int(x.rounded())
            return k >= 0 && k < onset.count ? onset[k] : 0
        }
        // the pulse: the beat length (in steps) and start that line up with the most of it, leaning a little towards
        // 120 a minute when two are close (a song at 60 or 240 is heard as 120)
        var best = (score: Float(-1), period: 0.0, phase: 0.0)
        var period = 60.0 / 180.0 / step
        let longest = 60.0 / 70.0 / step
        while period <= longest {
            let bpm = 60 / (period * step)
            let lean = Float(exp(-pow(log2(bpm / 120), 2) * 0.6))
            var phase = 0.0
            while phase < period {
                var sum: Float = 0, n = 0
                var x = phase
                while x < Double(onset.count) { sum += at(x); n += 1; x += period }
                let score = n > 0 ? sum / Float(n) * lean : 0
                if score > best.score { best = (score, period, phase) }
                phase += 1
            }
            period += 0.04
        }
        guard best.period > 0 else { return [] }
        var out: [Double] = []
        var x = best.phase
        while x < Double(onset.count) { out.append(x * step); x += best.period }
        return out
    }
}
