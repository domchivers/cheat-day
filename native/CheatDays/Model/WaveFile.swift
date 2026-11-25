import AVFoundation

/// A file's sound as the timeline draws it, read once whatever part of it plays: fifty levels a second, and the pauses
/// in what's said that a handle holds on (design/timeline-waveforms-pro-mockup.html).
struct WaveFile: Equatable, Sendable {
    static let rate = 50.0

    let levels: [Float]
    let pauses: [Double]

    init(levels: [Float]) {
        self.levels = levels
        self.pauses = WaveFile.findPauses(levels)
    }

    /// The loudest between two moments of it.
    func peak(from low: Double, to high: Double) -> Float {
        guard !levels.isEmpty, high >= 0 else { return 0 }
        let first: Int = max(0, Int((low * WaveFile.rate).rounded(.down)))
        guard first < levels.count else { return 0 }
        let last: Int = min(levels.count - 1, max(first, Int((high * WaveFile.rate).rounded(.up)) - 1))
        var top: Float = 0
        for i in first...last { top = max(top, levels[i]) }
        return top
    }

    /// A part of it, as so many levels.
    func part(from low: Double, to high: Double, count: Int) -> [Float] {
        guard high > low, count > 0, !levels.isEmpty else { return [] }
        let each: Double = (high - low) / Double(count)
        var out: [Float] = []
        for i in 0..<count {
            let at: Double = low + each * Double(i)
            out.append(peak(from: at, to: at + each))
        }
        return out
    }

    /// Where the talking stops for a breath: the middle of each gap, and just clear of where it begins and ends.
    static func findPauses(_ levels: [Float]) -> [Double] {
        guard levels.count >= 10 else { return [] }
        let sorted: [Float] = levels.sorted()
        let quiet: Float = sorted[sorted.count / 10]
        // (the talking's loudness, however little of the file it is: of the whole, the 95th was the silence)
        let floor: Float = max(0.01, quiet * 3)
        let heard: [Float] = sorted.filter { (v: Float) -> Bool in v > floor }
        let loud: Float = heard.count >= 5 ? heard[heard.count * 95 / 100] : sorted[sorted.count * 95 / 100]
        // (as loud all the way through, music or noise: nothing to hold on. Relative too: one clap made the talking small)
        let apart: Float = loud - quiet
        guard apart > 0.12 || (loud > 0.02 && apart > loud * 0.6) else { return [] }
        let line: Float = quiet + (loud - quiet) * 0.16
        let least: Int = Int(0.22 * rate)
        var out: [Double] = []
        var i = 0
        while i < levels.count {
            guard levels[i] <= line else {
                i += 1
                continue
            }
            let began: Int = i
            while i < levels.count && levels[i] <= line { i += 1 }
            guard i - began >= least else { continue }
            let from: Double = Double(began) / rate, to: Double = Double(i) / rate
            if began == 0 && i == levels.count { break }
            if began == 0 { out.append(max(0, to - 0.08)) }
            else if i == levels.count { out.append(min(to, from + 0.1)) }
            else { out.append((from + to) / 2) }
        }
        return out
    }

    /// A file's sound read; one with none has no levels.
    static func read(_ url: URL) async -> WaveFile {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return WaveFile(levels: []) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                       AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return WaveFile(levels: []) }
        reader.add(output)
        guard reader.startReading() else { return WaveFile(levels: []) }
        let each: Int = Int(8000 / rate)
        var out: [Float] = []
        var top: Int32 = 0, count = 0, at = 0
        // (a level at a time, never the whole file's samples at once: a long clip's are tens of megabytes)
        while let sb = output.copyNextSampleBuffer() {
            let time: Double = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            // (a sound that starts late in its file, or has a hole in it, stays in time)
            if time.isFinite {
                let due: Int = Int(time * 8000)
                if due > at + each {
                    if count > 0 { out.append(Float(top) / 32768); top = 0; count = 0 }
                    while out.count < due / each { out.append(0) }
                    at = due
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes: Int = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: bytes / 2)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: (bytes / 2) * 2, destination: &chunk) == noErr else { continue }
            for sample in chunk {
                let size: Int32 = abs(Int32(sample))
                if size > top { top = size }
                count += 1
                if count == each {
                    out.append(Float(top) / 32768)
                    top = 0
                    count = 0
                }
            }
            at += chunk.count
        }
        if count > 0 { out.append(Float(top) / 32768) }
        let highest: Float = out.max() ?? 0
        guard highest > 0.004 else { return WaveFile(levels: out) }
        return WaveFile(levels: out.map { (v: Float) -> Float in v / highest })
    }
}

/// Where a wave's bars are, and what a handle's held on.
enum WaveMath {
    static let step = 2.5   // points from one bar to the next

    struct Bar: Equatable {
        var x: Double       // along it, points
        var low: Double     // what of its file it's the loudest of
        var high: Double
    }

    /// The bars along a stretch, on the file's own moments: trimmed, they stay under the sound they're of and don't
    /// shimmer.
    static func bars(width: Double, pps: Double, fileStart: Double, speed: Double) -> [Bar] {
        let perPoint: Double = max(speed, 0.01) / max(pps, 1)
        guard width > 0 else { return [] }
        let each: Double = step * perPoint
        var k: Double = (fileStart / each).rounded(.up)
        var out: [Bar] = []
        while true {
            let x: Double = (k * each - fileStart) / perPoint
            if x >= width { break }
            out.append(Bar(x: x, low: k * each, high: (k + 1) * each))
            k += 1
        }
        return out
    }

    /// The pause nearest a moment, if it's within reach.
    static func pause(_ pauses: [Double], near t: Double, reach: Double) -> Double? {
        guard let best = pauses.min(by: { (a: Double, b: Double) -> Bool in abs(a - t) < abs(b - t) }) else { return nil }
        return abs(best - t) <= reach ? best : nil
    }

    /// The words either side of a moment, each known by when it starts.
    static func between(_ words: [(text: String, at: Double)], _ t: Double) -> (before: String, after: String) {
        var before: (text: String, at: Double)?
        var after: (text: String, at: Double)?
        for w in words {
            if w.at <= t {
                if w.at >= (before?.at ?? -Double.infinity) { before = w }
            } else if w.at < (after?.at ?? Double.infinity) {
                after = w
            }
        }
        return (before?.text ?? "", after?.text ?? "")
    }

    /// Where a song goes round again, seconds along its bar.
    static func rounds(_ s: EditSound) -> [Double] {
        guard s.loopStart != nil else { return [] }
        return s.stretches(until: s.to).dropFirst().map { (part: EditSound.Stretch) -> Double in part.from - s.from }
    }

    // MARK: you see what you'll hear

    /// A stretch of the video a voiceover plays over, the takes merged where they come within 0.4 s of each other.
    struct Dip: Equatable {
        var from: Double
        var to: Double
    }

    /// How low a clip's own sound goes under a voiceover, and how long it takes to get there: as PreviewEngine and
    /// ClipJoin duck it.
    static let duckLow: Float = 0.3
    static let duckEase = 0.2

    /// Where the clips' own sound dips under a voiceover: each heard take, merged as the player merges them.
    static func dips(_ sounds: [EditSound]) -> [Dip] {
        let voices: [EditSound] = sounds.filter { (s: EditSound) -> Bool in s.kind == "voice" && s.off != true }
            .sorted { (a: EditSound, b: EditSound) -> Bool in a.from < b.from }
        var out: [Dip] = []
        for v in voices {
            if let last = out.last, v.from <= last.to + 0.4 {
                out[out.count - 1].to = max(last.to, v.to)
            } else {
                out.append(Dip(from: v.from, to: v.to))
            }
        }
        return out
    }

    /// How much of a clip's own sound is heard at a moment of the video, under the voiceovers: 1 clear of them, 0.3
    /// under one, eased down and back up a fifth of a second either side.
    static func duck(_ v: Double, _ dips: [Dip]) -> Float {
        var k: Float = 1
        let low: Float = duckLow
        let ease: Double = duckEase
        for d in dips {
            if v >= d.from && v <= d.to {
                k = min(k, low)
            } else if v > d.from - ease && v < d.from {
                let f: Float = Float((v - (d.from - ease)) / ease)
                k = min(k, 1 - (1 - low) * f)
            } else if v > d.to && v < d.to + ease {
                let f: Float = Float((v - d.to) / ease)
                k = min(k, low + (1 - low) * f)
            }
        }
        return k
    }

    /// A bar's height as a part of its row: as loud as it is in the file, times its level then (volume, keyframes,
    /// fades, ducking); nothing at all with its sound off, which draws it flat.
    static func shown(_ peak: Float, level: Float, heard: Bool) -> Float {
        guard heard else { return 0 }
        let v: Float = peak * level
        return v.isFinite ? max(0, min(1, v)) : 0
    }

    /// A clip as its sound is heard: across a transition it fades out as the next fades in (as PreviewEngine plays it).
    static func heardClip(_ clips: [Clip], at i: Int) -> Clip? {
        guard clips.indices.contains(i) else { return nil }
        var c: Clip = clips[i]
        let r: Double = max(c.speed, 0.01)
        let before: Double = i > 0 ? ClipJoin.overlap(clips, after: i - 1) : 0
        let after: Double = ClipJoin.overlap(clips, after: i)
        if before > 0 { c.fadeIn = max(c.fadeIn, before * r) }
        if after > 0 { c.fadeOut = max(c.fadeOut, after * r) }
        return c
    }
}
