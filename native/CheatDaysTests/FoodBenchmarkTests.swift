import XCTest
@testable import CheatDays

/// What the app's AI really wrote for recipes on 31 October, through the checks: each must land near the reference.
@MainActor
final class FoodBenchmarkTests: XCTestCase {
    private func ing(_ name: String, _ grams: Double, _ kcal: Double, _ p: Double = 0, _ c: Double = 0, _ f: Double = 0) -> JSON {
        ["name": name, "amount": "\(Int(grams)) g", "grams": grams, "kcal": kcal, "protein_g": p, "carbs_g": c, "fat_g": f]
    }
    private func out(_ i: JSON) -> JSON { FoodReference.checked([i]).items[0] }

    func testKingfishAndChuckComeOutRight() {
        let fish = out(ing("Kingfish fillet, skinless and boneless", 250, 257, 45, 0, 8))
        XCTAssertEqual(num(fish["kcal"]) ?? 0, 365, accuracy: 10)
        XCTAssertEqual(num(fish["protein_g"]) ?? 0, 57, accuracy: 2)
        XCTAssertEqual(num(out(ing("Beef chuck steak", 818, 2045, 172, 0, 147))["kcal"]) ?? 0, 1636, accuracy: 10)
    }

    func testChickenThighFilletsAreRaw() {
        XCTAssertEqual(num(out(ing("Chicken Thigh Fillets", 300, 630, 54, 0, 45))["kcal"]) ?? 0, 363, accuracy: 5)
        XCTAssertEqual(num(out(ing("Chicken thigh, skin on", 300, 630, 54, 0, 45))["kcal"]) ?? 0, 630, accuracy: 40)
    }

    func testFryingOilCountsWhatsAbsorbed() {
        let oil = out(ing("Vegetable Oil for frying", 400, 3536, 0, 0, 400))
        XCTAssertEqual(num(oil["kcal"]) ?? 0, 442, accuracy: 5)
        XCTAssertEqual(num(oil["grams"]), 50)
        XCTAssertEqual(num(out(ing("Olive oil", 30, 265, 0, 0, 30))["kcal"]), 265, "a normal spoon of oil is left alone")
    }

    func testCocoa() { XCTAssertEqual(num(out(ing("Cocoa powder", 40, 92, 7.8, 9.2, 5.4))["kcal"]) ?? 0, 131, accuracy: 2) }

    func testOnlyThePlainRawFoodMatches() {
        for name in ["Chicken stock", "Smoked salmon", "Fish sauce", "Canned tuna", "Grilled chicken breast", "Peanut butter", "Chicken salad", "Beef burger"] {
            XCTAssertNil(FoodReference.match(name), name)
        }
        XCTAssertEqual(FoodReference.match("Sashimi grade Atlantic salmon, cubed")?.name, "Salmon")
        XCTAssertEqual(FoodReference.match("Lean beef mince")?.name, "Beef mince, lean")
        XCTAssertEqual(FoodReference.match("Beef mince")?.name, "Beef mince")
    }

    func testAGoodNumberIsLeftAlone() {
        let (x, changed) = FoodReference.corrected(ing("Salmon fillet", 150, 312, 30, 0, 20))
        XCTAssertFalse(changed)
        XCTAssertEqual(num(x["kcal"]), 312)
    }

    func testADatabaseRowMustBeTheSameFood() {
        XCTAssertFalse(FoodReference.sameFood(asked: "Crustaceans, shrimp, mixed species, raw", got: "Crustaceans, shrimp, mixed species, canned"))
        XCTAssertFalse(FoodReference.sameFood(asked: "Oats", got: "Oats, puffed"))
        XCTAssertFalse(FoodReference.sameFood(asked: "Peanut butter, smooth", got: "Peanut butter, smooth, reduced fat"))
        XCTAssertTrue(FoodReference.sameFood(asked: "Rice, cooked", got: "Rice, white, cooked"))
    }

    func testAlcoholIsntFlagged() {
        XCTAssertTrue(Sanity.check(name: "Dry red wine", grams: 250, kcal: 210, p: 0, c: 7, f: 0).flags.isEmpty)
    }

    // round two: what the AI wrote for new dishes
    func testCookedNumbersOnRawChickenAreFixed() {
        XCTAssertEqual(num(out(ing("Chicken breast, skinless", 300, 495, 93, 0, 11))["kcal"]) ?? 0, 360, accuracy: 5)
    }

    func testProteinOffIsFixedToo() {
        let steak = out(ing("Scotch Fillet Steak", 250, 650, 35, 0, 55))
        XCTAssertEqual(num(steak["protein_g"]) ?? 0, 47.5, accuracy: 1)
    }

    func testBonesAndWholeFishDontCount() {
        XCTAssertEqual(num(out(ing("Whole fresh Australian snapper", 700, 770, 133, 0, 20))["kcal"]) ?? 0, 315, accuracy: 5)
        XCTAssertEqual(num(out(ing("Chicken drumsticks", 500, 860, 85, 0, 55))["kcal"]) ?? 0, 580, accuracy: 5)
        XCTAssertEqual(num(out(ing("Boneless kingfish fillet", 100, 146, 23, 0, 5))["kcal"]), 146)
    }

    func testAProteinDishWithoutProteinIsFlagged() {
        let items = [ing("Butter", 115, 828), ing("Sugar", 200, 800), ing("Eggs", 100, 143, 13, 1, 10)]
        XCTAssertNotNil(FoodReference.protein(promisedBy: "Protein brownie", in: items))
        XCTAssertNil(FoodReference.protein(promisedBy: "Brownie", in: items))
    }
}
