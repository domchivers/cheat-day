import XCTest
@testable import CheatDays

/// 22 Nov, design/timeline-waveforms-pro-mockup.html: the timeline's waves, and trimming to the words.
final class WaveformTests: XCTestCase {
    private func levels(_ runs: [(seconds: Double, level: Float)]) -> [Float] {
        var out: [Float] = []
        for run in runs {
            out += [Float](repeating: run.level, count: Int((run.seconds * WaveFile.rate).rounded()))
        }
        return out
    }

    func testAPauseIsTheMiddleOfAGapInTheTalking() {
        let said: [Float] = levels([(seconds: 1, level: 0.8), (seconds: 0.5, level: 0.02), (seconds: 1, level: 0.7)])
        let found: [Double] = WaveFile.findPauses(said)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first ?? 0, 1.25, accuracy: 0.001)
    }

    func testJustClearOfWhereTalkingBeginsAndEnds() {
        let said: [Float] = levels([(seconds: 0.4, level: 0.01), (seconds: 1, level: 0.8), (seconds: 0.6, level: 0.01)])
        let found: [Double] = WaveFile.findPauses(said)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first ?? 0, 0.32, accuracy: 0.001)
        XCTAssertEqual(found.last ?? 0, 1.5, accuracy: 0.001)
    }

    func testAShortBreakOrSteadySoundHasNoPause() {
        let quick: [Float] = levels([(seconds: 1, level: 0.8), (seconds: 0.1, level: 0.02), (seconds: 0.4, level: 0.8)])
        XCTAssertTrue(WaveFile.findPauses(quick).isEmpty)
        XCTAssertTrue(WaveFile.findPauses(levels([(seconds: 3, level: 0.6)])).isEmpty)
    }

    func testTheLoudestOfAStretch() {
        let file = WaveFile(levels: [0.1, 0.9, 0.2, 0.3])
        XCTAssertEqual(file.peak(from: 0, to: 0.04), 0.9)
        XCTAssertEqual(file.peak(from: 0.04, to: 0.08), 0.3)
        XCTAssertEqual(file.peak(from: 2, to: 3), 0)
    }

    func testBarsStayUnderTheirSoundAsItsTrimmed() throws {
        let whole: [WaveMath.Bar] = WaveMath.bars(width: 50, pps: 25, fileStart: 0, speed: 1)
        let cut: [WaveMath.Bar] = WaveMath.bars(width: 40, pps: 25, fileStart: 0.25, speed: 1)
        let first: WaveMath.Bar = try XCTUnwrap(cut.first)
        XCTAssertEqual(first.low, 0.3, accuracy: 0.0001)
        XCTAssertEqual(first.x, 1.25, accuracy: 0.001)
        XCTAssertEqual(whole.count, 20)
    }

    func testDragPastAndItLetsGo() {
        XCTAssertEqual(WaveMath.pause([1, 2], near: 2.1, reach: 0.2), 2)
        XCTAssertNil(WaveMath.pause([1, 2], near: 2.3, reach: 0.2))
    }

    func testTheWordsEitherSide() {
        let words: [(text: String, at: Double)] = [(text: "and", at: 13.3), (text: "to", at: 12), (text: "chaos", at: 12.25)]
        let sides: (before: String, after: String) = WaveMath.between(words, 13.05)
        XCTAssertEqual(sides.before, "chaos")
        XCTAssertEqual(sides.after, "and")
        XCTAssertEqual(WaveMath.between([], 1).before, "")
    }

    func testWhereMusicGoesRoundAgain() {
        var s = EditSound(kind: "song", name: "Song", from: 2, start: 0, length: 70, full: 30)
        s.loopFrom = 0
        XCTAssertEqual(WaveMath.rounds(s), [30, 60])
    }
}
