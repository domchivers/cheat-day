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

    func testChangeOffersTheMatchFirstThenItsKind() {
        let matched = "Cake, sponge, filled with cream &/or jam & fruit"
        let options = FoodTable.au.alternatives("Tiramisu cream cake", tags: ["bought", "filled"], matched: matched).map(\.name)
        XCTAssertEqual(options.first, matched)
        XCTAssertEqual(options.count, 4)
        XCTAssertEqual(Set(options).count, 4, "no repeats")
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

    func testAShopsPlateIsCheckedAndItsNameKeptOffTheParts() {
        // the 1.0.71 screenshot: "your numbers" with none given, and "#1000 Bread kabana croissant" judged as bread
        let e: JSON = ["shop": "#1000 Bread", "parts": [
            ["name": "#1000 Bread kabana croissant", "numbers_from": "them"],
            ["name": "Tiramisu cream cake bites (#1000 Bread)", "numbers_from": "estimate"],
            ["name": "#1000 Bread's kabana", "numbers_from": "them"]]]
        let parts = list(Assistant.tidied(e, said: "Kabana croissant and tiramisu cream cake bites from #1000 bread", photos: true)["parts"])
        XCTAssertEqual(parts.map { str($0["name"]) }, ["Kabana croissant", "Tiramisu cream cake bites", "Kabana"])
        XCTAssertEqual(parts.map { str($0["numbers_from"]) }, ["estimate", "estimate", "estimate"], "the 1000 in the shop's name isn't a number they gave")
        let given = list(Assistant.tidied(["parts": [["name": "Toast", "numbers_from": "them"]]], said: "toast, 180 kcal", photos: false)["parts"])
        XCTAssertEqual(str(given.first?["numbers_from"]), "them")
    }

    func testPastFoodsAreFoundAndTheirNumbersKept() {
        let said = Set(FoodTable.words("croissant from the bakery again").filter { $0.count >= 4 })
        XCTAssertTrue(Assistant.soundsLike("Croissant", said), "a short name by its one long word")
        XCTAssertTrue(Assistant.soundsLike("Kabana croissant", said))
        XCTAssertFalse(Assistant.soundsLike("Chicken and rice bowl", said))
        let again = list(Assistant.tidied(["parts": [["name": "Porridge", "numbers_from": "them"]]], said: "same breakfast as yesterday", photos: false)["parts"])
        XCTAssertEqual(str(again.first?["numbers_from"]), "them", "yesterday's logged numbers are theirs")
    }

    func testMinusAndPlusLandOnRoundNumbers() {
        XCTAssertEqual(AssistantView.step(100, by: -10, min: 10), 90)
        XCTAssertEqual(AssistantView.step(97, by: -10, min: 10), 90, "off a step: down to the round one below")
        XCTAssertEqual(AssistantView.step(97, by: 10, min: 10), 100)
        XCTAssertEqual(AssistantView.step(130, by: 10, min: 10), 140)
        XCTAssertEqual(AssistantView.step(45, by: -5, min: 5), 40)
        XCTAssertEqual(AssistantView.step(10, by: -10, min: 10), 10, "never below the smallest step")
        XCTAssertEqual(AssistantView.step(89, by: -10, min: 10), 80, "a plate at 89% after rounding goes to 80")
    }

    func testTheTrailSaysWhatWasChecked() {
        let e: JSON = ["shop": "#1000 Bread", "shop_items": "Kabana croissant x1", "parts": [["src": "afcd"], ["src": "afcd"], ["src": "ai"]]]
        XCTAssertEqual(Assistant.trail(e, shopFound: false), ["2 of 3 parts checked against the food database", "#1000 Bread doesn't publish its numbers"])
        var mine = e; mine["shopNote"] = "#1000 Bread's own published numbers"
        XCTAssertEqual(Assistant.trail(mine, shopFound: true), ["#1000 Bread's own published numbers"])
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

    // Rock Pho's rare beef and brisket pho, 7 Nov: 793 kcal on the card, about 600 really

    func testPhoNoodlesStayRiceNoodles() {
        // "plain" matched egg noodles one tag better: 166 kcal and 7.5 g protein a 100 g, not 119 and 2.5
        XCTAssertEqual(best("Rice noodles, boiled", ["bought", "boiled", "plain"]), "Noodle, rice stick, boiled, drained")
        XCTAssertEqual(best("Pho noodles", ["boiled"]), "Noodle, rice stick, boiled, drained")
        XCTAssertNil(FoodTable.au.find("Dried flat rice noodles (banh pho), uncooked"), "dried noodles aren't boiled ones")
    }

    func testRareBeefIsALeanCutNotMince() {
        for n in ["Rare beef", "Beef, rare", "Rare beef, cooked in the broth"] {
            let f = FoodTable.au.best(n, tags: ["raw"])
            XCTAssertLessThanOrEqual(f?.kcal ?? 999, 140, n)
            XCTAssertFalse(f?.name.contains("mince") ?? true, n)
        }
        XCTAssertEqual(Sanity.range("Rare beef")?.label, "rare lean beef")
    }

    func testAMatchThatFailsTheChecksIsSwappedAndSaysSo() {
        // the egg noodles the pho was first given (alternatives starts with the entry it's told was matched)
        let egg = FoodTable.au.alternatives("Rice noodles, boiled", tags: [], matched: "Noodle, wheat with egg, plain, boiled, no added fat")[0]
        XCTAssertEqual(egg.kcal, 166)
        let part = Assistant.checked(["name": "Rice noodles, boiled", "grams": 200, "tags": "boiled"], kcal100: egg.kcal, p100: egg.p, c100: egg.c, f100: egg.f, source: "afcd", match: egg.name)
        let fixed = Assistant.rematched(part, from: egg, table: .au)
        XCTAssertEqual(str(fixed?["match"]), "Noodle, rice stick, boiled, drained")
        XCTAssertEqual(num(fixed?["kcal"]), 238)
        XCTAssertTrue(str(fixed?["swapped"]).contains("changed to Noodle, rice stick"), str(fixed?["swapped"]))
        let rice = FoodTable.au.find("Rice noodles, boiled")!
        XCTAssertNil(Assistant.rematched(Assistant.checked(part, kcal100: rice.kcal, p100: rice.p, c100: rice.c, f100: rice.f, source: "afcd", match: rice.name), from: rice, table: .au), "a good match stays")
        XCTAssertTrue(Assistant.trail(["parts": [fixed!]], shopFound: false).contains(str(fixed?["swapped"])), "the swap is said under the reply")
    }

    func testAPartWithAWarningIsNeverCountedAsChecked() {
        let plate = Assistant.sane(["parts": [
            ["name": "Rice noodles, boiled", "grams": 200, "kcal": 332, "protein_g": 15, "carbs_g": 60, "fat_g": 2, "src": "afcd"],
            ["name": "Bean sprouts", "grams": 50, "kcal": 11, "protein_g": 1.5, "carbs_g": 1, "fat_g": 0.1, "src": "afcd"],
        ] as [JSON]])
        XCTAssertFalse((plate["flags"] as? [String] ?? []).isEmpty)
        XCTAssertEqual(Assistant.checkedCount(list(plate["parts"])), 1)
        XCTAssertEqual(Assistant.trail(plate, shopFound: false).first, "1 of 2 parts checked against the food database")
    }

    func testBrothAndWholeSoupsHaveTheirOwnRanges() {
        XCTAssertEqual(Sanity.range("Beef broth")?.label, "broth")
        XCTAssertNotEqual(Sanity.range("Beef pho with rice noodles, soup")?.label, "cooked rice or pasta", "a whole pho isn't plain noodles")
        XCTAssertNil(Sanity.range("Bone broth"), "bone broth has more protein than a clear broth")
        XCTAssertEqual(Sanity.range("Chicken broth")?.label, "broth", "chicken broth isn't chicken")
    }

    func testTheirCorrectionsForFoodsLikeThisAreShownToTheAI() {
        let rows: [JSON] = [
            ["name": "Rice noodles, boiled", "plate": "Rare beef & brisket pho", "shop": "Rock Pho", "change": "grams", "from": 250, "to": 180],
            ["name": "Pho", "shop": "Rock Pho", "change": "grams", "aiGrams": 880.0, "grams": 700.0],
            ["name": "Cheese, melted", "plate": "Kabana croissant", "change": "match", "from": "Cheese, processed", "to": "Cheese, cheddar, natural, regular fat"],
            ["name": "Rice noodles, boiled", "plate": "Pho", "change": "regular", "from": 200, "to": 200],
        ]
        let text = Assistant.corrections(rows, text: "beef pho rice noodles")
        XCTAssertTrue(text.contains("Rice noodles, boiled (Rock Pho): you said 250 g, they made it 180 g"), text)
        XCTAssertTrue(text.contains("Pho (Rock Pho): you said 880 g, they later changed it to 700 g"), text)
        XCTAssertFalse(text.contains("Cheese"), "not a food like this one")
        XCTAssertFalse(text.contains("200 g"), "a regular size agrees with the estimate")
        XCTAssertEqual(Assistant.corrections(rows, text: "chicken salad"), "")
    }

    func testTheSideSauceOfferAndHowMuchWasEaten() {
        XCTAssertEqual(AssistantView.sauceFood("Hoisin sauce")?.name, "Sauce, hoi sin (hoisin), commercial")
        XCTAssertEqual(AssistantView.eaten.map { $0.share }, [0.25, 0.5, 0.75, 1])
        let props = dict(dict(dict(Assistant.schema["properties"])["estimate"])["properties"])
        XCTAssertNotNil(props["eaten_unsure"]); XCTAssertNotNil(props["side_sauce"])
    }
}
