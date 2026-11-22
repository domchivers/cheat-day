import SwiftUI
import XCTest
@testable import CheatDays

/// 22 Nov, "lets just do all the fixes in one": Undo, clip trims that keep their captions, music to the end, the
/// caption's colours and moving, and the timeline's glide.
final class EditorFixesTests: XCTestCase {
    // MARK: Undo

    func testUndoTakesASettledChangeAsOneStep() {
        var h = EditHistory<Int>()
        h.start(0)
        h.touched()
        XCTAssertTrue(h.canUndo, "there's something to undo before it settles")
        h.record(3)
        XCTAssertEqual(h.undo(from: 3), 0)
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.redo(from: 0), 3)
    }

    func testUndoBeforeItSettlesUndoesThatChange() {
        var h = EditHistory<Int>()
        h.start(1)
        h.touched()
        XCTAssertEqual(h.undo(from: 2), 1)
        XCTAssertEqual(h.redo(from: 1), 2)
    }

    func testAChangeThatEndsWhereItBeganIsNoStep() {
        var h = EditHistory<Int>()
        h.start(5)
        h.touched()
        h.record(5)
        XCTAssertFalse(h.canUndo)
    }

    func testANewChangeLeavesNothingToRedo() {
        var h = EditHistory<Int>()
        h.start(0)
        h.record(1)
        XCTAssertEqual(h.undo(from: 1), 0)
        h.record(7)
        XCTAssertFalse(h.canRedo)
    }

    // MARK: clip trims

    private func captioned() -> (clip: Clip, texts: [EditText]) {
        let clip = Clip(source: URL(fileURLWithPath: "/tmp/talk.mov"), length: 5, start: 0, end: 5)
        var words: [EditText.Word] = []
        words.append(EditText.Word(text: "we", at: 1))
        words.append(EditText.Word(text: "glaze", at: 2))
        words.append(EditText.Word(text: "pots", at: 3))
        let caption = EditText(kind: "caption", text: "we glaze pots", from: 1, to: 3.5, words: words)
        return (clip, EditOverlays.anchor([caption], clips: [clip]))
    }

    func testWordsTrimmedOffComeBack() {
        let made: (clip: Clip, texts: [EditText]) = captioned()
        var short: Clip = made.clip
        short.end = 2.5
        let cut = ClipCuts.trimmed(made.texts, kept: [], clips: [short], sounds: [])
        XCTAssertEqual(cut.texts.map { (t: EditText) -> String in t.text }, ["we glaze"])
        XCTAssertEqual(cut.kept.map { (t: EditText) -> String in t.text }, ["pots"])

        let back = ClipCuts.trimmed(cut.texts, kept: cut.kept, clips: [made.clip], sounds: [])
        XCTAssertEqual(back.texts.map { (t: EditText) -> String in t.text }, ["we glaze pots"])
        XCTAssertTrue(back.kept.isEmpty)
    }

    func testACaptionTrimmedOffWholeComesBack() {
        let made: (clip: Clip, texts: [EditText]) = captioned()
        var short: Clip = made.clip
        short.end = 0.5
        let cut = ClipCuts.trimmed(made.texts, kept: [], clips: [short], sounds: [])
        XCTAssertTrue(cut.texts.isEmpty)
        let back = ClipCuts.trimmed(cut.texts, kept: cut.kept, clips: [made.clip], sounds: [])
        XCTAssertEqual(back.texts.map { (t: EditText) -> String in t.text }, ["we glaze pots"])
    }

    func testAWordDoesntComeBackOutOfTurnAfterASplit() throws {
        let made: (clip: Clip, texts: [EditText]) = captioned()
        var short: Clip = made.clip
        short.end = 2.5
        let cut = ClipCuts.trimmed(made.texts, kept: [], clips: [short], sounds: [])
        let left: EditText = try XCTUnwrap(cut.texts.first)
        let halves: (EditText, EditText) = try XCTUnwrap(EditOverlays.split(left, at: 1))

        let back = ClipCuts.trimmed([halves.0, halves.1], kept: cut.kept, clips: [made.clip], sounds: [])
        let inOrder: [EditText] = back.texts.sorted { (a: EditText, b: EditText) -> Bool in a.from < b.from }
        XCTAssertEqual(inOrder.map { (t: EditText) -> String in t.text }, ["we", "glaze", "pots"])
    }

    func testASeparatedSoundsWordsGoBackToItsClip() {
        let clip = Clip(source: URL(fileURLWithPath: "/tmp/talk.mov"), length: 5, start: 0, end: 5)
        let sound = EditSound(kind: "clip", name: "Clip 1 sound", file: clip.source, from: 0, length: 5)
        var word = EditText.Word(text: "hi", at: 1)
        word.clip = sound.id
        word.src = 1
        let caption = EditText(kind: "caption", text: "hi", from: 1, to: 2, words: [word])
        let back: [EditText] = CaptionLayers.returned([caption], from: sound, clip: clip)
        XCTAssertEqual(back.first?.words?.first?.clip, clip.id)
        XCTAssertEqual(back.first?.words?.first?.file, "talk.mov")
    }

    func testTheFiveOldHighlightsKeepTheirBlackInk() {
        for name in ["yellow", "green", "red", "blue", "white"] {
            var t = EditText(kind: "caption", text: "hi", from: 0, to: 1)
            t.highlight = ColourCode.hex(named: name)
            XCTAssertEqual(t.popInk, .black, name)
        }
    }

    // MARK: music

    private func song(length: Double) -> EditSound {
        var s = EditSound(kind: "song", name: "Song", file: URL(fileURLWithPath: "/tmp/s.m4a"), from: 0, start: 5, length: length,
                          full: 35, beats: [6, 20])
        s.loopFrom = 5
        return s
    }

    func testASongGoesRoundToTheEnd() {
        let parts: [EditSound.Stretch] = song(length: 70).stretches(until: 70)
        let expected: [EditSound.Stretch] = [
            EditSound.Stretch(from: 0, fileStart: 5, length: 30),
            EditSound.Stretch(from: 30, fileStart: 5, length: 30),
            EditSound.Stretch(from: 60, fileStart: 5, length: 10),
        ]
        XCTAssertEqual(parts, expected)
        XCTAssertEqual(song(length: 70).beatTimes(until: 70), [1, 15, 31, 45, 61])
    }

    func testAnOlderSongDrawnOutGoesRoundToo() {
        var s: EditSound = song(length: 40)
        s.loopFrom = nil
        XCTAssertEqual(s.stretches(until: 100).map { (p: EditSound.Stretch) -> Double in p.fileStart }, [5, 5])
    }

    func testAVoiceoverDoesntGoRound() {
        let v = EditSound(kind: "voice", name: "Voice 1", from: 1, start: 0, length: 9, full: 4)
        XCTAssertEqual(v.stretches(until: 20, fileEnd: 4), [EditSound.Stretch(from: 1, fileStart: 0, length: 4)])
    }

    // MARK: captions

    func testColoursThereAndBack() {
        for hex in ["#FF6A2B", "#2C1E5C", "#FFFFFF", "#000000", "#5CA8F2"] {
            XCTAssertEqual(ColourCode.hex(ColourCode.hsb(hex)), hex)
        }
        XCTAssertEqual(ColourCode.typed("2c1e5c"), "#2C1E5C")
        XCTAssertNil(ColourCode.typed("2c1e5"))
    }

    func testAnOldCaptionLooksAsItDid() {
        let old = EditText(kind: "caption", text: "hi", from: 0, to: 1)
        XCTAssertEqual(old.hex(of: .words), "#FFFFFF")
        XCTAssertEqual(old.hex(of: .box), "#000000")
        XCTAssertEqual(old.alpha(of: .box), 0.7)
        XCTAssertEqual(old.alpha(of: .lit), 1)
        XCTAssertEqual(old.hex(of: .lit), "#FFCC33")
    }

    func testADragHoldsOnTheMiddle() {
        let near = OverlayDrag.place(fromX: 0.3, fromY: 0.7, dx: 58, dy: 10, width: 300, height: 600)
        XCTAssertEqual(near.x, 0.5)
        XCTAssertTrue(near.middleX)
        XCTAssertFalse(near.middleY)
    }

    func testPlacedByHandIsntLiftedOverAVoiceover() {
        let voice = EditSound(kind: "voice", name: "Voice 1", from: 0, length: 4)
        var theirs = EditText(kind: "caption", text: "over", x: 0.5, y: 0.76, from: 0, to: 2)
        theirs.voice = voice.id
        var own = EditText(kind: "caption", text: "under", x: 0.5, y: 0.74, from: 0, to: 2)
        own.byHand = true
        let drawn: [EditText] = CaptionLayers.placed([own, theirs], sounds: [voice])
        XCTAssertEqual(drawn.first?.y, 0.74)
    }

    // MARK: the timeline

    func testAFlickGlidesAndStops() {
        XCTAssertEqual(TimelineGlide.travel(velocity: 1000, after: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(TimelineGlide.travel(velocity: 1000, after: 60), 499.5, accuracy: 1)
        XCTAssertLessThan(TimelineGlide.speed(velocity: 1000, after: 3), TimelineGlide.stops)
    }

    func testATickAsTheLinePassesAnEdge() {
        XCTAssertTrue(TimelineGlide.crossed([2], from: 1, to: 3))
        XCTAssertTrue(TimelineGlide.crossed([2], from: 3, to: 2))
        XCTAssertFalse(TimelineGlide.crossed([2], from: 2, to: 3), "not again as it leaves")
    }
}
