import XCTest
@testable import CheatDays

/// Stage D: keyframed movement eased between keys, an overlay with none staying put, and a split sharing a clip's movement.
final class EditMotionTests: XCTestCase {
    func testMovementEasesBetweenKeys() {
        let keys = [MoveKey(at: 0, size: 1), MoveKey(at: 2, x: 0.7, size: 1.2)]
        let base = MoveKey(at: 0)
        XCTAssertEqual(MoveKey.value(keys, at: -1, base: base).size, 1, accuracy: 0.0001)     // before the first: the first
        XCTAssertEqual(MoveKey.value(keys, at: 1, base: base).size, 1.1, accuracy: 0.0001)    // halfway (eased, still the middle)
        XCTAssertEqual(MoveKey.value(keys, at: 1, base: base).x, 0.6, accuracy: 0.0001)
        XCTAssertLessThan(MoveKey.value(keys, at: 0.5, base: base).size, 1.05)                  // eased: slow to start
        XCTAssertEqual(MoveKey.value(keys, at: 5, base: base).size, 1.2, accuracy: 0.0001)    // after the last: the last
        XCTAssertEqual(MoveKey.value([], at: 1, base: MoveKey(at: 0, x: 0.3)).x, 0.3, accuracy: 0.0001)
    }

    func testOverlayWithoutKeysStaysWhereItIs() {
        let p = EditPip(source: URL(fileURLWithPath: "/tmp/p.mov"), length: 4, from: 2, x: 0.2, y: 0.8, size: 0.5)
        let m = p.place(at: 3)
        XCTAssertEqual(m.x, 0.2, accuracy: 0.0001); XCTAssertEqual(m.y, 0.8, accuracy: 0.0001); XCTAssertEqual(m.size, 0.5, accuracy: 0.0001)
        XCTAssertEqual(p.to, 6, accuracy: 0.0001)
    }

    func testSplitSharesTheMovement() throws {
        var c = Clip(source: URL(fileURLWithPath: "/tmp/x.mov"), length: 20, start: 0, end: 10)
        c.moves = [MoveKey(at: 0), MoveKey(at: 3, size: 1.1), MoveKey(at: 8, size: 1.3)]
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 5))
        XCTAssertEqual(a.moves.map { $0.at }, [0, 3])
        XCTAssertEqual(b.moves.map { $0.at }, [3])   // 8 s in the clip is 3 s into the second half
    }
}
