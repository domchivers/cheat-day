import XCTest
@testable import CheatDays

/// The takeaway planner, with Gami's 2026 kJ (from its menu PDF, as in design's takeaway spec; protein estimated) and
/// the foods from home in that session's log.
final class TakeawayTests: XCTestCase {
    private let gami: [Takeaway.Item] = {
        let rows: [(String, Double, Double, String)] = [
            ("Original tenders, 4 pcs", 2800, 42, "main"), ("Honey soy tenders, 4 pcs", 3219, 42, "main"), ("Soy garlic tenders, 4 pcs", 3428, 42, "main"),
            ("Original boneless, 7 pcs", 3996, 50, "main"), ("Original wings, 8 pcs", 3520, 45, "main"), ("Chicken Burger (Original)", 2280, 30, "main"),
            ("Saucy Burger", 2490, 30, "main"), ("Mad Gochujang chicken plate", 3560, 50, "main"), ("Honey Butter Garlic chicken plate", 3780, 50, "main"),
            ("Bulgogi hot pot", 2300, 30, "main"), ("Bibimbap", 2740, 28, "main"), ("Beef bulgogi cup-bap", 2950, 28, "main"), ("Grilled chicken cup-bap", 3740, 40, "main"),
            ("Kimchi fried rice", 3053, 15, "main"), ("Tteokbokki", 3354, 15, "main"), ("Kimchi pancake", 2541, 12, "main"), ("Japchae", 4183, 18, "main"),
            ("Dumplings", 1095, 10, "side"), ("Corn ribs", 1030, 5, "side"), ("Gami chips", 3042, 8, "side"), ("Cheese Snowy chips", 2550, 8, "side")]
        return Takeaway.items(["items": rows.map { ["name": $0.0, "kind": $0.3, "published": "energy", "kj": $0.1, "kcal": 0, "protein_g": $0.2, "carbs_g": 50, "fat_g": 25] as JSON }])
    }()
    private let home: [Takeaway.Home] = [
        Takeaway.home(name: "Milk Chocolate Protein Powder", kcal100: 380, p100: 69.3, c100: 16, f100: 4.3, serving: 30, label: true)!,
        Takeaway.home(name: "Pauls PLUS+ milk", kcal100: 68, p100: 6, c100: 5, f100: 1, serving: nil, label: true)!,
        Takeaway.home(name: "Kenny's salted caramel ice cream", kcal100: 106, p100: 7.2, c100: 11.6, f100: 3.4, serving: nil, label: true)!,
        Takeaway.home(name: "Lyttos Light Greek yoghurt", kcal100: 67, p100: 5.5, c100: 5, f100: 2, serving: nil, label: false)!]

    /// "Chicken Burger (2280 kJ)": 545 kcal, the kJ taken out of the name, protein kept and carbs and fat fitted to it.
    func testKilojoulesFromTheName() {
        XCTAssertEqual(Takeaway.kj(in: "Chicken Burger (2280 kJ)"), 2280)
        XCTAssertEqual(Takeaway.kj(in: "Japchae 4,183kJ"), 4183)
        XCTAssertNil(Takeaway.kj(in: "Chicken Burger"))
        let i = Takeaway.items(["items": [["name": "Chicken Burger (2280 kJ)", "kind": "main", "published": "none", "kj": 0, "kcal": 0, "protein_g": 30, "carbs_g": 50, "fat_g": 30] as JSON]])[0]
        XCTAssertEqual(i.name, "Chicken Burger")
        XCTAssertEqual(i.tier, "energy")
        XCTAssertEqual(i.kcal, 545)
        XCTAssertEqual(i.p, 30)
        XCTAssertEqual(4 * i.p + 4 * i.c + 9 * i.f, 545, accuracy: 0.5)
    }

    /// 854 kcal and 59 g left: the best combo reaches the protein and lands within 854 (10 over at most), three different dishes.
    func testGamiDinner() {
        let p = Takeaway.plan(menu: gami, home: home, kcal: 854, protein: 59, place: "Gami")
        XCTAssertEqual(p.combos.count, 3)
        let best = p.combos[0].0
        XCTAssertTrue(p.meets)
        XCTAssertGreaterThanOrEqual(best.p, 58.5)
        XCTAssertLessThanOrEqual(best.kcal, 864)
        XCTAssertGreaterThanOrEqual(best.kcal, 794, "close to what's left, not far under")
        XCTAssertEqual(Set(p.combos.map(\.0.item.name)).count, 3, "a different dish each")
        // a shake and one more at most, and milk only in a shake
        for (c, _) in p.combos {
            XCTAssertLessThanOrEqual(c.home.filter { $0.0.kind != .milk }.count, 2)
            if c.grams(.milk) > 0 { XCTAssertGreaterThan(c.grams(.powder), 0) }
        }
        // the card adds up: its totals are its lines
        let j = Takeaway.json(best, note: "Best fit", restaurant: "Gami", kcal: 854)
        XCTAssertEqual(list(j["lines"]).reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, num(j["kcal"]) ?? 0, accuracy: 2)
    }

    /// With protein to spare, the spare goes on more food or dessert rather than more powder.
    func testSpareProteinGoesOnTheFood() {
        let p = Takeaway.plan(menu: gami, home: home, kcal: 854, protein: 40, place: "Gami")
        let best = p.combos[0].0
        XCTAssertGreaterThanOrEqual(best.p, 39.5)
        XCTAssertEqual(best.grams(.powder), 0, "40 g is reached without a shake: the room goes on food")
    }

    /// "No milk left, and I want the wings": the wings even though they go over, with a water shake; "no milk" leaves the
    /// Milk Chocolate powder alone.
    func testWantedDishAndNoMilk() {
        let p = Takeaway.plan(menu: gami, home: home, kcal: 854, protein: 59, want: ["the wings"], avoid: ["milk"], place: "Gami")
        let best = p.combos[0].0
        XCTAssertTrue(best.item.name.contains("wings"))
        XCTAssertEqual(best.grams(.milk), 0)
        XCTAssertGreaterThan(best.grams(.powder), 0)
        XCTAssertGreaterThan(Takeaway.json(best, note: "", restaurant: "Gami", kcal: 854)["over"] as? Double ?? 0, 10, "says how far over")
    }

    /// "I'd like the chicken burger, with a shake and ice cream" (as Claude reads it): the burger, with a shake and ice cream from home.
    func testBurgerWithAShakeAndIceCream() {
        let menu = gami + [Takeaway.Item(name: "Strawberry milkshake", kind: "drink", tier: "energy", kcal: 400, p: 10, c: 60, f: 12)]
        let p = Takeaway.plan(menu: menu, home: home, kcal: 854, protein: 59, want: ["chicken burger", "shake", "ice cream"], place: "Gami")
        XCTAssertEqual(Set(p.combos.map(\.0.item.name)), ["Chicken Burger (Original)"], "only the burger, never the milkshake")
        let best = p.combos[0].0
        XCTAssertGreaterThan(best.grams(.powder), 0)
        XCTAssertGreaterThan(best.grams(.dessert), 0)
        XCTAssertGreaterThanOrEqual(best.p, 58.5)
        XCTAssertLessThanOrEqual(best.kcal, 864)
    }

    /// The kJ they read on DoorDash beat the lookup's (an old menu's 6,888 kJ burger): the dish takes theirs, protein in
    /// proportion when the sizes are far apart, kept when close; a dish the menu lacked is added.
    func testTheirKilojoulesWin() {
        let found = [Takeaway.Item(name: "Chicken Burger", kind: "main", tier: "energy", kcal: 1646, p: 42, c: 80, f: 105),
                     Takeaway.Item(name: "Original wings, 8 pcs", kind: "main", tier: "energy", kcal: 841, p: 45, c: 40, f: 50)]
        let out = Takeaway.withSeen(found, [["name": "Chicken Burger (2280 kJ)", "kj": 2280], ["name": "Original wings, 8 pcs", "kj": 3600], ["name": "Cheese tteokbokki", "kj": 3000]])
        let burger = out.first { $0.name == "Chicken Burger" }!
        XCTAssertEqual(burger.kcal, 545)
        XCTAssertEqual(burger.p, 42 * 545 / 1646, accuracy: 0.1)
        XCTAssertEqual(4 * burger.p + 4 * burger.c + 9 * burger.f, 545, accuracy: 0.5)
        XCTAssertEqual(out.first { $0.name.hasPrefix("Original wings") }!.p, 45, "860 kcal is close to 841: protein kept")
        XCTAssertTrue(out.contains { $0.name == "Cheese tteokbokki" && $0.kcal == 717 })
        XCTAssertEqual(Takeaway.dishes(["Chicken Burger", "shake", "ice cream"]), ["Chicken Burger"])
        // a DoorDash page in a photo: "this burger" is the burger, and the chips on the page aren't added as a main
        let page = Takeaway.withSeen(found, [["name": "Chicken Burger", "kj": 2280], ["name": "Gami Chips", "kj": 3042]], want: ["This burger"])
        XCTAssertEqual(page.first { $0.name == "Chicken Burger" }?.kcal, 545)
        XCTAssertFalse(page.contains { $0.name == "Gami Chips" })
        XCTAssertTrue(Takeaway.has(page, "this burger"), "'this' isn't a word of the dish")
    }

    /// 196 kcal left at 10 pm: not "nothing fits", but the smallest dishes, each saying how far over.
    func testNothingFitsShowsTheSmallest() {
        let p = Takeaway.plan(menu: gami, home: home, kcal: 196, protein: 10, place: "Gami")
        XCTAssertEqual(p.combos.count, 3)
        XCTAssertEqual(p.combos[0].0.item.name, "Chicken Burger (Original)", "the smallest dish first (545 kcal)")
        XCTAssertEqual(p.combos[0].0.home.count, 0, "nothing from home on top of a dish that's already over")
        XCTAssertEqual(Takeaway.json(p.combos[0].0, note: "", restaurant: "Gami", kcal: 196)["over"] as? Double, 349)
    }

    /// Low-protein dishes and sides that can't fit with a dish are listed, never suggested.
    func testLowProteinAndSides() {
        let p = Takeaway.plan(menu: gami, home: home, kcal: 854, protein: 59)
        XCTAssertTrue(p.low.contains { $0.name == "Tteokbokki" }, "15 g in 802 kcal is under 3 g per 100 kcal")
        XCTAssertTrue(p.sides.contains { $0.name == "Gami chips" })
        XCTAssertFalse(p.sides.contains { $0.name == "Corn ribs" }, "246 kcal fits with the burger")
        for (c, _) in p.combos { XCTAssertEqual(c.item.kind, "main"); XCTAssertFalse(Takeaway.lowProtein(c.item)) }
    }

    func testHomeFoodKinds() {
        XCTAssertEqual(Takeaway.kind("Milk Chocolate Protein Powder"), .powder)
        XCTAssertEqual(Takeaway.kind("Pauls PLUS+ milk"), .milk)
        XCTAssertEqual(Takeaway.kind("Kenny's salted caramel ice cream"), .dessert)
        XCTAssertEqual(Takeaway.kind("Chobani Greek Yogurt"), .yoghurt)
        XCTAssertNil(Takeaway.kind("Cadbury Dairy Milk Chocolate"))
        XCTAssertNil(Takeaway.kind("Chicken breast"))
        XCTAssertEqual(home[0].amounts, [0, 15, 22.5, 30, 45], "half, three quarters, one and one and a half scoops")
    }

    func testChoosingFromAMenuPage() {
        XCTAssertTrue(Takeaway.choosing("This burger for dinner"))
        XCTAssertTrue(Takeaway.choosing("what should I get?"))
        XCTAssertFalse(Takeaway.choosing("Had this for lunch"))
        XCTAssertFalse(Takeaway.choosing("ate this burger"))
        XCTAssertFalse(Takeaway.choosing("This burger"), "just naming it: a log, as before")
        // Claude called this "not takeaway" three times out of three, while naming Gami: the app's own check decides
        XCTAssertTrue(Takeaway.choosing("Want something from the gami in Windsor tomorrow, what's my options? Lunch thinking"))
    }

    /// Every typed message is asked: the ask reads choose, log or other however it's put (intent-check.js has the cases).
    func testTheAskHasTheThreeIntents() {
        let p = Takeaway.routeAsk("Gami tonight?", earlier: "")
        XCTAssertTrue(p.contains("choose:") && p.contains("log:") && p.contains("other:"))
        XCTAssertTrue(p.contains("Their message: \"Gami tonight?\""))
        XCTAssertEqual(dict(Takeaway.routeSchema["properties"])["intent"].flatMap { $0 as? JSON }?["enum"] as? [String], ["choose", "log", "other"])
    }

    /// A food saved with 100 g as its "serving" shows per 100 g ("379 kcal per serving" was a protein powder's per 100 g).
    func testHundredGramsIsNotAServing() {
        let c = FoodMath.conv(["name": "Protein powder", "unit": "g", "kcalPer100": 379, "servingSize": 100])
        XCTAssertNil(c.countKcal)
        XCTAssertEqual(c.kcalPer100, 379)
        XCTAssertEqual(FoodMath.conv(["name": "Protein powder", "unit": "g", "kcalPer100": 379, "servingSize": 30]).countKcal ?? 0, 113.7, accuracy: 0.1)
    }
}
