import XCTest
@testable import CheatDays

/// The AI's tags on a part pick the right entry in the food table: the general rule behind the #1000 Bread croissant's
/// cheese (natural, not processed) and its "tiramisu" cream cake bites (a cream sponge, not homemade tiramisu).
final class FoodMatchTests: XCTestCase {
    private func best(_ name: String, _ tags: [String]) -> String? { FoodTable.au.best(name, tags: tags)?.name }

    func testUnqualifiedCheeseOnABakeryItemIsNaturalCheddar() {
        XCTAssertEqual(best("Cheese, melted", ["bought", "cooked"]), "Cheese, cheddar, natural, regular fat")
        XCTAssertEqual(best("Melted cheese", ["bought"]), "Cheese, cheddar, natural, regular fat")
        XCTAssertEqual(best("Cheese", ["processed"]), "Cheese, cheddar, processed, regular fat", "a processed slice when that's what it is")
    }

    func testCreamCakeIsACreamSponge() {
        XCTAssertEqual(best("Cream cake", ["bought", "filled"]), "Cake, sponge, filled with cream &/or jam & fruit")
        XCTAssertEqual(best("Tiramisu cream cake bites (4 pieces)", ["bought", "filled"]), "Cake, sponge, filled with cream &/or jam & fruit")
        XCTAssertEqual(best("Tiramisu", ["homemade"]), "Tiramisu, coffee, homemade", "real tiramisu stays tiramisu")
    }

    func testCookedChickenWithSkinOnIsAWithSkinEntry() {
        let found = best("Cooked chicken, skin on", ["cooked", "skin on"]) ?? ""
        XCTAssertTrue(found.contains("skin & fat"), found)
        XCTAssertFalse(found.hasPrefix("Chicken, skin"), "the chicken, not the skin on its own")
        XCTAssertEqual(best("Chicken thigh, roasted, skin on", ["cooked", "baked", "skin on"]), "Chicken, thigh, lean flesh, skin & fat, baked, no added fat")
        XCTAssertEqual(best("Chicken breast, grilled", ["cooked", "grilled", "skin off"]), "Chicken, breast, lean flesh, grilled, no added fat")
    }

    func testTheEverydayNamesFromThatPlateMatch() {
        XCTAssertEqual(best("Kabana sausage", []), "Kabana or cabanossi")
        XCTAssertEqual(best("Croissant pastry", ["bought"]), "Croissant, plain")
        XCTAssertEqual(best("Potato, boiled", ["cooked", "boiled"]), FoodTable.au.find("Potato, boiled")?.name, "tags agreeing with find change nothing")
    }

    func testNoTagsIsFindUnchanged() {
        for n in ["Olive oil", "Chicken breast", "Cheese", "Basmati rice, cooked"] { XCTAssertEqual(best(n, []), FoodTable.au.find(n)?.name, n) }
    }

    func testTagsAndShopItemsAreRead() {
        XCTAssertEqual(Assistant.tags(["tags": "Bought, natural , skin on"]), ["bought", "natural", "skin on"])
        // as Sonnet really wrote them for the #1000 Bread plate
        XCTAssertEqual(Assistant.tags(["tags": "bought, bakery, processed meat, cooked (baked), filling"]), ["bought", "processed", "cooked", "baked"])
        let items = Assistant.shopItems("Kabana croissant x1; Tiramisu cream cake bites x4")
        XCTAssertEqual(items.map(\.name), ["Kabana croissant", "Tiramisu cream cake bites"])
        XCTAssertEqual(items.map(\.count), [1, 4])
        XCTAssertTrue(Assistant.shopItems("").isEmpty)
    }

    func testAChangedAIEstimateIsLoggedAsACorrection() {
        let item: JSON = ["name": "Kabana croissant", "source": "claude", "shop": "#1000 Bread", "kcalPer100": 300.0, "kcal": 360, "aiGrams": 120.0, "aiKcal": 360.0]
        let op = Store.correction(item, newKcal: 240)
        let row = dict(op?["row"])
        XCTAssertEqual(str(op?["type"]), "correction")
        XCTAssertEqual(num(row["aiGrams"]), 120)
        XCTAssertEqual(num(row["grams"]), 80)
        XCTAssertEqual(str(row["shop"]), "#1000 Bread")
        XCTAssertNil(Store.correction(item, newKcal: 360), "nothing changed")
        XCTAssertNil(Store.correction(["name": "Toast", "source": "manual", "kcal": 200], newKcal: 100), "only AI estimates")
    }
}
