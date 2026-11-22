import XCTest
@testable import CheatDays

/// 22 Nov: a voiceover's captions replaced the video's own. Those are kept now, switched off on a row of their own,
/// the voiceover's below it (design/voiceover-caption-layers-mockup.html).
final class CaptionLayersTests: XCTestCase {
    private let voice = EditSound(kind: "voice", name: "Voice 1", file: URL(fileURLWithPath: "/tmp/v.m4a"), from: 4, length: 3)
    private var voices: Set<UUID> { [voice.id] }

    private func caption(_ text: String, _ from: Double, _ to: Double, by v: UUID? = nil) -> EditText {
        let parts = text.split(separator: " ").map(String.init)
        let step = (to - from) / Double(max(1, parts.count))
        var words: [EditText.Word] = []
        for (i, part) in parts.enumerated() { words.append(EditText.Word(text: part, at: from + step * Double(i))) }
        var t = EditText(kind: "caption", text: text, style: "Pop", x: 0.5, y: 0.76, from: from, to: to, words: words)
        t.voice = v
        return t
    }

    func testTheVideosOwnAreKeptAndSwitchedOffOnlyUnderTheVoiceover() {
        let all = [caption("before", 0, 2), caption("we glaze", 4.5, 6), caption("after", 8, 9)]
        let out = CaptionLayers.cover(all, by: voice, voices: voices)
        XCTAssertEqual(out.map(\.text), ["before", "we glaze", "after"], "none deleted")
        XCTAssertEqual(out.map { $0.hidden == true }, [false, true, false])
    }

    func testOneAcrossItsEdgeIsCutBetweenWords() {
        let out = CaptionLayers.cover([caption("a b c d", 3, 5)], by: voice, voices: voices)
        XCTAssertEqual(out.map(\.text), ["a b", "c d"])
        XCTAssertEqual(out.map { $0.hidden == true }, [false, true])
        XCTAssertEqual(out[0].to, 4, accuracy: 0.001, "not into the voiceover")
    }

    func testTakingTheVoiceoverOffSwitchesTheOriginalsBackOn() {
        let covered = CaptionLayers.cover([caption("we glaze", 4.5, 6)], by: voice, voices: voices)
        let said = caption("day three", 4.2, 6.5, by: voice.id)
        let out = CaptionLayers.removed(voice.id, texts: covered + [said], sounds: [voice])
        XCTAssertEqual(out.map(\.text), ["we glaze"])
        XCTAssertNil(out[0].hidden)
    }

    func testMovingTheVoiceoverSwitchesOffWhatsUnderItNow() {
        let all = CaptionLayers.cover([caption("first", 1, 2), caption("second", 4.5, 6)], by: voice, voices: voices)
        var moved = voice
        moved.from = 0.5
        XCTAssertEqual(CaptionLayers.settled(all, sounds: [moved]).map { $0.hidden == true }, [true, false])
    }

    func testARowSwitchedBackOnStaysOn() {
        var all = CaptionLayers.cover([caption("second", 4.5, 6)], by: voice, voices: voices)
        all[0].hidden = nil
        XCTAssertNil(CaptionLayers.settled(all, sounds: [voice])[0].hidden)
    }

    func testWithBothOnTheOriginalsSitAbove() {
        let own = caption("we glaze", 4.5, 6), said = caption("day three", 4.5, 6, by: voice.id)
        let shown = CaptionLayers.placed([own, said], sounds: [voice])
        XCTAssertLessThan(shown[0].y, shown[1].y - 0.05)
        XCTAssertEqual(shown[1].y, 0.76, accuracy: 0.001)
        var off = own
        off.hidden = true
        XCTAssertEqual(CaptionLayers.placed([off, said], sounds: [voice]).map(\.text), ["day three"])
    }

    func testTheVoiceoversGoDirectlyBelowIt() {
        let music = UUID(), gone = UUID()
        let on = caption("before", 0, 2), said = caption("day three", 4.5, 6, by: voice.id)
        var off = caption("we glaze", 4.5, 6)
        off.hidden = true
        let rows = CaptionLayers.rows([[gone], [voice.id], [music]], texts: [on, off, said], sounds: [voice], live: [voice.id, music])
        XCTAssertEqual(rows, [[on.id], [off.id], [voice.id], [said.id], [music]])
    }

    func testLayersMayRunOverEachOtherButNotThemselves() {
        let all = [caption("own", 4, 6), caption("next", 5, 7), caption("said", 4.5, 8, by: voice.id)]
        let out = CaptionLayers.clamped(all, voices: voices)
        XCTAssertEqual(out[0].to, 5, accuracy: 0.001)
        XCTAssertEqual(out[1].to, 7, accuracy: 0.001)
        XCTAssertEqual(out[2].to, 8, accuracy: 0.001)
    }

    @MainActor func testSwitchedOffIsntInTheFinishedVideo() {
        var off = caption("we glaze", 4.5, 6)
        off.hidden = true
        XCTAssertTrue(EditOverlays.pieces([off], frame: CGSize(width: 1080, height: 1920)).isEmpty)
    }

    /// 22 Nov recording: the voiceover's start let go a moment past "hello", and that caption was gone for good.
    func testTrimmingAVoiceoverNeverLosesItsCaptions() {
        var v: EditSound = voice
        v.full = 3
        func said(_ text: String, _ at: Double) -> EditText {
            let word = EditText.Word(text: text, at: at, clip: v.id, src: at - 4)
            var t = EditText(kind: "caption", text: text, from: at, to: at + 0.5, words: [word])
            t.voice = v.id
            return t
        }
        let all: [EditText] = [said("hello", 4.1), said("my", 5), said("friend", 6)]
        var short: EditSound = v
        short.from = 4.5; short.start = 0.5; short.length = 2.5
        let cut = CaptionLayers.trimmed(all, clips: [], sounds: [short])
        XCTAssertEqual(cut.texts.map(\.text), ["my", "friend"])
        XCTAssertEqual(cut.sounds[0].cut?.map(\.text), ["hello"], "kept on the voiceover")
        // trimmed again, it's still kept
        var shorter: EditSound = cut.sounds[0]
        shorter.from = 5.5; shorter.start = 1.5; shorter.length = 1.5
        let more = CaptionLayers.trimmed(cut.texts, clips: [], sounds: [shorter])
        XCTAssertEqual(more.texts.map(\.text), ["friend"])
        var back: EditSound = more.sounds[0]
        back.from = 4; back.start = 0; back.length = 3
        let out = CaptionLayers.trimmed(more.texts, clips: [], sounds: [back])
        XCTAssertEqual(out.texts.sorted { $0.from < $1.from }.map(\.text), ["hello", "my", "friend"])
        XCTAssertNil(out.sounds[0].cut)
    }

    func testACaptionCutInTheMiddleGetsItsWordsBack() {
        var v: EditSound = voice
        v.full = 3
        let words: [EditText.Word] = [EditText.Word(text: "hello", at: 4.1, clip: v.id, src: 0.1), EditText.Word(text: "friend", at: 4.8, clip: v.id, src: 0.8)]
        var t = EditText(kind: "caption", text: "hello friend", from: 4.1, to: 5.3, words: words)
        t.voice = v.id
        var short: EditSound = v
        short.from = 4.5; short.start = 0.5; short.length = 2.5
        let cut = CaptionLayers.trimmed([t], clips: [], sounds: [short])
        XCTAssertEqual(cut.texts.map(\.text), ["friend"])
        var back: EditSound = cut.sounds[0]
        back.from = 4; back.start = 0; back.length = 3
        XCTAssertEqual(CaptionLayers.trimmed(cut.texts, clips: [], sounds: [back]).texts.map(\.text), ["hello friend"])
    }

    func testAVoiceoversHandleIsntHeldOnCaptions() {
        let bars: [(from: Double, to: Double, caption: Bool, off: Bool)] = [
            (from: 1, to: 2, caption: true, off: false), (from: 3, to: 4, caption: true, off: true), (from: 5, to: 6, caption: false, off: false)]
        XCTAssertEqual(TimelineRows.snapTargets(fixed: [0], bars: bars, movingCaption: false), [0, 5, 6])
        XCTAssertEqual(TimelineRows.snapTargets(fixed: [0], bars: bars, movingCaption: true), [0, 1, 2, 5, 6], "never what's switched off")
    }

    func testADraftFromBeforeLayersStillOpens() throws {
        let old = caption("we glaze", 4.5, 6)
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("hidden"), "left out when it's on, as an old draft has it")
        XCTAssertNil(try JSONDecoder().decode(EditText.self, from: data).hidden)
    }
}
