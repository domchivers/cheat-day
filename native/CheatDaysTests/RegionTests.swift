import XCTest
@testable import CheatDays

/// Portion sizes follow the chosen country; the UK uses the food list's own sizes.
final class RegionTests: XCTestCase {
    private var saved = ""
    override func setUp() { saved = Region.choice }
    override func tearDown() { Region.choice = saved }   // leave the setting as it was

    func testPortionsByCountry() {
        Region.choice = "uk"
        XCTAssertNil(Region.portion("Chicken thigh, raw, skinless"))
        XCTAssertEqual(Region.current.name, "the UK")
        Region.choice = "au"
        XCTAssertEqual(Region.portion("Chicken thigh, raw, skinless"), 140)
        XCTAssertEqual(Region.portion("Red wine"), 150)
        Region.choice = "us"
        XCTAssertEqual(Region.portion("Chicken breast, raw, skinless"), 280)
        XCTAssertNil(Region.portion("Banana"))
    }

    func testFoodListUsesTheRegion() {
        let row: [Any] = ["Chicken thigh, raw, skinless", 121, 100, "thigh", "g", "uncooked boneless", 20, 0, 4]
        Region.choice = "uk"
        XCTAssertEqual(num(FoodMath.foodItem(row)["servingSize"]), 100)
        Region.choice = "au"
        XCTAssertEqual(num(FoodMath.foodItem(row)["servingSize"]), 140)
    }

    /// 147 g of raw chicken breast from the food list is what the assistant makes it in Australia (18 Nov: 176 against
    /// 144, the list at 120 kcal per 100 g, the assistant at the AFCD's 98). The UK keeps the list's own.
    func testRawChickenMatchesTheAssistantInAustralia() {
        let row: [Any] = ["Chicken breast, raw, skinless", 120, 150, "breast", "g", "uncooked", 23, 0, 2.6]
        Region.choice = "au"
        let au = FoodMath.foodItem(row)
        XCTAssertEqual(num(au["kcalPer100"]), 98)
        XCTAssertEqual(num(au["p100"]), 22.5)
        XCTAssertEqual(((num(au["kcalPer100"]) ?? 0) * 147 / 100).rounded(), 144)
        let saved: JSON = ["name": "Chicken breast, raw, skinless", "source": "search", "kcalPer100": 120, "p100": 23, "c100": 0, "f100": 2.6, "servingSize": 230, "unitLabel": "breast"]
        XCTAssertEqual(num(Region.adjust(saved)["kcalPer100"]), 98)
        Region.choice = "uk"
        XCTAssertEqual(num(FoodMath.foodItem(row)["kcalPer100"]), 120)
    }

    func testSavedFoodsGetTheRegionalPortion() {
        Region.choice = "au"
        let old: JSON = ["name": "Chicken thigh, raw, skinless", "source": "search", "kcalPer100": 121, "servingSize": 100, "kcalPerServing": 121, "unitLabel": "thigh"]
        let b = Region.adjust(old)
        XCTAssertEqual(num(b["servingSize"]), 140)
        XCTAssertEqual(num(b["kcalPer100"]), 104)       // Australia's own numbers for it (AFCD), not the list's 121
        XCTAssertEqual(num(b["kcalPerServing"]), 145.6)
        let pack: JSON = ["name": "Chicken thigh, raw, skinless", "source": "barcode", "kcalPer100": 121, "servingSize": 100]
        XCTAssertEqual(num(Region.adjust(pack)["servingSize"]), 100)   // a scanned pack keeps its own size
    }
}
