import XCTest
@testable import CheatDays

/// Saved meals and the budget page change the record the same way the website does.
@MainActor
final class MealsBudgetTests: XCTestCase {
    private func doc() -> JSON { ["day": ["date": "2026-10-09", "items": [Any]()] as JSON, "budget": 1600, "dayBudgets": ["6": 2400] as JSON] }

    func testSavingAMealReplacesItInPlace() {
        var d = doc()
        let meal: JSON = ["id": "m1", "name": "Stir fry", "portions": 2, "items": [["id": "a", "name": "Rice", "kcal": 400] as JSON]]
        Store.apply(["type": "saveMeal", "meal": meal], to: &d, today: "2026-10-09")
        var renamed = meal; renamed["name"] = "Chicken stir fry"
        Store.apply(["type": "saveMeal", "meal": renamed], to: &d, today: "2026-10-09")
        XCTAssertEqual(list(d["meals"]).count, 1)
        XCTAssertEqual(str(list(d["meals"])[0]["name"]), "Chicken stir fry")
    }

    func testADeletedMealStaysDeleted() {
        var d = doc()
        let meal: JSON = ["id": "m1", "name": "Stir fry", "items": [Any]()]
        Store.apply(["type": "saveMeal", "meal": meal], to: &d, today: "2026-10-09")
        Store.apply(["type": "deleteMeal", "id": "m1", "at": 1], to: &d, today: "2026-10-09")
        Store.apply(["type": "saveMeal", "meal": meal], to: &d, today: "2026-10-09")   // an old edit arriving late
        XCTAssertTrue(list(d["meals"]).isEmpty)
    }

    func testBudgetPageSetsEveryPart() {
        var d = doc()
        Store.apply(["type": "budget", "budget": 1800, "dayBudgets": JSON(), "eatBack": true], to: &d, today: "2026-10-09")
        XCTAssertEqual(num(d["budget"]), 1800)
        XCTAssertTrue(dict(d["dayBudgets"]).isEmpty)
        XCTAssertEqual(d["eatBack"] as? Bool, true)
    }

    func testDeletingAReadingLeavesATombstone() {
        var d = doc()
        Store.apply(["type": "body", "row": ["day": "2026-10-08", "weight": 82.4, "updatedAt": "2026-10-08T07:00:00Z"] as JSON], to: &d, today: "2026-10-09")
        Store.apply(["type": "deleteBody", "day": "2026-10-08", "at": 5], to: &d, today: "2026-10-09")
        XCTAssertTrue(list(d["body"]).isEmpty)
        XCTAssertEqual(num(dict(d["tombs"])["body:2026-10-08"]), 5)
    }

    // meals are in grams, including older saved ingredients that only had a serving
    func testMealsShowGrams() {
        let toast: JSON = ["name": "Toast", "kcal": 160, "kcalPer100": 265, "unitLabel": "slice", "kcalPerServing": 80]
        XCTAssertEqual(MealEditor.grams(toast) ?? 0, 60.4, accuracy: 0.1)            // worked out from its calories
        XCTAssertEqual(MealEditor.grams(["name": "Rice", "kcal": 200, "grams": 150]), 150)
        XCTAssertNil(MealEditor.grams(["name": "Mystery", "kcal": 200, "unitLabel": "portion", "kcalPerServing": 200]))
        let meal: JSON = ["name": "Stir fry", "source": "meal", "kcalPer100": 130, "unitLabel": "portion", "kcalPerServing": 520, "servingSize": 400]
        XCTAssertEqual(FoodMath.amountText(meal, kcal: 260), "200 g")
    }
}
