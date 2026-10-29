import XCTest
@testable import CheatDays

/// The checks before numbers are logged, from real slips found while logging.
final class SanityTests: XCTestCase {
    func testCaloriesThatDontFitTheMacrosAreFixed() {
        // a cabbage salad card said 2 kcal with 5 g carbs
        let r = Sanity.check(name: "Cabbage salad", grams: 100, kcal: 2, p: 1, c: 5, f: 0)
        XCTAssertEqual(r.kcal, 24)
        XCTAssertFalse(r.flags.isEmpty)
        // and a sensible one passes untouched
        let ok = Sanity.check(name: "Cabbage", grams: 100, kcal: 25, p: 1.3, c: 5.8, f: 0.1)
        XCTAssertEqual(ok.kcal, 25)
        XCTAssertTrue(ok.flags.isEmpty)
    }

    func testProteinBeyondWhatTheFoodHasIsFlagged() {
        // "Aldi BBQ shredded chicken, 140 g" logged at 49 g protein: 35 g per 100 g
        let r = Sanity.check(name: "Aldi BBQ shredded chicken", grams: 140, kcal: 322, p: 49, c: 2, f: 20)
        XCTAssertTrue(r.flags.contains { $0.contains("protein per 100 g") })
        XCTAssertTrue(Sanity.check(name: "Aldi BBQ shredded chicken", grams: 140, kcal: 322, p: 35, c: 2, f: 20).flags.allSatisfy { !$0.contains("protein per 100 g") })
    }

    func testANearZeroDatabaseValueDoesntReplaceRealFood() {
        // the AI said 100 kcal for 400 g of cabbage; a per-gram value (2) read as per 100 g mustn't win
        XCTAssertFalse(Sanity.prefersDatabase(2, aiKcal: 100, grams: 400, name: "Cabbage"))
        XCTAssertTrue(Sanity.prefersDatabase(25, aiKcal: 100, grams: 400, name: "Cabbage"))
        // the AI's own near-zero still loses to a sensible value
        XCTAssertTrue(Sanity.prefersDatabase(25, aiKcal: 2, grams: 105, name: "Cabbage"))
    }

    func testFarApartTheOneThatFitsTheFoodWins() {
        // cooked rice: the AI said 650 per 100 g (dry rice), the database 130 (cooked)
        XCTAssertTrue(Sanity.prefersDatabase(130, aiKcal: 975, grams: 150, name: "Cooked rice"))
        // and a database row at 650 for cooked rice loses to the AI's 130
        XCTAssertFalse(Sanity.prefersDatabase(650, aiKcal: 195, grams: 150, name: "Cooked rice"))
    }

    func testSwapsAreLikeForLike() {
        XCTAssertTrue(FoodKind.swaps("Beef chuck steak", "Jindurra Station Beef Chuck"))
        XCTAssertTrue(FoodKind.swaps("Chicken thigh", "Beef mince"))          // protein for protein
        XCTAssertFalse(FoodKind.swaps("Beef chuck steak", "Kewpie mayo"))
        XCTAssertFalse(FoodKind.swaps("Beef chuck steak", "S&B curry sauce mix"))
        XCTAssertFalse(FoodKind.swaps("Beef chuck steak", "Greek yoghurt bowl"))
        XCTAssertTrue(FoodKind.swaps("Jasmine rice, cooked", "SunRice sushi rice"))
        XCTAssertEqual(FoodKind.of("Berg pepperoni"), .meat)
    }

    @MainActor func testADishsCaloriesPer100gRange() {
        XCTAssertEqual(CookedWeightCard.dishRange("Hearty Beef and Carrot Curry").hi, 200)
        XCTAssertEqual(CookedWeightCard.dishRange("Protein brownies").hi, 450)
    }

    @MainActor func testABodyFatGoalsWeight() {
        // 80 kg at 14.5% body fat, aiming for 13%: about 78 kg once a little lean loss is counted
        let g = Store.fatGoal(weight: 80, fatPct: 14.5, target: 13)
        XCTAssertEqual(g.weight, 78.2, accuracy: 0.15)
        XCTAssertEqual(g.fat / g.weight, 0.13, accuracy: 0.001)
    }

    func testRangesByKind() {
        XCTAssertEqual(Sanity.range("Muscle Nation protein powder")?.label, "protein powder")
        XCTAssertEqual(Sanity.range("Beef chuck, raw")?.label, "raw beef chuck")
        XCTAssertNil(Sanity.range("Berg pepperoni"))   // not a pepper
        XCTAssertNil(Sanity.range("Water"))
    }
}
