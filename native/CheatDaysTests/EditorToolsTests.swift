import XCTest
@testable import CheatDays

/// 22 Nov, design/editor-panels-mockup.html: the previews, the record button, choosing a song.
final class EditorToolsTests: XCTestCase {
    func testAHoldLetGoBeforeItsTimerIsHeardStillStops() {
        var p = VoicePress()
        _ = p.pressed(countdown: false)
        XCTAssertEqual(p.released(after: 0.9), VoicePress.Act.stop)
    }

    func testAQuickTapHeardLateIsStillATap() {
        var p = VoicePress()
        XCTAssertEqual(p.pressed(countdown: false), VoicePress.Act.start)
        XCTAssertEqual(p.heldLong(), VoicePress.Act.none)
        XCTAssertEqual(p.released(after: 0.1), VoicePress.Act.none)
        XCTAssertEqual(p.phase, VoicePress.Phase.going)
    }

    func testALongPressStillStopsAsItsLetGo() {
        var p = VoicePress()
        _ = p.pressed(countdown: false)
        _ = p.heldLong()
        XCTAssertEqual(p.released(after: 1.2), VoicePress.Act.stop)
    }

    func testATapStartsAndATapStops() {
        var p = VoicePress()
        XCTAssertEqual(p.pressed(countdown: false), VoicePress.Act.start)
        XCTAssertEqual(p.released(), VoicePress.Act.none)
        XCTAssertEqual(p.phase, VoicePress.Phase.going)
        XCTAssertEqual(p.pressed(countdown: false), VoicePress.Act.stop)
        XCTAssertEqual(p.released(), VoicePress.Act.none)
    }

    func testAHoldTalksTillItsLetGo() {
        var p = VoicePress()
        XCTAssertEqual(p.pressed(countdown: false), VoicePress.Act.start)
        XCTAssertEqual(p.heldLong(), VoicePress.Act.none, "started already")
        XCTAssertEqual(p.released(), VoicePress.Act.stop)
    }

    func testWithACountdownATapCountsFirst() {
        var p = VoicePress()
        XCTAssertEqual(p.pressed(countdown: true), VoicePress.Act.none)
        XCTAssertEqual(p.released(), VoicePress.Act.count)
        XCTAssertEqual(p.counted(), VoicePress.Act.start)
        XCTAssertEqual(p.pressed(countdown: true), VoicePress.Act.stop)
    }

    func testACountdownTappedIsOff() {
        var p = VoicePress()
        _ = p.pressed(countdown: true)
        _ = p.released()
        XCTAssertEqual(p.pressed(countdown: true), VoicePress.Act.stopCount)
        XCTAssertEqual(p.counted(), VoicePress.Act.none)
    }

    func testHeldWithACountdownItStartsWithoutOne() {
        var p = VoicePress()
        _ = p.pressed(countdown: true)
        XCTAssertEqual(p.heldLong(), VoicePress.Act.start)
        XCTAssertEqual(p.released(), VoicePress.Act.stop)
    }

    func testTheMeterShowsQuietTalking() {
        XCTAssertEqual(VoiceMeter.shown(0.25), 0.5, accuracy: 0.001)
        let meter = VoiceMeter()
        meter.add(1)
        let levels: [Float] = meter.snapshot()
        XCTAssertEqual(levels.count, VoiceMeter.room)
        XCTAssertEqual(levels.first, 1)
        XCTAssertEqual(levels.last, 0)
    }

    func testSongsAreFoundInAnyMood() {
        let found: [Song] = SongSearch.find(Music.all, mood: "Chill", words: "boss metal")
        XCTAssertTrue(found.contains { (s: Song) -> Bool in s.id == "boss-battle-8-metal" })
        let chill: [Song] = SongSearch.find(Music.all, mood: "Chill", words: " ")
        XCTAssertFalse(chill.isEmpty)
        XCTAssertTrue(chill.allSatisfy { (s: Song) -> Bool in s.mood == "Chill" })
        XCTAssertEqual(SongSearch.find(Music.all, mood: SongSearch.all, words: "").count, Music.all.count)
    }

    func testASongsPartStaysInsideIt() {
        XCTAssertEqual(SongSearch.start(-4, length: 90), 0)
        XCTAssertEqual(SongSearch.start(85, length: 90), 60)
        XCTAssertEqual(SongSearch.start(22.04, length: 90), 22, accuracy: 0.001)
        XCTAssertEqual(SongSearch.levels("09").last, 1)
    }

    func testAPreviewRestsAtEachEnd() {
        XCTAssertEqual(PreviewArt.progress(at: 0.2, length: 1, rest: 0.5), 0)
        XCTAssertEqual(PreviewArt.progress(at: 1, length: 1, rest: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(PreviewArt.progress(at: 1.8, length: 1, rest: 0.5), 1)
    }

    @MainActor func testShapesFitTheirTiles() {
        let square: CGSize = ShapeStrip.size("1:1", own: 1)
        XCTAssertEqual(square.width, square.height, accuracy: 0.001)
        let wide: CGSize = ShapeStrip.size("Original", own: 16.0 / 9.0)
        XCTAssertLessThanOrEqual(wide.width, 64.001)
    }
}
