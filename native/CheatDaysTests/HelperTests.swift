import XCTest
@testable import CheatDays

/// What the helper sets for a family member: a budget for the week, and changes to logged food.
@MainActor
final class HelperTests: XCTestCase {
    private let today = "2026-10-09"

    func testWeekBudgetBecomesEverydayPlusDayBudgets() {
        var d: JSON = ["budget": 1600, "day": ["date": today, "items": [Any]()] as JSON, "plan": ["kcal": 1600] as JSON]
        Store.apply(["type": "override", "updatedAt": "2026-10-09T10:00:00Z", "budget": 1500, "dayBudgets": ["6": 2000] as JSON, "planKcal": 1571], to: &d, today: today)
        XCTAssertEqual(num(d["budget"]), 1500)
        XCTAssertEqual(num(dict(d["dayBudgets"])["6"]), 2000)
        XCTAssertEqual(num(dict(d["plan"])["kcal"]), 1571)
        XCTAssertEqual(str(d["overrideApplied"]), "2026-10-09T10:00:00Z")
        XCTAssertEqual(Store.baseBudget("2026-10-10", in: d), 2000, "10 October 2026 is a Saturday")
    }

    func testFoodEditOnAPastDayRecountsTheDay() {
        var d: JSON = ["day": ["date": today, "items": [Any]()] as JSON,
                       "history": [["date": "2026-10-08", "kcal": 900, "items": [["name": "Toast", "kcal": 300] as JSON, ["name": "Soup", "kcal": 600] as JSON] as [Any]] as JSON] as [Any]]
        Store.apply(["type": "helperEdit", "day": "2026-10-08", "name": "Soup", "oldKcal": 600, "newKcal": 250, "remove": false, "at": nowMs()], to: &d, today: today)
        let h = list(d["history"])[0]
        XCTAssertEqual(num(h["kcal"]), 550)
        XCTAssertEqual(num(list(h["items"])[1]["kcal"]), 250)
    }

    func testRemovingTodaysFoodLeavesATombstone() {
        var d: JSON = ["day": ["date": today, "items": [["id": "t1", "name": "Crisps", "kcal": 180] as JSON] as [Any]] as JSON]
        Store.apply(["type": "helperEdit", "day": today, "name": "crisps", "oldKcal": 180, "newKcal": 0, "remove": true, "at": nowMs()], to: &d, today: today)
        XCTAssertTrue(list(dict(d["day"])["items"]).isEmpty)
        XCTAssertNotNil(dict(d["tombs"])["item:t1"])
    }
}
