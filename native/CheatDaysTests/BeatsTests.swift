import XCTest
@testable import CheatDays

/// Stage E: the beat finder hears a steady click as its tempo, the beats landing on the clicks.
final class BeatsTests: XCTestCase {
    /// Clicks every `gap` seconds, starting `offset` in, for `seconds`, with a little hiss under them.
    private func clicks(gap: Double, offset: Double, seconds: Double) -> [Float] {
        let rate = Beats.rate, n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var seed: UInt32 = 7
        for i in 0..<n {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            out[i] = Float(seed % 1000) / 1000 * 0.01 - 0.005
        }
        var t = offset
        while t < seconds {
            let start = Int(t * rate)
            for k in 0..<Int(0.03 * rate) where start + k < n { out[start + k] += Float(sin(Double(k) * 0.9)) * 0.8 * Float(exp(-Double(k) / 80)) }
            t += gap
        }
        return out
    }

    func testFindsA120BeatAMinutePulse() {
        let beats = Beats.grid(clicks(gap: 0.5, offset: 0.2, seconds: 12), rate: Beats.rate)
        XCTAssertGreaterThan(beats.count, 18)
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.02)
        // each beat lands on a click (within 40 ms)
        for b in beats.prefix(20) {
            let off = (b - 0.2).truncatingRemainder(dividingBy: 0.5)
            XCTAssertLessThan(min(abs(off), abs(0.5 - abs(off))), 0.04, "beat at \(b)")
        }
    }

    func testFindsAFasterPulse() {
        let beats = Beats.grid(clicks(gap: 60.0 / 150.0, offset: 0, seconds: 12), rate: Beats.rate)
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(gaps.reduce(0, +) / Double(max(gaps.count, 1)), 0.4, accuracy: 0.02)
    }

    func testSilenceHasNoBeatToSpeakOf() {
        XCTAssertTrue(Beats.grid([Float](repeating: 0, count: 500), rate: Beats.rate).isEmpty)
    }
}
