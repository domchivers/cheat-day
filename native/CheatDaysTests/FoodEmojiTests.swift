import XCTest
@testable import CheatDays

/// Food icons: whole words only, phrases before single words, the more specific food first.
final class FoodEmojiTests: XCTestCase {
    func testWholeWords() {
        XCTAssertEqual(FoodEmoji.for("Rump steak"), "🥩")        // not rum, not tea
        XCTAssertEqual(FoodEmoji.for("Kale salad"), "🥗")        // not ale
        XCTAssertEqual(FoodEmoji.for("Ginger beer"), "🍺")
        XCTAssertEqual(FoodEmoji.for("Flat white"), "☕️")
    }

    func testPhrasesAndOrder() {
        XCTAssertEqual(FoodEmoji.for("Dairy Milk"), "🍫")
        XCTAssertEqual(FoodEmoji.for("Butter chicken"), "🍛")
        XCTAssertEqual(FoodEmoji.for("Egg fried rice"), "🍚")
        XCTAssertEqual(FoodEmoji.for("Chicken burger"), "🍔")
        XCTAssertEqual(FoodEmoji.for("Chicken sandwich"), "🥪")
        XCTAssertEqual(FoodEmoji.for("Popcorn"), "🍿")
        XCTAssertEqual(FoodEmoji.for("Bananas"), "🍌")
    }

    func testUnknown() {
        XCTAssertNil(FoodEmoji.for("Quick add"))
    }
}
