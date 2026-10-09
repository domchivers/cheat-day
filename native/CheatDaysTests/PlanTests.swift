import XCTest
@testable import CheatDays

/// The sign-up plan: the same maths as the web app's computePlan, the cheat day keeps the weekly total, and saving it keeps old cheat day plans.
@MainActor
final class PlanTests: XCTestCase {
    func testCheatDayKeepsTheWeeklyTotal() {
        var q = PlanInput()
        q.sex = "m"; q.age = 34; q.height = 178; q.weight = 84; q.activity = 1.375
        q.trainDays = 4; q.trainType = "weights"; q.goal = "lose"; q.pace = -0.5
        q.spread = "cheat"; q.cheatDay = 6; q.cheatSize = 1.3
        let r = Plan.compute(q)
        XCTAssertEqual(r.kcal, 2050)
        XCTAssertEqual(r.cheat, 2670)
        XCTAssertEqual(r.everyday, 1950)
        XCTAssertEqual(r.days[6], 2670)
        XCTAssertEqual(r.p, 134)
        XCTAssertLessThan(abs(r.everyday * 6 + (r.cheat ?? 0) - r.kcal * 7), 40)
    }

    func testNeverBelowTheSafeMinimum() {
        var q = PlanInput()
        q.sex = "f"; q.age = 60; q.height = 155; q.weight = 52; q.activity = 1.2; q.trainDays = 0; q.goal = "lose"; q.pace = -0.75; q.spread = "same"
        XCTAssertGreaterThanOrEqual(Plan.compute(q).kcal, 1200)
    }

    func testHomeWorkoutsSwapTheMachines() {
        let week = Training.week(days: 4, experience: "some", kit: "dumbbells")
        XCTAssertEqual(week.map(\.name), ["Upper", "Lower", "Upper", "Lower"])
        let names = week.flatMap { $0.moves.map(\.name) }
        XCTAssertTrue(names.contains("Goblet squat"))
        XCTAssertFalse(names.contains("Leg press"))
        for d in week { XCTAssertEqual(Set(d.moves.map(\.name)).count, d.moves.count) }
    }

    func testSavingThePlanKeepsCheatDayPlans() {
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON, "budget": 1600,
                       "prefs": ["cheatPlans": ["2026-10-11": ["title": "Yum cha"] as JSON] as JSON] as JSON]
        Store.apply(["type": "plan", "budget": 1950, "dayBudgets": ["6": 2670] as JSON, "goals": ["p": 134, "c": 200, "f": 67] as JSON,
                     "plan": ["kcal": 2050] as JSON, "prefs": ["loves": ["Pizza"]] as JSON, "weightKg": 84, "goalWeight": 78, "day": "2026-10-09"],
                    to: &d, today: "2026-10-09")
        XCTAssertEqual(num(d["budget"]), 1950)
        XCTAssertEqual(d["onboarded"] as? Bool, true)
        XCTAssertEqual(dict(d["prefs"])["loves"] as? [String], ["Pizza"])
        XCTAssertNotNil(dict(dict(d["prefs"])["cheatPlans"])["2026-10-11"])
        XCTAssertEqual(num(dict(d["goalStart"])["weight"]), 84)
    }

    func testPickingACheatDayLater() {
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON, "budget": 2000, "plan": ["spread": "same"] as JSON]
        Store.apply(["type": "cheatSpread", "day": 6, "cheat": 2600, "everyday": 1900], to: &d, today: "2026-10-09")
        XCTAssertEqual(num(d["budget"]), 1900)
        XCTAssertEqual(num(dict(d["dayBudgets"])["6"]), 2600)
        XCTAssertEqual(str(dict(d["plan"])["spread"]), "cheat")
    }
}
