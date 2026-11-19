import XCTest
@testable import CheatDays

/// The multi-clip editor's split: the two halves meet where it was cut, and the sound kept stays where it was in time.
final class ClipJoinTests: XCTestCase {
    private func clip(_ start: Double, _ end: Double) -> Clip {
        Clip(source: URL(fileURLWithPath: "/tmp/x.mov"), length: 20, start: start, end: end)
    }

    func testSplitMeetsWhereItWasCut() throws {
        let (a, b) = try XCTUnwrap(ClipJoin.split(clip(2, 12), at: 4))
        XCTAssertEqual(a.start, 2); XCTAssertEqual(a.end, 6)
        XCTAssertEqual(b.start, 6); XCTAssertEqual(b.end, 12)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.duration + b.duration, 10, accuracy: 0.0001)
    }

    func testSplitTooNearAnEndDoesNothing() {
        XCTAssertNil(ClipJoin.split(clip(2, 12), at: 0.1))
        XCTAssertNil(ClipJoin.split(clip(2, 12), at: 9.9))
    }

    func testSoundKeptStaysInPlace() throws {
        var c = clip(0, 10); c.soundStart = 3; c.soundEnd = 5
        // cut after the sound: the first half has it all, the second none
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 7))
        XCTAssertEqual(a.heardStart, 3); XCTAssertEqual(a.heardEnd, 5)
        XCTAssertLessThanOrEqual(b.heardEnd - b.heardStart, 0)
        // cut through it: each half keeps its own part
        let (x, y) = try XCTUnwrap(ClipJoin.split(c, at: 4))
        XCTAssertEqual(x.heardStart, 3); XCTAssertEqual(x.heardEnd, 4)
        XCTAssertEqual(y.heardStart, 4); XCTAssertEqual(y.heardEnd, 5)
    }

    func testFadesStayAtTheOuterEnds() throws {
        var c = clip(0, 10); c.fadeIn = 1; c.fadeOut = 2
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 5))
        XCTAssertEqual(a.fadeIn, 1); XCTAssertEqual(a.fadeOut, 0)
        XCTAssertEqual(b.fadeIn, 0); XCTAssertEqual(b.fadeOut, 2)
    }

    /// Volume keyframes eased between, fades on top, and a split keeping each half its own keyframes.
    func testLevelFollowsKeyframesAndFades() throws {
        var c = clip(0, 10)
        c.keys = [VolumeKey(at: 2, volume: 1), VolumeKey(at: 4, volume: 0.2)]
        XCTAssertEqual(c.level(at: 1), 1, accuracy: 0.001)       // before the first: its level
        XCTAssertEqual(c.level(at: 3), 0.6, accuracy: 0.001)     // halfway between
        XCTAssertEqual(c.level(at: 8), 0.2, accuracy: 0.001)     // after the last: its level
        c.fadeOut = 2
        XCTAssertEqual(c.level(at: 9), 0.1, accuracy: 0.001)     // half way through the fade out
        XCTAssertEqual(c.level(at: 10), 0, accuracy: 0.001)
        XCTAssertTrue(c.turns.contains(8))                        // where the fade out starts
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 3))
        XCTAssertEqual(a.keys.map { $0.at }, [2]); XCTAssertEqual(b.keys.map { $0.at }, [4])
    }

    /// At another speed a clip lasts longer or shorter in the video; a split keeps its speed in both halves.
    func testSpeedSetsHowLongItLasts() throws {
        var c = clip(2, 12); c.speed = 0.5
        XCTAssertEqual(c.span, 20, accuracy: 0.001)
        c.speed = 4
        XCTAssertEqual(c.span, 2.5, accuracy: 0.001)
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 4))
        XCTAssertEqual(a.speed, 4); XCTAssertEqual(b.speed, 4)
        XCTAssertEqual(a.span + b.span, 2.5, accuracy: 0.001)
    }

    /// A draft saved before speed existed still opens, at normal speed.
    func testOldDraftClipDecodes() throws {
        let old = #"{"id":"6B1F2C1E-0000-4000-8000-000000000001","source":"file:///x.mov","length":20,"start":1,"end":9,"still":false,"soundOn":true,"volume":0.5,"fadeIn":0,"fadeOut":0,"keys":[]}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(old.utf8))
        XCTAssertEqual(c.speed, 1); XCTAssertEqual(c.volume, 0.5); XCTAssertEqual(c.end, 9)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}
