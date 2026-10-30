import XCTest
@testable import CheatDays

/// The word after lunch and dinner: what counts as mostly bread, and as veg.
@MainActor
final class MealCheckTests: XCTestCase {
    private func food(_ name: String, _ kcal: Int) -> JSON { ["name": name, "kcal": kcal] }

    func testToastOnlyIsBread() {
        XCTAssertTrue(Store.breadHeavy([food("Toast with butter", 260)]))
        XCTAssertTrue(Store.breadHeavy([food("Ham sandwich", 350), food("Apple", 60)]))
    }

    func testAProperMealIsNot() {
        XCTAssertFalse(Store.breadHeavy([food("Salmon fillet", 300), food("Rice", 200), food("Broccoli", 30)]))
        XCTAssertFalse(Store.breadHeavy([food("Chicken curry", 500), food("Naan bread", 150)]), "a side of bread isn't the meal")
    }

    private func serving(_ name: String, _ kcal: Int, protein: Double) -> JSON {
        ["name": name, "kcal": kcal, "kcalPerServing": kcal, "pServ": protein, "cServ": 0, "fServ": 0]
    }

    func testToastAloneIsALightDinner() {
        XCTAssertTrue(Store.shared.isLight([serving("Toast with jam", 310, protein: 8)], meal: "Dinner"))
    }

    func testEggsOnToastIsAMeal() {
        XCTAssertFalse(Store.shared.isLight([serving("Toast", 180, protein: 7), serving("Scrambled eggs", 200, protein: 14)], meal: "Dinner"),
                       "bread with something proper on it is fine")
        XCTAssertFalse(Store.shared.isLight([serving("Ham sandwich", 350, protein: 18)], meal: "Lunch"))
    }

    func testCaloriesOnlyIsNotJudged() {
        XCTAssertFalse(Store.shared.isLight([food("Chicken curry", 600)], meal: "Dinner"), "no macros: unknown, not light")
        XCTAssertFalse(Store.shared.isLight([serving("Tea", 30, protein: 1)], meal: "Lunch"), "a cup of tea isn't a meal")
    }

    func testVegIsSpotted() {
        let veg = try! NSRegularExpression(pattern: Store.vegWords, options: .caseInsensitive)
        func has(_ s: String) -> Bool { veg.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        XCTAssertTrue(has("Chicken, potatoes and peas"))
        XCTAssertTrue(has("Side salad"))
        XCTAssertFalse(has("Toast with jam"))
        XCTAssertFalse(has("Peanut butter"), "pea in peanut isn't peas")
    }
}
