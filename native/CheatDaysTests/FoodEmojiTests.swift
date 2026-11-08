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
        XCTAssertEqual(FoodEmoji.for("Biltong slices"), "🥩")               // nor biltong slices
        XCTAssertEqual(FoodEmoji.for("Caramel slice"), "🍰")                // a slice by itself is one
        // a set is the dish it's named for: not the sauce it didn't have, nor the wagyu that came with it
        XCTAssertEqual(FoodEmoji.for("Chirashi lunch set (2/3 fish, rice and sides) and 3 wagyu slices, no side sauces"), "🍣")
        XCTAssertEqual(FoodEmoji.for("Burger combo, fries and a coke"), "🍔")
        XCTAssertEqual(FoodEmoji.for("Chirashi bowl"), "🍣")
        XCTAssertEqual(FoodEmoji.for("Gyudon"), "🍚")
        XCTAssertEqual(FoodEmoji.for("Oden broth, dashi"), "🍲")
        XCTAssertEqual(FoodEmoji.for("Chicken karaage"), "🍗")
        XCTAssertEqual(FoodEmoji.for("Edamame, shelled, boiled"), "🫛")
    }

    /// Dishes from the cuisines people eat out, each to an icon the app has.
    func testOtherCuisines() {
        XCTAssertEqual(FoodEmoji.for("Chicken tikka masala"), "🍛")
        XCTAssertEqual(FoodEmoji.for("Masala dosa"), "🥞")
        XCTAssertEqual(FoodEmoji.for("Masala chai"), "🍵")          // the drink, not the curry
        XCTAssertEqual(FoodEmoji.for("Garlic naan"), "🫓")
        XCTAssertEqual(FoodEmoji.for("Beef samosa"), "🥟")
        XCTAssertEqual(FoodEmoji.for("Nasi lemak"), "🍚")
        XCTAssertEqual(FoodEmoji.for("Char kway teow"), "🍜")
        XCTAssertEqual(FoodEmoji.for("Tom yum soup"), "🍲")
        XCTAssertEqual(FoodEmoji.for("Pork banh mi"), "🥪")
        XCTAssertEqual(FoodEmoji.for("Prawn rice paper rolls"), "🥟")   // not a bread roll
        XCTAssertEqual(FoodEmoji.for("Beef bulgogi"), "🥩")
        XCTAssertEqual(FoodEmoji.for("Kimchi fried rice"), "🍚")
        XCTAssertEqual(FoodEmoji.for("Chicken shawarma"), "🌯")
        XCTAssertEqual(FoodEmoji.for("Lamb tagine"), "🍲")
        XCTAssertEqual(FoodEmoji.for("Chicken parma"), "🍗")
        XCTAssertEqual(FoodEmoji.for("Parma ham"), "🥓")
        XCTAssertEqual(FoodEmoji.for("Beef empanada"), "🥟")
        XCTAssertEqual(FoodEmoji.for("Churros"), "🍩")
        XCTAssertEqual(FoodEmoji.for("Tiramisu"), "🍰")
        XCTAssertEqual(FoodEmoji.for("Miso glazed salmon"), "🐟")   // miso is a soup only by itself
        XCTAssertEqual(FoodEmoji.for("Shakshuka"), "🍳")
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
        XCTAssertEqual(FoodEmoji.for("Kimchi, Sliced Napa Cabbage"), "🥬")
    }

    func testUnknown() {
        XCTAssertNil(FoodEmoji.for("Quick add"))
    }
}
