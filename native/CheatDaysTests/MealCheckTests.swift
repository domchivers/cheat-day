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

    func testVegIsSpotted() {
        let veg = try! NSRegularExpression(pattern: Store.vegWords, options: .caseInsensitive)
        func has(_ s: String) -> Bool { veg.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        XCTAssertTrue(has("Chicken, potatoes and peas"))
        XCTAssertTrue(has("Side salad"))
        XCTAssertFalse(has("Toast with jam"))
        XCTAssertFalse(has("Peanut butter"), "pea in peanut isn't peas")
    }
}
