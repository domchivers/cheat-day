import XCTest
@testable import CheatDays

/// "Thinking protein pepperoni pizza from Crust?" (16 Nov): Crust's menu has pepperoni pizzas, but none with "protein" in
/// its name, so the pepperoni was dropped as not on the menu and a Pesto Chicken Club pizza (1,329 kcal) was planned.
final class TakeawayMannerTests: XCTestCase {
    private let crust = [
        Takeaway.Item(name: "Classic Pepperoni, large 11 inch", kind: "main", tier: "energy", kcal: 966, p: 38, c: 105, f: 38),
        Takeaway.Item(name: "Pesto Chicken Club pizza", kind: "main", tier: "energy", kcal: 1329, p: 50, c: 120, f: 55),
        Takeaway.Item(name: "Capricciosa, large 11 inch", kind: "main", tier: "energy", kcal: 946, p: 36, c: 105, f: 33),
    ]

    func testAProteinPepperoniIsItsPepperoniPizza() {
        let r = Takeaway.onMenu(["protein pepperoni pizza"], crust)
        XCTAssertEqual(r.want, ["Classic Pepperoni, large 11 inch"], "Crust's name for it has no 'pizza'")
        XCTAssertTrue(r.missing.isEmpty)
        XCTAssertEqual(r.plain.first?.said, "protein pepperoni pizza")
    }

    func testADishItDoesntSellIsStillMissing() {
        let r = Takeaway.onMenu(["protein burrito"], crust)
        XCTAssertEqual(r.missing, ["protein burrito"])
        XCTAssertTrue(r.want.isEmpty)
    }

    func testAChickenWrapAtAPlaceWithoutWrapsIsStillMissing() {
        XCTAssertEqual(Takeaway.onMenu(["chicken wrap"], crust).missing, ["chicken wrap"], "not swapped for any chicken dish")
    }

    func testADishItHasStaysAsSaid() {
        let r = Takeaway.onMenu(["capricciosa"], crust)
        XCTAssertEqual(r.want, ["capricciosa"])
        XCTAssertTrue(r.plain.isEmpty && r.missing.isEmpty)
    }

    func testTheMannerWordsGo() {
        XCTAssertEqual(Takeaway.core("High protein pepperoni pizza"), "pepperoni pizza")
        XCTAssertEqual(Takeaway.core("large low carb burger"), "burger")
    }
}
