import XCTest
@testable import CheatDays

/// A cheat day plan's dishes are their parts checked against the food tables (CheatPlan.checked), as the assistant's
/// cards are. The parts here are from real answers (tools/ai-test/cheat-check.js, 16 Nov), including the two that the
/// test script's simple matcher got wrong: battered fried wings as baked lean wing, and hot chips as raw sweet potato chips.
final class CheatPlanCheckTests: XCTestCase {
    private func part(_ name: String, _ g: Double, _ k: Double, p: Double = 0, c: Double = 0, f: Double = 0) -> JSON {
        ["name": name, "grams": g, "kcal": k, "protein": p, "carbs": c, "fat": f]
    }
    private func slot(_ title: String, _ parts: [JSON], kcal: Double) -> JSON {
        ["time": "18:30", "title": title, "detail": "", "kcal": kcal, "protein": 0, "carbs": 0, "fat": 0, "workout": false, "saved": "", "parts": parts]
    }

    @MainActor
    func testTheDishIsItsCheckedPartsAddedUp() async {
        let s = slot("Crispy chicken burger", [part("Bread roll, white", 85, 225, p: 7, c: 42, f: 2.5), part("Mayonnaise", 25, 170, p: 0.3, c: 1, f: 18.5)], kcal: 900)
        let out = await CheatPlan.checked([s])[0], parts = list(out["parts"])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(num(out["kcal"]) ?? 0, parts.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, accuracy: 1, "the AI's 900 for the dish is gone")
        XCTAssertLessThan(num(out["kcal"]) ?? 0, 450)
    }

    @MainActor
    func testBatteredFriedWingsStayFried() async {
        let s = slot("Korean fried chicken", [part("Chicken wings, fried with batter", 300, 810, p: 54, c: 30, f: 52)], kcal: 980)
        let out = await CheatPlan.checked([s])[0], p = list(out["parts"])[0]
        XCTAssertGreaterThanOrEqual(num(out["kcal"]) ?? 0, 690, "not counted as lean baked wing (582): matched \(str(p["match"]))")
        XCTAssertFalse(str(p["match"]).lowercased().contains("lean"), str(p["match"]))
    }

    func testFriedFoodIsntItsLeanBakedEntry() {
        XCTAssertFalse(Assistant.sameCooking("Chicken wings, fried with batter", "Chicken, wing, lean flesh, baked, no added fat"))
        XCTAssertTrue(Assistant.sameCooking("Chicken wings, fried with batter", "Chicken, wing, flesh & skin, battered, fried"))
        XCTAssertTrue(Assistant.sameCooking("Potato, pan fried, no oil", "Potato, peeled, pan fried, no added fat"))
        XCTAssertTrue(Assistant.sameCooking("Chicken breast, grilled", "Chicken, breast, lean flesh, baked, no added fat"), "only fried food is held to it")
        XCTAssertFalse(Assistant.sameCooking("Chicken wings, fried with batter", "Chicken wings, with skin, fried without fat (oven)"), "fried in name only, and not battered")
        XCTAssertFalse(Assistant.sameCooking("Youtiao, deep fried", "Bread, white, commercially prepared, toasted"), "a fried dough stick isn't toast (28 Nov)")
        XCTAssertFalse(Assistant.sameFood("Sauce, tomato, reduced sugar ketchup", "Sauce, barbecue, commercial"), "tomato sauce isn't barbecue sauce (28 Nov)")
        XCTAssertTrue(Assistant.sameFood("Sauce, tomato, reduced sugar ketchup", "Sauce, tomato, reduced sugar & salt, commercial"))
        XCTAssertTrue(Assistant.sameFood("Cheese, cheddar", "Cheese, cheddar, regular fat"), "the family word plus its kind still matches")
        XCTAssertFalse(Assistant.sameFood("Cheese, cheddar, reduced fat", "Cheese, cheddar, regular fat"), "and lean still isn't full fat (fatClash)")
        XCTAssertTrue(FoodReference.differentDish("Youtiao, deep fried", "Doughnuts, yeast-leavened, glazed, enriched (includes honey buns)"), "nor a glazed doughnut")
        XCTAssertFalse(FoodReference.differentDish("Doughnut, glazed", "Doughnuts, yeast-leavened, glazed, enriched (includes honey buns)"))
        XCTAssertTrue(FoodReference.differentDish("Jellied bean curd in soy broth", "Tofu, soft, prepared with calcium sulfate and magnesium chloride (nigari)"), "half of it is broth")
        XCTAssertFalse(FoodReference.differentDish("Tofu, soft", "Tofu, soft, prepared with calcium sulfate and magnesium chloride (nigari)"))
        XCTAssertTrue(Assistant.sameCooking("Bacon, fried","Bacon, middle rasher, untrimmed, baked, roasted, fried, grilled or BBQ'd, no added fat"))
    }

    @MainActor
    func testHotChipsArentSweetPotatoChips() async {
        let s = slot("Burger and chips", [part("Potato chips (fries), hot", 150, 465, p: 5, c: 55, f: 24)], kcal: 465)
        let out = await CheatPlan.checked([s])[0], p = list(out["parts"])[0]
        XCTAssertFalse(str(p["match"]).lowercased().contains("sweet potato"), str(p["match"]))
        XCTAssertGreaterThanOrEqual(num(out["kcal"]) ?? 0, 330, "matched \(str(p["match"]))")
    }

    @MainActor
    func testSavedMealsWorkoutsAndPartlessDishesKeepTheirNumbers() async {
        var saved = slot("Protein brownie", [part("Brownie", 100, 400)], kcal: 430); saved["saved"] = "Protein brownie"
        var workout = slot("Walk", [], kcal: 0); workout["workout"] = true
        let bare = slot("Burnt basque cheesecake", [], kcal: 550)
        let out = await CheatPlan.checked([saved, workout, bare])
        XCTAssertEqual(num(out[0]["kcal"]), 430)
        XCTAssertEqual(num(out[1]["kcal"]), 0)
        XCTAssertEqual(num(out[2]["kcal"]), 550)
    }
}
