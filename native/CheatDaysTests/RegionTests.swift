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

    func testSavedFoodsGetTheRegionalPortion() {
        Region.choice = "au"
        let old: JSON = ["name": "Chicken thigh, raw, skinless", "source": "search", "kcalPer100": 121, "servingSize": 100, "kcalPerServing": 121, "unitLabel": "thigh"]
        let b = Region.adjust(old)
        XCTAssertEqual(num(b["servingSize"]), 140)
        XCTAssertEqual(num(b["kcalPerServing"]), 169.4)
        let pack: JSON = ["name": "Chicken thigh, raw, skinless", "source": "barcode", "kcalPer100": 121, "servingSize": 100]
        XCTAssertEqual(num(Region.adjust(pack)["servingSize"]), 100)   // a scanned pack keeps its own size
    }
}
