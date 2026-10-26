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
}
