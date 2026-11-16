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

    func testAPepperoniPizzaIsItsClassicPepperoni() {
        // a pizza place's names often leave out "pizza"
        XCTAssertEqual(Takeaway.onMenu(["pepperoni pizza"], crust).want, ["Classic Pepperoni, large 11 inch"])
    }

    func testADishItHasStaysAsSaid() {
        let r = Takeaway.onMenu(["capricciosa"], crust)
        XCTAssertEqual(r.want, ["capricciosa"])
        XCTAssertTrue(r.plain.isEmpty && r.missing.isEmpty)
    }

    func testABaseIsAWayNotADish() {
        // "They do a protein pizza base": not "Crust's menu doesn't have a protein pizza base"
        let r = Takeaway.onMenu(["protein pizza base"], crust)
        XCTAssertTrue(r.missing.isEmpty)
        XCTAssertEqual(r.ways, ["protein pizza base"], "said its numbers aren't out, and planned on the usual base")
        XCTAssertTrue(r.want.isEmpty)
    }

    func testABaseTheMenuListsIsPlannedOnIt() {
        let hp = Takeaway.Item(name: "Classic Pepperoni, high protein base, 10.5 inch", kind: "main", tier: "energy", kcal: 950, p: 62, c: 70, f: 36)
        let r = Takeaway.onMenu(["pepperoni pizza", "high protein base"], crust + [hp])
        XCTAssertTrue(r.ways.isEmpty && r.missing.isEmpty)
        XCTAssertEqual(r.want, [hp.name], "one pizza on that base, not the pizza and the base as two")
    }

    func testABaseOnlyAnotherPizzaHasLeavesTheirPizza() {
        let other = Takeaway.Item(name: "Crust Supreme, high protein base, 10.5 inch", kind: "main", tier: "energy", kcal: 1028, p: 50, c: 100, f: 32)
        let r = Takeaway.onMenu(["pepperoni pizza", "high protein base"], crust + [other])
        XCTAssertEqual(r.ways, ["high protein base"], "said its numbers aren't out for theirs")
        XCTAssertEqual(r.want, ["Classic Pepperoni, large 11 inch"], "their pepperoni, not swapped for the supreme")
    }

    func testALookupAgainKeepsItsProteinEstimate() {
        let was: JSON = ["items": [["name": "Pesto Chicken Club pizza", "published": "energy", "kj": 5560, "kcal": 1329, "protein_g": 50, "carbs_g": 120, "fat_g": 55] as JSON]]
        let now: JSON = ["items": [["name": "Pesto Chicken Club pizza", "published": "energy", "kj": 5560, "kcal": 1329, "protein_g": 60, "carbs_g": 110, "fat_g": 58] as JSON,
                                   ["name": "Classic Pepperoni", "published": "energy", "kj": 4040, "kcal": 966, "protein_g": 40, "carbs_g": 105, "fat_g": 38] as JSON]]
        let out = list(Takeaway.steady(now, was: was)["items"])
        XCTAssertEqual(num(out[0]["protein_g"]), 50, "same pizza, same kJ: the same estimate")
        XCTAssertEqual(num(out[1]["protein_g"]), 40, "a new one keeps its own")
        let full: JSON = ["items": [["name": "Pesto Chicken Club pizza", "published": "full", "kj": 5560, "kcal": 1329, "protein_g": 62, "carbs_g": 110, "fat_g": 58] as JSON]]
        XCTAssertEqual(num(list(Takeaway.steady(full, was: was)["items"])[0]["protein_g"]), 62, "a published number wins")
    }

    func testADeliveryAppIsntARestaurant() {
        // "Some high protein meals on door dash?" looked for DoorDash's own menu
        for n in ["DoorDash", "door dash", "Uber Eats", "Menulog"] { XCTAssertTrue(Takeaway.deliveryApp(n), n) }
        for n in ["Crust", "Gami", "Doorstep Dumplings"] { XCTAssertFalse(Takeaway.deliveryApp(n), n) }
    }

    func testTheMannerWordsGo() {
        XCTAssertEqual(Takeaway.core("High protein pepperoni pizza"), "pepperoni pizza")
        XCTAssertEqual(Takeaway.core("large low carb burger"), "burger")
    }
}
