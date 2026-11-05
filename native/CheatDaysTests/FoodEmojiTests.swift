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

    /// From the owner's own list: the food the name ends on, without the extras.
    func testTheDishNotTheExtras() {
        XCTAssertEqual(FoodEmoji.for("Coliban potato, peeled, boiled, no oil"), "🥔")
        XCTAssertEqual(FoodEmoji.for("Cucumber, sliced"), "🥒")             // not a slice of cake
        XCTAssertEqual(FoodEmoji.for("Watermelon"), "🍉")                   // not water
        XCTAssertEqual(FoodEmoji.for("Crust Classic Pepperoni, high protein base"), "🥓")   // not a pepper
        XCTAssertEqual(FoodEmoji.for("Hearty Beef and Carrot Curry (1 portion, ¼ batch)"), "🍛")
        XCTAssertEqual(FoodEmoji.for("Spring onion, bacon, egg & cheese wrap"), "🌯")
        XCTAssertEqual(FoodEmoji.for("Orange and Grapefruit Bubble Tea"), "🧋")
        XCTAssertEqual(FoodEmoji.for("Breadtop Glazed Donut"), "🍩")
        XCTAssertEqual(FoodEmoji.for("Salmon and avocado sushi roll"), "🍣")
        XCTAssertEqual(FoodEmoji.for("Red chili, sliced"), "🌶️")
        XCTAssertEqual(FoodEmoji.for("Aldi Peri-Peri Chicken with Rice & Corn"), "🍗")
        XCTAssertEqual(FoodEmoji.for("Pizza Cheese Shredded"), "🧀")
        XCTAssertEqual(FoodEmoji.for("Kimchi, Sliced Napa Cabbage"), "🥦")
    }

    func testUnknown() {
        XCTAssertNil(FoodEmoji.for("Quick add"))
    }
}
