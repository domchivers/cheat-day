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

    func testPausesInAMostlyQuietRecording() {
        let said: [Float] = levels([(seconds: 30, level: 0.002), (seconds: 1, level: 0.5), (seconds: 0.5, level: 0.002),
                                    (seconds: 0.8, level: 0.45), (seconds: 30, level: 0.002)])
        XCTAssertEqual(WaveFile.findPauses(said).count, 3)
    }

    func testOneClapDoesntHideTheTalking() {
        let said: [Float] = levels([(seconds: 1, level: 0.1), (seconds: 0.5, level: 0.002), (seconds: 1, level: 0.1),
                                    (seconds: 0.02, level: 1)])
        XCTAssertEqual(WaveFile.findPauses(said).count, 1)
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

    // MARK: 25 Nov: you see what you'll hear

    func testAWaveShrinksWithItsLevelAndGoesFlatWhenOff() {
        XCTAssertEqual(WaveMath.shown(0.8, level: 0.5, heard: true), 0.4, accuracy: 0.0001)
        XCTAssertEqual(WaveMath.shown(0.8, level: 2, heard: true), 1, accuracy: 0.0001)
        XCTAssertEqual(WaveMath.shown(0.8, level: 1, heard: false), 0)
        XCTAssertEqual(WaveMath.shown(Float.nan, level: 1, heard: true), 0)
    }

    func testASoundsWaveFollowsItsVolumeKeyframesAndFades() {
        var s = EditSound(kind: "effect", name: "Pop", from: 10, start: 0, length: 4)
        s.volume = 0.5
        XCTAssertEqual(WaveMath.shown(1, level: s.level(at: 12), heard: true), 0.5, accuracy: 0.0001)
        s.fadeIn = 2
        XCTAssertEqual(WaveMath.shown(1, level: s.level(at: 11), heard: true), 0.25, accuracy: 0.0001)
        s.fadeIn = nil
        s.keys = [VolumeKey(at: 0, volume: 0), VolumeKey(at: 4, volume: 1)]
        XCTAssertEqual(WaveMath.shown(1, level: s.level(at: 13), heard: true), 0.75, accuracy: 0.0001)
    }

    func testAClipsWaveFollowsItsVolumeAndFades() {
        var c = Clip(source: URL(fileURLWithPath: "/tmp/a.mov"), length: 10, start: 0, end: 10)
        c.volume = 0.6
        c.fadeOut = 2
        XCTAssertEqual(WaveMath.shown(1, level: c.level(at: 5), heard: true), 0.6, accuracy: 0.0001)
        XCTAssertEqual(WaveMath.shown(1, level: c.level(at: 9), heard: true), 0.3, accuracy: 0.0001)
    }

    func testAClipFadesAcrossItsTransitionAsItsHeard() throws {
        var a = Clip(source: URL(fileURLWithPath: "/tmp/a.mov"), length: 4, start: 0, end: 4)
        let b = Clip(source: URL(fileURLWithPath: "/tmp/b.mov"), length: 4, start: 0, end: 4)
        a.transition = ClipTransition(kind: "Dissolve", length: 0.5)
        let first: Clip = try XCTUnwrap(WaveMath.heardClip([a, b], at: 0))
        let second: Clip = try XCTUnwrap(WaveMath.heardClip([a, b], at: 1))
        XCTAssertEqual(first.fadeOut, 0.5, accuracy: 0.0001)
        XCTAssertEqual(second.fadeIn, 0.5, accuracy: 0.0001)
        XCTAssertNil(WaveMath.heardClip([a, b], at: 2))
    }

    func testClipsDipUnderAVoiceoverAsThePlayerDipsThem() {
        let v1 = EditSound(kind: "voice", name: "Voice 1", from: 2, length: 3)
        let v2 = EditSound(kind: "voice", name: "Voice 2", from: 5.3, length: 1)    // within 0.4 s: one dip
        var off = EditSound(kind: "voice", name: "Voice 3", from: 20, length: 2)
        off.off = true                                                               // its row switched off: no dip
        let song = EditSound(kind: "song", name: "Song", from: 0, length: 30)
        let dips: [WaveMath.Dip] = WaveMath.dips([v2, song, off, v1])
        XCTAssertEqual(dips, [WaveMath.Dip(from: 2, to: 6.3)])
        XCTAssertEqual(WaveMath.duck(4, dips), 0.3, accuracy: 0.0001)
        XCTAssertEqual(WaveMath.duck(1, dips), 1, accuracy: 0.0001)
        XCTAssertEqual(WaveMath.duck(1.9, dips), 0.65, accuracy: 0.0001)    // half way down
        XCTAssertEqual(WaveMath.duck(6.4, dips), 0.65, accuracy: 0.0001)    // half way back up
        XCTAssertEqual(WaveMath.duck(21, dips), 1, accuracy: 0.0001)
    }

    func testTheHandleSnapsToThePauseAndSaysTheWords() throws {
        let said: [Float] = levels([(seconds: 1, level: 0.8), (seconds: 0.5, level: 0.02), (seconds: 1, level: 0.7)])
        let file = WaveFile(levels: said)
        let held: Double = try XCTUnwrap(WaveMath.pause(file.pauses, near: 1.1, reach: 0.25))
        XCTAssertEqual(held, 1.25, accuracy: 0.001)
        let sides: (before: String, after: String) = WaveMath.between([(text: "chaos", at: 0.6), (text: "and", at: 1.5)], held)
        XCTAssertEqual(sides.before, "chaos")
        XCTAssertEqual(sides.after, "and")
        XCTAssertNil(WaveMath.pause(file.pauses, near: 1.8, reach: 0.25), "dragged past, it lets go")
    }

    func testAShortSongHasNoLoopMark() {
        var s = EditSound(kind: "song", name: "Song", from: 0, start: 0, length: 20, full: 30)
        s.loopFrom = 0
        XCTAssertEqual(WaveMath.rounds(s), [])
        let effect = EditSound(kind: "effect", name: "Pop", from: 0, start: 0, length: 70, full: 30)
        XCTAssertEqual(WaveMath.rounds(effect), [])
    }
}
