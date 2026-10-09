import XCTest
@testable import CheatDays

/// Barcode products turn into the same food as on the website.
final class FoodLookupTests: XCTestCase {
    func testPlainProduct() {
        let p: JSON = ["product_name": "Digestives", "brands": "McVitie's", "product_quantity": 400, "quantity": "400 g",
                       "serving_size": "1 biscuit (14.7 g)", "nutriments": ["energy-kcal_100g": 481, "energy-kj_100g": 2017, "proteins_100g": 7, "carbohydrates_100g": 62, "fat_100g": 21] as JSON,
                       "categories_tags": ["en:biscuits"]]
        let item = OpenFoodFacts.item(from: p)
        XCTAssertEqual(str(item["name"]), "Digestives")
        XCTAssertEqual(num(item["kcalPer100"]), 481)
        XCTAssertEqual(str(item["unitLabel"]), "biscuit")
        XCTAssertEqual(num(item["servingSize"]) ?? 0, 14.7, accuracy: 0.01)
        XCTAssertEqual(num(item["piecesPerPack"]), 27)
        XCTAssertEqual(num(item["p100"]), 7)
    }

    func testKilojoulesInTheKcalBoxAreFixed() {
        let p: JSON = ["product_name": "Oat bar", "nutriments": ["energy-kcal_100g": 1800] as JSON]
        let item = OpenFoodFacts.item(from: p)
        XCTAssertEqual(num(item["kcalPer100"]), (1800 / 4.184).rounded())
    }

    func testDrinksAreMeasuredInMl() {
        let p: JSON = ["product_name": "Cola", "quantity": "330 ml", "nutriments": ["energy-kcal_100g": 42] as JSON]
        XCTAssertEqual(str(OpenFoodFacts.item(from: p)["unit"]), "ml")
    }
}
