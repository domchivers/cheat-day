import XCTest
@testable import CheatDays

/// The check-in maths matches the web app's.
@MainActor
final class CheckInTests: XCTestCase {
    func testOddReadingIsIgnored() {
        let days = (0..<10).map { DayKey.shift("2026-10-01", days: $0) }
        var kg = [82.0, 81.9, 81.8, 81.8, 81.7, 81.6, 81.6, 81.5, 81.4, 81.4]
        kg[5] = 70.0   // someone else stepped on the scale
        let t = Trend.fit(days: days, values: kg)
        XCTAssertTrue(t.odd[5])
        XCTAssertFalse(t.odd[4])
        XCTAssertEqual(t.fit[9], 81.4, accuracy: 0.2)
    }

    func testUsingTheSuggestionScalesTheWeek() {
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON, "budget": 1600, "dayBudgets": ["6": 2000] as JSON,
                       "plan": ["kcal": 1657, "macros": ["p": 140, "c": 150, "f": 55] as JSON] as JSON, "goals": ["p": 140, "c": 150, "f": 55] as JSON]
        Store.apply(["type": "checkIn", "week": "2026-10-05", "use": true, "suggest": 1760, "now": 1660, "burn": 2300, "at": 1], to: &d, today: "2026-10-09")
        XCTAssertEqual(str(d["checkInSeen"]), "2026-10-05")
        XCTAssertEqual(num(d["budget"]), 1700)
        XCTAssertEqual(num(dict(d["dayBudgets"])["6"]), 2120)
        XCTAssertEqual(num(dict(d["plan"])["kcal"]), 1760)
        XCTAssertEqual(num(dict(dict(d["plan"])["macros"])["c"]), 175)
        XCTAssertEqual(num(dict(d["goals"])["c"]), 175)
        XCTAssertEqual(num(dict(d["plan"])["learnedBurn"]), 2300)
    }

    func testKeepingOnlyMarksItSeen() {
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON, "budget": 1600]
        Store.apply(["type": "checkIn", "week": "2026-10-05", "use": false, "suggest": 1760, "now": 1600, "at": 1], to: &d, today: "2026-10-09")
        XCTAssertEqual(num(d["budget"]), 1600)
        XCTAssertEqual(str(d["checkInSeen"]), "2026-10-05")
    }
}
