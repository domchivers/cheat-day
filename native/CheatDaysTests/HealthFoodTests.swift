import XCTest
@testable import CheatDays

/// A day's foods as Apple Health's meals (25 Nov, design/health-food-mockup.html).
@MainActor
final class HealthFoodTests: XCTestCase {
    private let day = "2026-11-25"
    private func at(_ h: Int, _ m: Int = 0) -> String {
        ISO8601DateFormatter().string(from: DayKey.date(day).addingTimeInterval(Double(h * 3600 + m * 60)))
    }

    func testMealsAddUp() {
        let items: [JSON] = [
            ["name": "Oats", "meal": "Breakfast", "kcal": 300, "grams": 80, "kcal100": 375, "p100": 12.5, "c100": 60, "f100": 7.5, "addedAt": at(8, 5)],
            ["name": "Banana", "meal": "Breakfast", "kcal": 100, "addedAt": at(8, 10)],
            ["name": "Curry", "meal": "Dinner", "kcal": 650, "addedAt": at(19, 10)]
        ]
        let meals = HealthSync.foodMeals(items, day: day, now: DayKey.date(day).addingTimeInterval(23 * 3600))
        XCTAssertEqual(meals.map(\.meal), ["Breakfast", "Dinner"], "empty meals aren't sent")
        XCTAssertEqual(meals[0].kcal, 400)
        XCTAssertEqual(meals[1].kcal, 650)
        XCTAssertEqual(DayKey.string(meals[0].at), day)
        XCTAssertEqual(Calendar.current.component(.minute, from: meals[0].at), 10, "the last one added in the meal")
    }

    func testNoMealIsOtherAndNeverInTheFuture() {
        let items: [JSON] = [["name": "Bar", "kcal": 200]]
        let now = DayKey.date(day).addingTimeInterval(9 * 3600)
        let meals = HealthSync.foodMeals(items, day: day, now: now)
        XCTAssertEqual(meals.map(\.meal), ["Other"])
        XCTAssertLessThanOrEqual(meals[0].at, now, "midday's usual time is still to come at 9am")
    }

    func testSignatureIgnoresRounding() {
        let a = HealthSync.FoodMeal(meal: "Lunch", kcal: 500.2, p: 30.4, c: 50, f: 10, at: Date())
        var b = a; b.kcal = 499.9
        XCTAssertEqual(a.sig, b.sig)
        b.p = 31
        XCTAssertNotEqual(a.sig, b.sig)
    }
}
