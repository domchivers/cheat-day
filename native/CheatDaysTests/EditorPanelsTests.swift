import XCTest
@testable import CheatDays

/// 22 Nov, design/editor-panels-mockup.html: every editor panel on the one sheet.
final class EditorPanelsTests: XCTestCase {
    func testARowSwitchedOffIsntPlayedOrMade() {
        var voice = EditSound(kind: "voice", name: "Voice 1", file: nil, from: 2, length: 5)
        let song = EditSound(kind: "song", name: "Be Chillin", file: nil, from: 0, length: 45)
        voice.off = true
        XCTAssertEqual(EditSound.heard([voice, song]).map(\.id), [song.id])
        var pip = EditPip(source: URL(fileURLWithPath: "/tmp/a.mov"), length: 3, from: 1)
        XCTAssertEqual(EditPip.shown([pip]).count, 1)
        pip.off = true
        XCTAssertTrue(EditPip.shown([pip]).isEmpty)
    }

    func testOlderDraftsReadWithEveryRowOn() throws {
        let song = EditSound(kind: "song", name: "Be Chillin", file: nil, from: 0, length: 45)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(song)) as? [String: Any])
        json["off"] = nil
        let back: EditSound = try JSONDecoder().decode(EditSound.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.off)
        XCTAssertEqual(EditSound.heard([back]).count, 1)
    }

    func testTheListFollowsWhatsSaidAsItPlays() {
        let early = EditText(kind: "caption", text: "hello my friend", from: 8, to: 9)
        let said = UUID()
        XCTAssertEqual(CaptionFocus.row(picked: early, saying: said, at: 14, playing: true), said)
        XCTAssertEqual(CaptionFocus.row(picked: early, saying: said, at: 14, playing: false), said)
        XCTAssertEqual(CaptionFocus.row(picked: early, saying: said, at: 8.5, playing: false), early.id)
    }

    func testPausedLaterTheOneBeingSaidShows() {
        let early = EditText(kind: "caption", text: "how's it going?", from: 9, to: 10)
        let later = EditText(kind: "caption", text: "bury it", from: 17, to: 18)
        let both: [EditText] = [early, later]
        XCTAssertNil(CaptionFocus.held(picked: early.id, in: both, at: 17.5, playing: false))
        XCTAssertEqual(CaptionFocus.held(picked: early.id, in: both, at: 9.5, playing: false), early.id)
        XCTAssertEqual(CaptionFocus.held(picked: early.id, in: both, at: 12, playing: false), early.id)
    }

    @MainActor func testTheSpeedRulerHoldsOnItsStops() {
        XCTAssertEqual(SpeedRuler.speed(at: 0.05), 1)
        XCTAssertEqual(SpeedRuler.speed(at: 0.97), 2)
        XCTAssertEqual(SpeedRuler.speed(at: -2.5), 0.25)
        XCTAssertEqual(SpeedRuler.speed(at: 9), 4)
        XCTAssertEqual(SpeedRuler.speed(at: log2(1.5)), 1.5, accuracy: 0.001)
    }

    @MainActor func testSpeedsAreNamedShort() {
        XCTAssertEqual(SpeedRuler.name(0.25), "0.25×")
        XCTAssertEqual(SpeedRuler.name(0.5), "0.5×")
        XCTAssertEqual(SpeedRuler.name(4), "4×")
    }

    @MainActor func testResetKnowsTheFilterFromItsAdjusting() {
        let parts: (name: String, tunes: [String: Double]) = MultiClipEditor.lookParts("Warm;b=20.0;c=-5.0")
        XCTAssertEqual(parts.name, "Warm")
        XCTAssertEqual(parts.tunes, ["b": 20, "c": -5])
        XCTAssertTrue(MultiClipEditor.lookParts("Normal").tunes.isEmpty)
    }

    @MainActor func testTimesToTheTenth() {
        XCTAssertEqual(MultiClipEditor.tenths(8), "00:08.0")
        XCTAssertEqual(MultiClipEditor.tenths(65.25), "01:05.3")
    }

    func testASongsWaveGoesRoundWithIt() {
        var s = EditSound(kind: "song", name: "Song", from: 0, start: 0, length: 40, full: 20)
        s.loopFrom = 0
        XCTAssertEqual(s.waveAcross([0.2, 0.8], from: 0, to: 20, count: 4), [0.2, 0.8, 0.2, 0.8])
    }

    func testAVoiceoversWaveIsJustIts() {
        let v = EditSound(kind: "voice", name: "Voice 1", from: 3, start: 1, length: 2, full: 5)
        XCTAssertEqual(v.waveAcross([0.1, 0.9], from: 1, to: 3, count: 2), [0.1, 0.9])
        XCTAssertTrue(v.waveAcross([], from: 1, to: 3, count: 2).isEmpty, "not read yet")
    }
}
