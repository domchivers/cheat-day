import XCTest
@testable import CheatDays

/// 22 Nov, design/templates-pro-mockup.html: what plays as a template's filled is what's made.
final class TemplateCutTests: XCTestCase {
    private let a = Clip(source: URL(fileURLWithPath: "/tmp/a.mov"), length: 9, start: 0, end: 9)
    private let b = Clip(source: URL(fileURLWithPath: "/tmp/b.mov"), length: 9, start: 0, end: 9)
    private let template = EditTemplate.all[0]

    private var slots: [EditTemplate.Slot] {
        [EditTemplate.Slot(name: "Breakfast"), EditTemplate.Slot(name: "Lunch"), EditTemplate.Slot(name: "Dinner")]
    }

    func testAClipUsedTwiceHasItsOwnMomentInEach() {
        let chosen: (clips: [Clip], slots: [Int]) = TemplateCut.picked(library: [a], filled: [a.id, a.id], moments: [1: 4])
        XCTAssertEqual(chosen.clips.map { (c: Clip) -> Double in c.start }, [0, 4])
        XCTAssertNotEqual(chosen.clips[0].id, chosen.clips[1].id)
        let again: (clips: [Clip], slots: [Int]) = TemplateCut.picked(library: [a], filled: [a.id, a.id], moments: [1: 5])
        XCTAssertEqual(chosen.clips[1].id, again.clips[1].id, "the same copy as it's cut again")
    }

    func testEmptySlotsAreLeftOutAndTheRestKeepTheirWords() {
        let cut: TemplateCut = TemplateCut.make(template, library: [a, b], filled: [a.id, nil, b.id], moments: [:], slots: slots, music: nil)
        XCTAssertEqual(cut.slots, [0, 2])
        XCTAssertEqual(cut.words.map { (w: EditText) -> String in w.text }, ["Breakfast", "Dinner"])
        XCTAssertNil(cut.start(of: 1))
        XCTAssertEqual(cut.start(of: 0), 0)
    }

    func testTheChosenMomentIsWhatPlays() {
        let cut: TemplateCut = TemplateCut.make(template, library: [a], filled: [a.id, nil, nil], moments: [0: 3], slots: slots, music: nil)
        XCTAssertEqual(cut.clip(of: 0)?.start ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(cut.total, 2, accuracy: 0.001)
    }

    func testBlankWordsShowNothing() {
        let blank: [EditTemplate.Slot] = [EditTemplate.Slot(name: "", detail: "")]
        let cut: TemplateCut = TemplateCut.make(template, library: [a], filled: [a.id], moments: [:], slots: blank, music: nil)
        XCTAssertTrue(cut.words.isEmpty)
    }

    func testTheSongRunsAsLongAsTheVideo() {
        let song = EditSound(kind: "song", name: "Song", from: 0, start: 0, length: 30, full: 30)
        let music = TemplateMusic(song: song, beats: [])
        let cut: TemplateCut = TemplateCut.make(template, library: [a], filled: [a.id, nil, nil], moments: [:], slots: slots, music: music)
        XCTAssertEqual(cut.sounds.first?.length ?? 0, cut.total, accuracy: 0.001)
    }

    func testACardGoesRoundItsSlots() {
        let two: [EditTemplate.Slot] = [EditTemplate.Slot(name: "A", beats: 2), EditTemplate.Slot(name: "B", beats: 4)]
        XCTAssertEqual(TemplateReel.length(two), 3, accuracy: 0.001)
        XCTAssertEqual(TemplateReel.at(0.5, slots: two).slot, 0)
        XCTAssertEqual(TemplateReel.at(1.5, slots: two).slot, 1)
        XCTAssertEqual(TemplateReel.at(3.5, slots: two).slot, 0)
    }
}
