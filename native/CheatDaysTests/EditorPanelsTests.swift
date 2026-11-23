import XCTest
import UIKit
import SwiftUI
@testable import CheatDays

/// 22 Nov, design/editor-panels-mockup.html: every editor panel on the one sheet.
final class EditorPanelsTests: XCTestCase {
    func testKeepPitchIsSavedAndOlderDraftsKeepIt() throws {
        var c = Clip(source: URL(fileURLWithPath: "/tmp/c.mov"), length: 10, start: 0, end: 10)
        XCTAssertTrue(c.keepsPitch)
        c.keepPitch = false
        let back: Clip = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertFalse(back.keepsPitch)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        json["keepPitch"] = nil
        let old: Clip = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.keepsPitch)
    }

    func testARetypedCaptionStaysTiedToItsVoiceover() {
        let voice = UUID()
        let old: [EditText.Word] = [EditText.Word(text: "hello", at: 8, clip: voice, file: "v.m4a", src: 1.0),
                                    EditText.Word(text: "friend", at: 8.6, clip: voice, file: "v.m4a", src: 1.6)]
        let now: [EditText.Word] = EditText.retyped(old, parts: ["hello", "my", "friend"], from: 8, to: 9)
        XCTAssertEqual(now.map(\.text), ["hello", "my", "friend"])
        XCTAssertTrue(now.allSatisfy { $0.clip == voice && $0.file == "v.m4a" })
        let src: [Double] = now.compactMap(\.src)
        XCTAssertEqual(src.count, 3)
        for (a, b) in zip(src, [1.0, 1.3, 1.6]) { XCTAssertEqual(a, b, accuracy: 0.0001) }
        // typed in by hand, with nothing to tie to: none made up
        let typed: [EditText.Word] = EditText.retyped([EditText.Word(text: "hi", at: 2)], parts: ["hi", "there"], from: 2, to: 3)
        XCTAssertTrue(typed.allSatisfy { $0.src == nil && $0.clip == nil })
    }

    func testEveryGlyphDrawsInsideItsSquare() {
        let square = CGRect(x: 0, y: 0, width: 48, height: 48)
        for g in [Glyph.send, .save, .repost, .comment, .grid, .videos, .tagged] {
            let path: Path = GlyphShape(glyph: g).path(in: square)
            XCTAssertFalse(path.isEmpty)
            XCTAssertTrue(square.insetBy(dx: -1, dy: -1).contains(path.boundingRect), "\(g) spills out")
        }
    }

    @MainActor func testAScreenshotsDateIsNeverInTheFuture() {
        let now: Date = DayKey.date("2026-11-23").addingTimeInterval(19 * 3600)
        let dec9: Date = DayKey.date("2026-12-09").addingTimeInterval(8 * 3600)
        XCTAssertEqual(Calendar.current.component(.year, from: WeighInSheet.past(dec9, now: now)), 2025)
        let nov21: Date = DayKey.date("2026-11-21").addingTimeInterval(8 * 3600)
        XCTAssertEqual(WeighInSheet.past(nov21, now: now), nov21)
    }

    @MainActor func testProgressTabsOnlyForMeasuresWithALine() {
        let rows: [JSON] = [
            ["day": "2026-08-01", "weight": 84.0, "muscle": 36.0],
            ["day": "2026-08-20", "weight": 83.5, "muscle": 36.2],
            ["day": "2026-11-10", "weight": 80.5, "fat": 18.0, "bmi": 24.9],
            ["day": "2026-11-22", "weight": 79.7, "fat": 17.6],
        ]
        let keys: [String] = ProgressPage.tabs(rows, today: "2026-11-23").map(\.key)
        XCTAssertEqual(keys, ["weight", "fat"], "one BMI reading, and muscle only long ago: no tabs")
    }

    @MainActor func testCaptionsMovedByHandStillRideTheirVoice() {
        let voice = EditSound(kind: "voice", name: "Voice 1", file: nil, from: 8, length: 3)
        let tied = EditText(kind: "caption", text: "hello", from: 8, to: 8.5,
                            words: [EditText.Word(text: "hello", at: 8, clip: voice.id, file: "v.m4a", src: 0)])
        let nudged = EditText(kind: "caption", text: "my friend", from: 9, to: 10, words: [EditText.Word(text: "my", at: 9)])
        let elsewhere = EditText(kind: "caption", text: "later", from: 14, to: 15, words: [EditText.Word(text: "later", at: 14)])
        let title = EditText(kind: "text", text: "Dinner", from: 8, to: 10)
        let ride: [UUID] = MultiClipEditor.riding([tied, nudged, elsewhere, title], on: voice).map(\.id)
        XCTAssertEqual(ride, [tied.id, nudged.id])
    }

    func testEveryBundledFontIsInTheApp() {
        let named: [String] = ["Anton-Regular", "BebasNeue-Regular", "ArchivoBlack-Regular", "Bangers-Regular", "Pacifico-Regular",
                               "Lobster-Regular", "CaveatBrush-Regular", "AbrilFatface-Regular", "Righteous-Regular",
                               "PressStart2P-Regular", "Monoton-Regular", "DancingScript-Regular"]
        for n in named { XCTAssertNotNil(UIFont(name: n, size: 20), n + " isn't loaded") }
        XCTAssertEqual(EditText.fonts.count, 17)
    }

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
