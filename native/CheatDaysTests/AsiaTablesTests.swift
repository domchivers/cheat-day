import XCTest
@testable import CheatDays

/// Taiwan's and Japan's tables (28 Nov): the dishes the Western tables got wrong come from them, under the names the AI uses.
final class AsiaTablesTests: XCTestCase {
    func testTaiwanHasTheBreakfast() {
        XCTAssertEqual(FoodTable.taiwan.best("Youtiao, deep fried", tags: ["fried", "bought"])?.name, "Youtiao")
        XCTAssertEqual(FoodTable.taiwan.best("Youtiao, deep fried", tags: ["fried"])?.kcal, 548)
        XCTAssertEqual(FoodTable.taiwan.best("Tea egg, boiled", tags: ["boiled"])?.name, "Tea egg")
        XCTAssertEqual(FoodTable.taiwan.find("You char kway")?.name, "Youtiao", "its other names find it too")
        XCTAssertEqual(FoodTable.taiwan.best("Xiaolongbao, steamed", tags: ["steamed"])?.name, "Xiaolongbao")
    }

    func testJapanHasItsFoods() {
        XCTAssertEqual(FoodTable.japan.best("Udon, boiled", tags: ["boiled"])?.name, "Udon, boiled")
        XCTAssertEqual(FoodTable.japan.find("Natto")?.name, "Natto")
        XCTAssertEqual(FoodTable.japan.find("Gyoza")?.name, "Gyoza", "the dumplings, not their wrappers")
    }

    func testOurOwnDishes() {
        XCTAssertEqual(FoodTable.built.find("Butter chicken")?.name, "Butter chicken")
        XCTAssertEqual(FoodTable.built.find("Bibimbap")?.kcal, 143, "ours, not the US table's 76")
        XCTAssertEqual(FoodTable.built.best("Pad thai, chicken", tags: ["fried"])?.name, "Pad thai, chicken")
        XCTAssertEqual(FoodTable.built.find("Jollof rice")?.name, "Jollof rice")
    }

    func testWorldIngredients() {
        XCTAssertEqual(FoodTable.ingredients.find("Gochujang")?.name, "Gochujang")
        XCTAssertEqual(FoodTable.ingredients.find("Candlenut")?.name, "Candlenut, raw")
        XCTAssertEqual(FoodTable.ingredients.find("Berbere")?.name, "Berbere")
    }

    func testAWesternFoodStillFindsNothingOdd() {
        // strict fallback tables: a plain food doesn't pick up an Asian dish made with it
        XCTAssertNil(FoodTable.taiwan.find("Pork, loin, grilled").flatMap { $0.name.contains("bun") ? $0 : nil })
    }

    func testTheyAreCredited() {
        XCTAssertTrue(FoodSourcesView.sources.contains { $0.country == "Taiwan" && $0.credit.contains("Open Government Data License") })
        XCTAssertTrue(FoodSourcesView.sources.contains { $0.country == "Japan" && $0.credit.contains("日本食品標準成分表") })
    }
}
