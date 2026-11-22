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
        let loud: Float = sorted[sorted.count * 95 / 100]
        // (as loud all the way through, music or noise: nothing to hold on)
        guard loud - quiet > 0.12 else { return [] }
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
}
