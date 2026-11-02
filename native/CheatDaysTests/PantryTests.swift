import XCTest
@testable import CheatDays

/// Scanned cupboard foods: their label numbers per 100 g, and the planner's ideas worked out from them.
@MainActor
final class PantryTests: XCTestCase {
    func testAScannedFoodKeepsItsLabelNumbersPer100g() throws {
        let b: JSON = ["name": "Chicken breast fillets", "brand": "Tesco", "kcalPer100": 106.0, "p100": 24.0, "c100": 0.0, "f100": 1.5]
        let s = try XCTUnwrap(PantryItem(basis: b))
        XCTAssertEqual(s.name, "Tesco Chicken breast fillets")
        XCTAssertEqual(s.kcal100, 106)
        XCTAssertEqual(s.p100, 24)
        // per serving only: turned into per 100 g
        let serv = try XCTUnwrap(PantryItem(basis: ["name": "Rice pouch", "kcalPerServing": 370.0, "servingSize": 250.0, "pServ": 7.5]))
        XCTAssertEqual(serv.kcal100, 148, accuracy: 0.01)
        XCTAssertEqual(serv.p100 ?? 0, 3, accuracy: 0.01)
        XCTAssertNil(PantryItem(basis: ["name": "No numbers"]))
    }

    func testAnIdeaUsesTheLabelNotTheAIsSums() throws {
        let chicken = try XCTUnwrap(PantryItem(basis: ["name": "Chicken", "kcalPer100": 106.0, "p100": 24.0, "c100": 0.0, "f100": 1.5]))
        let idea: JSON = ["name": "Chicken and peppers", "kcal": 999.0, "protein": 1.0, "ingredients": [
            ["name": "Chicken", "grams": 200.0, "label": 1, "kcal": 400.0, "protein": 10.0, "carbs": 0.0, "fat": 9.0],   // AI's guess: ignored
            ["name": "Peppers", "grams": 100.0, "label": 0, "kcal": 30.0, "protein": 1.0, "carbs": 6.0, "fat": 0.0]
        ]]
        let m = MealPlannerView.withLabels(idea, [chicken])
        XCTAssertEqual(num(m["kcal"]), 242)   // 212 from the label + 30
        XCTAssertEqual(num(m["protein"]), 49)  // 48 + 1
        XCTAssertEqual(str(m["uses"]), "200 g Chicken")
        XCTAssertEqual(m["fromLabels"] as? Bool, true)
    }

    func testACardShowsWhatItsRecipeWillShow() {
        // the card said 414 kcal, and its recipe 300 once the chicken was corrected from cooked to raw numbers
        let idea: JSON = ["name": "Stir fry", "ingredients": [
            ["name": "Chicken breast, skinless, raw", "grams": 200.0, "label": 0, "kcal": 330.0, "protein": 62.0, "carbs": 0.0, "fat": 7.0],
            ["name": "Soy sauce", "grams": 15.0, "label": 0, "kcal": 8.0, "protein": 1.0, "carbs": 1.0, "fat": 0.0]
        ]]
        let m = MealPlannerView.withLabels(idea, [])
        XCTAssertEqual(num(m["kcal"]), 204)   // 196 + 8
        let written: [JSON] = [["name": "Chicken breast, skinless, raw", "grams": 180.0, "kcal": 250.0, "protein_g": 40.0, "carbs_g": 0.0, "fat_g": 3.0], ["name": "Salt", "grams": 1.0, "kcal": 0.0]]
        let kept = FoodReference.keepingCard(written, from: list(m["ingredients"]))
        XCTAssertEqual(num(kept[0]["kcal"]), 196)
        XCTAssertEqual(num(kept[0]["grams"]), 200)
        XCTAssertEqual(num(kept[1]["kcal"]), 0, "an added pinch of salt stays")
    }

    func testAnIdeaUnderItsProteinAimGetsABitMoreOfItsProteinFood() {
        func idea(aim: Double) -> JSON {
            ["name": "Stir fry", "aim": aim, "ingredients": [
                ["name": "Chicken breast, skinless, raw", "grams": 200.0, "label": 0, "kcal": 196.0, "protein": 45.0, "carbs": 0.0, "fat": 1.6],
                ["name": "Soy sauce", "grams": 15.0, "label": 0, "kcal": 8.0, "protein": 1.0, "carbs": 1.0, "fat": 0.0]
            ]]
        }
        let m = MealPlannerView.withLabels(idea(aim: 50), [])
        XCTAssertEqual(num(list(m["ingredients"])[0]["grams"]), 220)
        XCTAssertGreaterThanOrEqual(num(m["protein"]) ?? 0, 50)
        XCTAssertEqual(num(m["kcal"]), 224, "its calories follow")
        XCTAssertEqual(num(list(MealPlannerView.withLabels(idea(aim: 45), []) ["ingredients"])[0]["grams"]), 200, "already there")
        XCTAssertEqual(num(list(MealPlannerView.withLabels(idea(aim: 200), [])["ingredients"])[0]["grams"]), 270, "never more than a third extra")
    }

    func testNoScansLeavesTheIdeaAsTheAIGaveIt() {
        let idea: JSON = ["name": "Omelette", "kcal": 400.0, "ingredients": [["name": "Eggs", "grams": 150.0, "label": 0, "kcal": 210.0, "protein": 18.0, "carbs": 1.0, "fat": 15.0]]]
        let m = MealPlannerView.withLabels(idea, [])
        XCTAssertEqual(num(m["kcal"]), 210)   // summed from its ingredients
        XCTAssertNil(m["fromLabels"])
    }
}
