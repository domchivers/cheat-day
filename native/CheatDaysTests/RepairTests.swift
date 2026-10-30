import XCTest
@testable import CheatDays

/// Food lost from past days, put back from each day's shared summary: only what's missing, never a deleted food.
@MainActor
final class RepairTests: XCTestCase {
    private func food(_ name: String, _ kcal: Int, _ at: String, meal: String = "Dinner") -> JSON {
        ["name": name, "kcal": kcal, "addedAt": at, "meal": meal]
    }

    // Monday filed with breakfast only; the summary friends saw that night has the whole day and a workout
    private var history: [JSON] {
        [["date": "2026-10-26", "kcal": 469, "items": [food("Protein Yoghurt Bowl", 469, "2026-10-25T23:34:34Z", meal: "Breakfast")], "workouts": [Any]()] as JSON]
    }
    private var shared: [JSON] {
        [["day": "2026-10-26", "items": [food("Protein Yoghurt Bowl", 469, "2026-10-25T23:34:34Z", meal: "Breakfast"),
                                         food("Beef mince gyudon", 369, "2026-10-26T07:35:48Z"),
                                         food("Rice", 195, "2026-10-26T05:28:14Z"),
                                         ["name": "Workout: Chest, Shoulders & Triceps, 101 min", "kcal": -684] as JSON]] as JSON]
    }

    func testFindsTheMissingDinner() {
        let found = Store.missingFood(history: history, shared: shared, since: "2026-07-01", before: "2026-10-30")
        XCTAssertEqual(found["2026-10-26"]?.items.map { str($0["name"]) }, ["Beef mince gyudon", "Rice"])
        XCTAssertEqual(found["2026-10-26"]?.workouts, 1)
    }

    func testAWholeDayIsLeftAlone() {
        var full = history
        full[0]["items"] = list(shared[0]["items"]).filter { (num($0["kcal"]) ?? 0) > 0 }
        XCTAssertTrue(Store.missingFood(history: full, shared: shared, since: "2026-07-01", before: "2026-10-30").isEmpty)
    }

    func testPutsItBackOnce() {
        var d: JSON = ["day": ["date": "2026-10-30", "items": [Any](), "workouts": [Any]()] as JSON, "history": history]
        let op: JSON = ["type": "restorePast", "date": "2026-10-26",
                        "items": [food("Beef mince gyudon", 369, "2026-10-26T07:35:48Z"), food("Rice", 195, "2026-10-26T05:28:14Z")],
                        "workouts": [["name": "Chest, Shoulders & Triceps", "minutes": 101, "kcal": 684] as JSON]]
        Store.applyRestore(op, to: &d)
        Store.applyRestore(op, to: &d)   // sent twice (a retry): still once
        let h = list(d["history"])[0]
        XCTAssertEqual(list(h["items"]).count, 3)
        XCTAssertEqual(num(h["kcal"]), 1033)
        XCTAssertEqual(list(h["workouts"]).count, 1)
    }

    func testAChangedAmountIsUpdatedNotDoubled() {
        // rice logged at 286, changed to 234 that evening; the half-day copy kept 286
        var d: JSON = ["history": [["date": "2026-09-21", "items": [food("Short grain rice, cooked", 286, "2026-09-21T08:00:00Z")]] as JSON]]
        Store.applyRestore(["type": "restorePast", "date": "2026-09-21", "items": [food("Short grain rice, cooked", 234, "2026-09-21T08:00:00Z")]], to: &d)
        let items = list(list(d["history"])[0]["items"])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(num(items[0]["kcal"]), 234)
    }

    func testADeletedFoodIsNeverAdded() {
        // History still has a brownie that was deleted that day: it's not in the summary, so nothing is missing for it,
        // and the repair never takes anything away either
        var h = history
        h[0]["items"] = list(h[0]["items"]) + [food("Low Cal Protein Brownie", 294, "2026-10-26T07:35:38Z", meal: "Snacks")]
        let found = Store.missingFood(history: h, shared: shared, since: "2026-07-01", before: "2026-10-30")
        XCTAssertFalse(found["2026-10-26"]?.items.contains { str($0["name"]) == "Low Cal Protein Brownie" } ?? true)
    }
}
