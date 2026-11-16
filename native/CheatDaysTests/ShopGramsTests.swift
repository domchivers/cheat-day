import XCTest
@testable import CheatDays

/// "Half peri peri chicken from Nando's and 125g of their large chips that's weight 237g" (1.3.57, 16 Nov): Nando's
/// published large chips (230 g, 533 kcal) replaced the 125 g eaten. Sonnet's shop_items for it, as it really wrote
/// them (tools/ai-test/shop-grams-check.js): "Large chips x1 (125 g of 237 g)" before, "Large chips 125g" with the new wording.
final class ShopGramsTests: XCTestCase {
    func testTheGramsTheyHadAreRead() {
        let now = Assistant.shopItems("Peri-peri chicken, half x1; Large chips x1 (125 g of 237 g)")
        XCTAssertEqual(now.map(\.name), ["Peri-peri chicken, half", "Large chips"])
        XCTAssertNil(now[0].grams)
        XCTAssertEqual(now[1].grams, 125, "the weight they had, not the whole serve's")
        let new = Assistant.shopItems("Half peri peri chicken x1; Large chips 125g")
        XCTAssertEqual(new.map(\.name), ["Half peri peri chicken", "Large chips"])
        XCTAssertEqual(new[1].grams, 125)
        XCTAssertEqual(new[0].count, 1)
        XCTAssertNil(Assistant.shopItems("Kabana croissant x2")[0].grams)
        XCTAssertEqual(Assistant.shopItems("Kabana croissant x2")[0].count, 2)
    }

    func testThePublishedServeIsScaledToTheGramsEaten() {
        let label: JSON = ["serving_g": 230, "kcal": 533, "protein_g": 6.7, "carbs_g": 65, "fat_g": 26, "source": "nandos.com.au chips"]
        let chips = Assistant.fromLabel(["name": "Large chips", "grams": 125], label)
        XCTAssertEqual(num(chips["grams"]), 125)
        XCTAssertEqual(num(chips["kcal"]), 290, "533 × 125 / 230, not 533")
        let whole = Assistant.fromLabel(["name": "Large chips", "servings": 1], label)
        XCTAssertEqual(num(whole["kcal"]), 533)
    }

    func testNandosIsntNandoss() {
        XCTAssertEqual(Assistant.possessive("Nando's"), "Nando's")
        XCTAssertEqual(Assistant.possessive("Crust"), "Crust's")
        XCTAssertEqual(Assistant.possessive("Grill'd"), "Grill'd's")
    }
}
