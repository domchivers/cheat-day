import XCTest
@testable import CheatDays

/// Real meals the owner logged that came out wrong, replayed through every step after the AI (tidied, the food tables,
/// the guards), offline: the AI's parts are exactly as it answered, so these test the app, not the AI. Each test says
/// what the meal really was and the range the card must land in.
///
/// To add one: paste the chat's "Copy details for a report" text into a comment, copy the [AI (Claude)] parts into
/// meal(), and assert the totals (and any part that went wrong) against the real numbers: a label, a measured table,
/// or a weighed plate. Keep the range honest (about ±10% when the truth is a label, ±15% for a measured table).
@MainActor
final class RealMealsTests: XCTestCase {
    private func offline(label: JSON? = nil) {
        let was = (Assistant.findLabel, Assistant.findFoods)
        Assistant.ownFoods = false
        Assistant.findFoods = { _ in nil }
        Assistant.findLabel = { _ in label }
        addTeardownBlock { @MainActor in
            Assistant.ownFoods = true
            (Assistant.findLabel, Assistant.findFoods) = was
        }
    }

    private func part(_ name: String, _ g: Double, _ k: Double, _ p: Double, _ c: Double, _ f: Double, from: String = "estimate", tags: String = "") -> JSON {
        var x: JSON = ["name": name, "grams": g, "kcal": k, "protein_g": p, "carbs_g": c, "fat_g": f, "numbers_from": from]
        if !tags.isEmpty { x["tags"] = tags }
        return x
    }

    private func replay(_ name: String, _ parts: [JSON], said: String, photos: Bool = false) async -> JSON {
        let e: JSON = ["name": name, "parts": parts as [Any]]
        let shown = Assistant.shown(e, said: said, photos: photos, before: nil, via: "Claude").estimate
        return await Assistant.checkedCard(shown, before: nil, earlier: [])
    }

    private func find(_ card: JSON, _ prefix: String) -> JSON? { list(card["parts"]).first { str($0["name"]).hasPrefix(prefix) } }
    private func kcal(_ card: JSON) -> Double { num(card["kcal_total"]) ?? 0 }

    /// 28 Nov, 1.4.77: a takeaway Chinese breakfast, half of everything. The youtiao was counted as a glazed doughnut
    /// and the douhua in its broth as plain soft tofu. Taiwan measures youtiao at 548 kcal a 100 g; the whole breakfast
    /// works out about 1,050 kcal from Taiwan's numbers (the douhua and bun by estimate).
    func testChineseBreakfastHalfOfEverything() async {
        offline()
        let card = await replay("Breakfast", [
            part("Youtiao, deep fried", 85, 326, 6, 43, 14.5, tags: "fried, bought"),
            part("Tea egg, boiled", 55, 76, 6.5, 0.6, 5.3, tags: "boiled, bought"),
            part("Sauce meat bun, steamed", 130, 285, 10.4, 40, 9.1, tags: "steamed, bought"),
            part("Jellied bean curd in soy broth", 175, 88, 7, 5, 4.5, tags: "bought"),
            part("Soy milk (doujiang)", 125, 73, 4.6, 5.8, 3.4, tags: "bought"),
        ], said: "Had half of everything. Maybe 1/3 of the doujiang though", photos: true)
        let youtiao = find(card, "Youtiao")
        XCTAssertEqual(str(youtiao?["match"]), "Youtiao", "Taiwan's measured youtiao, not toast or a glazed doughnut")
        XCTAssertEqual(num(youtiao?["kcal"]) ?? 0, 466, accuracy: 5)
        let douhua = find(card, "Jellied bean curd")
        XCTAssertFalse(str(douhua?["match"]).lowercased().contains("tofu, soft"), "half of it is broth: not 175 g of plain tofu")
        XCTAssertEqual(kcal(card), 1_000, accuracy: 120)
    }

    /// The same breakfast's first chat (1.4.75): the youtiao went to "Bread, white, commercially prepared, toasted".
    func testYoutiaoIsNeverToast() async {
        offline()
        let card = await replay("Breakfast", [part("Youtiao, deep fried", 75, 290, 5.5, 38, 13, tags: "fried, bought")], said: "Had half of everything", photos: true)
        let youtiao = find(card, "Youtiao")
        XCTAssertEqual(str(youtiao?["match"]), "Youtiao")
        XCTAssertEqual(num(youtiao?["kcal"]) ?? 0, 411, accuracy: 5)
    }

    /// 28 Nov, 1.4.77: a home burger. The reduced-sugar tomato sauce was counted as barbecue sauce, the 3 Star mince as
    /// the table's 8.9%-fat "regular" mince (its label: 1,013 kJ, 20.4 g protein, 18 g fat a 100 g), and the bacon,
    /// weighed raw, as cooked. Truth: about 750 kcal, 57 g protein.
    func testHomeBurgerWithAldiMince() async {
        offline()   // no label found online: the AI's own numbers for the branded mince must stand, not the table's
        let card = await replay("Burger fillings", [
            part("Bacon, streaky, raw", 37, 102, 5.8, 0, 8.7, tags: "raw, processed"),
            part("Aldi Jindurra Station 3 Star beef mince, raw", 250, 605, 51, 0, 45, from: "brand", tags: "raw"),
            part("Mayonnaise, light Kewpie", 10, 33, 0.1, 1.5, 3, tags: "bought"),
            part("Sauce, tomato, reduced sugar ketchup", 10, 10, 0.1, 2.3, 0, tags: "bought"),
            part("Mustard, cream style", 5, 4, 0.3, 0.3, 0.2, tags: "bought"),
        ], said: "37g British streaky bacon\n250g jundurra Aldi 3 star beef mince\n10g light kewpie mayonnaise\n10g reduced sugar ketchup\n5g Australian mustard")
        XCTAssertFalse(str(find(card, "Sauce, tomato")?["match"]).lowercased().contains("barbecue"), "tomato sauce isn't barbecue sauce")
        XCTAssertEqual(num(find(card, "Aldi")?["kcal"]) ?? 0, 605, accuracy: 30, "the branded mince keeps its own numbers, not 8.9% 'regular' mince")
        XCTAssertLessThan(num(find(card, "Bacon")?["kcal"]) ?? 0, 130, "raw bacon at raw numbers")
        XCTAssertEqual(kcal(card), 750, accuracy: 75)
    }
}
