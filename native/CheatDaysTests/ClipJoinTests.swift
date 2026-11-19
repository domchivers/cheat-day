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
        var c = clip(0, 10); c.fadeIn = true; c.fadeOut = true
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 5))
        XCTAssertTrue(a.fadeIn); XCTAssertFalse(a.fadeOut)
        XCTAssertFalse(b.fadeIn); XCTAssertTrue(b.fadeOut)
    }
}
