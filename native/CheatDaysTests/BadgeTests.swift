import XCTest
@testable import CheatDays

/// The achievements match the website's: same list and XP, and earning only ever adds.
@MainActor
final class BadgeTests: XCTestCase {
    func testTheListMatchesTheWebsite() {
        XCTAssertEqual(Badge.all.count, 73)
        XCTAssertEqual(Set(Badge.all.map(\.id)).count, 73)
        for b in Badge.all { XCTAssertEqual(XPRules.badges[b.id], b.xp, b.id) }
    }

    func testEarningOnlyAdds() {
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON, "seenBadges": ["first"], "goalWins": ["2026-10-05:log"]]
        Store.apply(["type": "badges", "ids": ["first", "streak3"]], to: &d, today: "2026-10-09")
        Store.apply(["type": "goalWins", "keys": ["2026-10-05:log", "2026-10-05:under"]], to: &d, today: "2026-10-09")
        XCTAssertEqual(d["seenBadges"] as? [String], ["first", "streak3"])
        XCTAssertEqual(d["goalWins"] as? [String], ["2026-10-05:log", "2026-10-05:under"])
    }

    func testOneOffsAndTiers() {
        let early = Badge.all.first { $0.id == "early" }!, ten = Badge.all.first { $0.id == "days10" }!
        XCTAssertTrue(early.earned(["earlyBird": 1]))
        XCTAssertFalse(early.earned(["earlyBird": 0]))
        XCTAssertFalse(ten.earned(["daysLogged": 9]))
        XCTAssertTrue(ten.earned(["daysLogged": 10]))
    }
}
