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

    func testNoScansLeavesTheIdeaAsTheAIGaveIt() {
        let idea: JSON = ["name": "Omelette", "kcal": 400.0, "ingredients": [["name": "Eggs", "grams": 150.0, "label": 0, "kcal": 210.0, "protein": 18.0, "carbs": 1.0, "fat": 15.0]]]
        let m = MealPlannerView.withLabels(idea, [])
        XCTAssertEqual(num(m["kcal"]), 210)   // summed from its ingredients
        XCTAssertNil(m["fromLabels"])
    }
}
