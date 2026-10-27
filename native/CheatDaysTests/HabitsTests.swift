import XCTest
@testable import CheatDays

/// The food habits: saved in prefs (so the website keeps them), kept when the plan is redone, read back as they were.
@MainActor
final class HabitsTests: XCTestCase {
    func testSavedAndKeptThroughANewPlan() {
        var d: JSON = ["prefs": ["loves": ["Pizza"]] as JSON, "updatedAt": 1]
        let beer = Habit(meal: "Snacks", name: "Beer", perWeek: 2)
        var tweaked = beer; tweaked.choice = "tweak"; tweaked.tweak = "2 pints, not 4"; tweaked.tweakSave = 360
        Store.apply(["type": "habits", "value": ["goals": ["Drink less"], "items": [tweaked.json]] as JSON], to: &d, today: "2026-10-27")
        XCTAssertEqual(dict(d["prefs"])["loves"] as? [String], ["Pizza"], "the rest of prefs stays")
        Store.apply(["type": "plan", "prefs": ["loves": ["Curry"]] as JSON], to: &d, today: "2026-10-27")
        let back = list(dict(dict(d["prefs"])["habits"])["items"]).map(Habit.init)
        XCTAssertEqual(back.first?.plan, "2 pints, not 4", "redoing the plan doesn't lose the habits")
        XCTAssertEqual(back.first?.weekSave, 720)
    }

    func testHowOften() {
        XCTAssertEqual(Habit(meal: "Breakfast", name: "Flat white", perWeek: 7).often, "daily")
        XCTAssertEqual(Habit(meal: "Dinner", name: "Stir fry", perWeek: 2.6).often, "3× a week")
        XCTAssertEqual(Habit(meal: "Lunch", name: "Soup").often, "")
        var kept = Habit(meal: "Snacks", name: "Popcorn", perWeek: 7); kept.swap = "Rice cakes"
        XCTAssertNil(kept.plan, "a kept food has nothing to change")
        XCTAssertEqual(kept.weekSave, 0)
    }
}
