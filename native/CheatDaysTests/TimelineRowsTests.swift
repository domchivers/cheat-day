import XCTest
@testable import CheatDays

/// 22 Nov: "can't go to a new line?" A new row's offered only where dropping on it changes something.
final class TimelineRowsTests: XCTestCase {
    private let caption = UUID(), voice = UUID(), effect = UUID()

    func testABarAloneAtTheBottomIsNotOfferedARowThatDoesNothing() {
        let rows: [[UUID]] = [[caption], [voice]]
        XCTAssertFalse(TimelineRows.canAddRow(for: voice, rows: rows))
        XCTAssertEqual(TimelineRows.moved(voice, from: 1, to: 2, rows: rows, fits: false), rows, "it would be back where it was")
        XCTAssertTrue(TimelineRows.canAddRow(for: caption, rows: rows))
        XCTAssertEqual(TimelineRows.moved(caption, from: 0, to: 2, rows: rows, fits: false), [[voice], [caption]])
    }

    func testABarSharingTheBottomRowGoesToANewOne() {
        let rows: [[UUID]] = [[caption], [voice, effect]]
        XCTAssertTrue(TimelineRows.canAddRow(for: effect, rows: rows))
        XCTAssertEqual(TimelineRows.moved(effect, from: 1, to: 2, rows: rows, fits: false), [[caption], [voice], [effect]])
    }

    func testOntoARowItFitsOnOrARowOfItsOwnBesideIt() {
        let rows: [[UUID]] = [[caption], [voice], [effect]]
        XCTAssertEqual(TimelineRows.moved(effect, from: 2, to: 1, rows: rows, fits: true), [[caption], [voice, effect]])
        XCTAssertEqual(TimelineRows.moved(effect, from: 2, to: 0, rows: rows, fits: false), [[effect], [caption], [voice]], "over it, going up")
        XCTAssertEqual(TimelineRows.moved(caption, from: 0, to: 1, rows: rows, fits: false), [[voice], [caption], [effect]], "past it, going down")
    }

    func testNoMoreThanTheTimelineShows() {
        var full: [[UUID]] = [[caption], [voice, effect]]
        while full.count < TimelineRows.most { full.append([UUID()]) }
        XCTAssertFalse(TimelineRows.canAddRow(for: effect, rows: full))
    }
}
