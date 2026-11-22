import XCTest
import UIKit
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

    private func dish(_ name: String, _ kcal: Double, _ p: Double, kind: String = "main") -> Takeaway.Item {
        Takeaway.Item(name: name, kind: kind, tier: "none", kcal: kcal, p: p, c: 40, f: 20)
    }
    private var cheesesteaks: [Takeaway.Item] {
        [dish("Proper Cheesesteak, regular", 600, 38), dish("Proper Cheesesteak (extra cheese)", 640, 41),
         dish("Proper Cheesesteak, mushroom", 620, 39), dish("Plain wings", 400, 36), dish("Loaded tenders", 520, 40)]
    }

    /// 22 Nov, "then got stuck": A + B offered again as B + A, and three cheesesteak orders with the one title.
    func testNoOrderIsOfferedTwice() {
        let p = Takeaway.plan(menu: cheesesteaks, home: [], kcal: 1100, protein: 70, place: "Sparrows")
        let keys: [String] = p.combos.map { $0.0.key }
        XCTAssertEqual(keys.count, 3, "filled with other orders")
        XCTAssertEqual(Set(keys).count, keys.count)
        let shown: [String] = p.combos.map { (c: (Takeaway.Combo, String)) -> String in
            str(Takeaway.json(c.0, note: c.1, restaurant: "Sparrows", kcal: 1100)["title"])
        }
        XCTAssertEqual(Set(shown).count, shown.count)
    }

    func testPhillyCheesesteakIsTheProperOne() {
        let found = Takeaway.onMenu(["Philly cheesesteak"], cheesesteaks)
        XCTAssertTrue(found.missing.isEmpty)
        XCTAssertEqual(found.want, ["Proper Cheesesteak, regular"])
        XCTAssertEqual(Takeaway.onMenu(["seafood pancake"], [dish("Kimchi pancake", 600, 12)]).missing, ["seafood pancake"], "not a style")
        XCTAssertEqual(Takeaway.whose("Sparrows"), "Sparrows'")
        XCTAssertEqual(Takeaway.whose("Nando's"), "Nando's")
        XCTAssertEqual(Takeaway.whose("Gami"), "Gami's")
    }

    func testNoWingsIsACorrectionAndNotALog() {
        XCTAssertTrue(Takeaway.correcting("No wings on DoorDash"))
        XCTAssertTrue(Takeaway.correcting("don’t see the boneless option"))
        XCTAssertFalse(Takeaway.correcting("had it, no sauce on the app"))
        XCTAssertFalse(Takeaway.correcting("no dips"))
        let card: JSON = ["takeaway": ["restaurant": "Sparrows"] as JSON]
        let turns = [Assistant.Turn(me: false, text: "", result: card), Assistant.Turn(me: true, text: "No wings on DoorDash")]
        XCTAssertEqual(str(Takeaway.correctedCard(turns)?["restaurant"]), "Sparrows")
    }

    func testNoWingsKeepsTheCheesesteak() {
        let lines: [JSON] = [["name": "Proper Cheesesteak, regular"], ["name": "Plain wings"]]
        let card: JSON = ["combos": [["lines": lines] as JSON] as [JSON]]
        let kept: [String] = Takeaway.keptDish(card, said: "No wings on DoorDash")
        XCTAssertEqual(kept, ["Proper Cheesesteak"])
        XCTAssertTrue(Takeaway.keptDish(card, said: "no cheesesteak on DoorDash").isEmpty)
        let p = Takeaway.plan(menu: cheesesteaks, home: [], kcal: 1100, protein: 70, want: kept, avoid: ["wings"], place: "Sparrows")
        XCTAssertFalse(p.combos.isEmpty)
        for (c, _) in p.combos {
            XCTAssertTrue(c.item.name.hasPrefix("Proper Cheesesteak"))
            XCTAssertFalse(c.dishes.contains { $0.0.name == "Plain wings" })
        }
    }

    @MainActor func testAnOldPhotoLetsGoOnceTheChatMovesOn() {
        let photo = UIImage()
        var turns = [Assistant.Turn(me: true, text: "No wings on DoorDash", images: [photo]),
                     Assistant.Turn(me: false, text: "Just the cheesesteak"),
                     Assistant.Turn(me: true, text: "how much was the bread?")]
        XCTAssertEqual(Assistant.carriedPhotos(turns).count, 1, "still about it")
        let card: JSON = ["takeaway": ["restaurant": "Thai Social"] as JSON]
        turns[2] = Assistant.Turn(me: true, text: "From Thai social?")
        turns.append(Assistant.Turn(me: false, text: "", result: card))
        turns.append(Assistant.Turn(me: true, text: "Bbq noodle bar is a new place on DoorDash"))
        XCTAssertTrue(Assistant.carriedPhotos(turns).isEmpty, "moved on")
        turns[4] = Assistant.Turn(me: true, text: "what was in that photo?")
        XCTAssertEqual(Assistant.carriedPhotos(turns).count, 1, "asked about by name")
    }

    func testAPlaceTypedInTheMessage() {
        XCTAssertTrue(Takeaway.typed("Bbq noodle bar", in: "Bbq noodle bar is a new place on DoorDash"))
        XCTAssertTrue(Takeaway.typed("KFC", in: "kfc"))
        XCTAssertFalse(Takeaway.typed("Sparrows", in: "how much was the bread?"))
    }

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

    /// Every typed message is asked: the ask reads choose, find, log or other however it's put (find-check.js has the cases).
    func testTheAskHasTheFourIntents() {
        let p = Takeaway.routeAsk("Gami tonight?", earlier: "")
        XCTAssertTrue(p.contains("choose:") && p.contains("find:") && p.contains("log:") && p.contains("other:"))
        XCTAssertTrue(p.contains("Their message: \"Gami tonight?\""))
        XCTAssertEqual(dict(Takeaway.routeSchema["properties"])["intent"].flatMap { $0 as? JSON }?["enum"] as? [String], ["choose", "find", "log", "other"])
    }

    /// 70 g of protein asked for and dinners of 35 to 52 g found: not called a fit. The ones that reach it come first
    /// and the sentence says how many do.
    func testPlacesSayWhetherTheyReachTheProtein() {
        func spot(_ name: String, _ kcal: Double, _ p: Double) -> JSON {
            ["name": name, "area": "Melbourne", "cuisine": "Chicken", "dish": "A box", "published": "full", "kj": 0, "kcal": kcal, "protein_g": p, "carbs_g": 50, "fat_g": 20]
        }
        let short: JSON = ["found": true, "places": [spot("A", 906, 52), spot("B", 760, 35), spot("C", 837, 50)] as [JSON]]
        let none = Takeaway.places(short, area: "Melbourne", asked: "", meal: "Dinner", kcal: 1000, protein: 70)
        XCTAssertTrue(str(none["reply"]).hasPrefix("Nothing I found"), str(none["reply"]))
        XCTAssertEqual(list(dict(none["places"])["places"]).map { str($0["name"]) }, ["A", "C", "B"], "most protein first")
        let mixed: JSON = ["found": true, "places": [spot("A", 906, 52), spot("B", 990, 76), spot("C", 1400, 95)] as [JSON]]
        let some = Takeaway.places(mixed, area: "Melbourne", asked: "", meal: "Dinner", kcal: 1000, protein: 70)
        XCTAssertTrue(str(some["reply"]).contains("1 of these 3"), str(some["reply"]))
        XCTAssertEqual(list(dict(some["places"])["places"]).map { str($0["name"]) }, ["B", "C", "A"], "the one that fits, then by protein (C is far over the calories)")
        let all: JSON = ["found": true, "places": [spot("A", 900, 70), spot("B", 990, 76)] as [JSON]]
        XCTAssertTrue(str(Takeaway.places(all, area: "Melbourne", asked: "", meal: "Dinner", kcal: 1000, protein: 70)["reply"]).contains("these 2 in Melbourne fit"))
    }

    /// "Any good lunch spots in South Yarra?": the places the search found, their kJ winning, a dish with no energy read
    /// on a page marked estimated, and a place on the list found again by a tap or by the router's "the Greek one".
    func testFindingPlaces() {
        let found: JSON = ["found": true, "places": [
            ["name": "Spudbar", "area": "Chapel St", "cuisine": "Potato bowls", "dish": "The Chicken Power Bowl", "published": "full", "kj": 0, "kcal": 497, "protein_g": 46, "carbs_g": 40, "fat_g": 12],
            ["name": "Zeus Street Greek", "area": "Chapel St", "cuisine": "Greek", "dish": "Chargrilled Chicken", "published": "energy", "kj": 2760, "kcal": 650, "protein_g": 50, "carbs_g": 60, "fat_g": 22],
            ["name": "Wokinabox", "area": "South Yarra", "cuisine": "Asian", "dish": "The Satay", "published": "energy", "kj": 0, "kcal": 655, "protein_g": 40, "carbs_g": 70, "fat_g": 25],
            ["name": "", "area": "", "cuisine": "", "dish": "", "published": "none", "kj": 0, "kcal": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0]] as [JSON]]
        let r = Takeaway.places(found, area: "South Yarra", asked: "any good lunch spots in South Yarra?", meal: "Lunch", kcal: 700, protein: 45)
        XCTAssertEqual(str(r["kind"]), "places")
        let pl = dict(r["places"]), ps = list(pl["places"])
        XCTAssertEqual(ps.count, 3, "the empty one dropped")
        XCTAssertEqual(num(ps[1]["kcal"]), 660, "2760 kJ is 660 kcal, not the 650 it said")
        XCTAssertEqual(str(ps[0]["published"]), "full")
        XCTAssertEqual(str(ps[2]["published"]), "none", "no kJ read: estimated")
        XCTAssertEqual(str(pl["asked"]), "any good lunch spots in South Yarra?")
        XCTAssertEqual(str(Takeaway.place("Zeus Street Greek", in: pl)?["name"]), "Zeus Street Greek")
        XCTAssertEqual(str(Takeaway.place("zeus street", in: pl)?["name"]), "Zeus Street Greek")
        XCTAssertNil(Takeaway.place("Gami", in: pl))
        // nothing found: said so, no list
        XCTAssertEqual(str(Takeaway.places(["found": false, "places": [] as [JSON]], area: "Nowhere", asked: "", meal: "Lunch", kcal: 700, protein: 45)["kind"]), "answer")
    }

    /// "near me" or "near work" is nowhere to search; a suburb or a street is.
    func testVagueAreas() {
        for a in ["", "near me", "near work", "here", "home", "around me", "nearby"] { XCTAssertTrue(Takeaway.vague(a), a) }
        for a in ["South Yarra", "Chapel St", "the city", "near Prahran"] { XCTAssertFalse(Takeaway.vague(a), a) }
        // where they are now (their suburb from the phone) for "near me"; not for "near work", where they may not be
        for a in ["", "near me", "around me", "nearby", "here"] { XCTAssertTrue(Takeaway.here(a), a) }
        for a in ["near work", "home", "South Yarra"] { XCTAssertFalse(Takeaway.here(a), a) }
    }

    /// A food saved with 100 g as its "serving" shows per 100 g ("379 kcal per serving" was a protein powder's per 100 g).
    func testHundredGramsIsNotAServing() {
        let c = FoodMath.conv(["name": "Protein powder", "unit": "g", "kcalPer100": 379, "servingSize": 100])
        XCTAssertNil(c.countKcal)
        XCTAssertEqual(c.kcalPer100, 379)
        XCTAssertEqual(FoodMath.conv(["name": "Protein powder", "unit": "g", "kcalPer100": 379, "servingSize": 30]).countKcal ?? 0, 113.7, accuracy: 0.1)
    }

    /// "Want something from Gami tomorrow" came back with a shake and ice cream: home only when they bring it up.
    func testHomeOnlyWhenAsked() {
        XCTAssertFalse(Takeaway.asksForHome("want something from gami tomorrow, lunch"))
        XCTAssertTrue(Takeaway.asksForHome("Gami for dinner with a shake and ice cream"))
        XCTAssertTrue(Takeaway.asksForHome("no milk left, I want the wings"))
        // only Gami named: dishes alone, and a shake offered when the best one is short of protein
        let p = Takeaway.plan(menu: gami, home: [], kcal: 600, protein: 45, place: "Gami")
        let r = Takeaway.result(p, home: [], tips: home, menu: gami, shown: "Gami", kcal: 600, protein: 45, meal: "Lunch", smallest: 545)
        let c = list(dict(r["takeaway"])["combos"])[0]
        XCTAssertTrue(list(c["lines"]).allSatisfy { $0["dish"] as? Bool == true }, "only Gami's dishes, nothing from home")
        if !p.meets { XCTAssertNotNil(c["tip"], "short of the protein: a shake offered, not added") }
        XCTAssertFalse(list(c["swaps"]).isEmpty, "other dishes to swap in")
        XCTAssertFalse(str(r["reply"]).contains("Scan"), "no nudge to scan when a shake is on offer")
    }

    /// ✕, ⇄ and the offered shake: the totals, how far over, the count on the button and where the numbers came from follow.
    func testEditingTheCard() {
        let p = Takeaway.plan(menu: gami, home: home, kcal: 854, protein: 59, want: ["chicken burger"], place: "Gami")
        let c = Takeaway.json(p.combos[0].0, note: "", restaurant: "Gami", kcal: 854)
        let n = list(c["lines"]).count
        XCTAssertGreaterThan(n, 1)
        let off = Takeaway.edited(c, off: [n - 1], dish: nil, tip: false, restaurant: "Gami", kcal: 854)
        XCTAssertEqual(num(off["count"]), Double(n - 1))
        XCTAssertEqual(num(off["kcal"]) ?? 0, (num(c["kcal"]) ?? 0) - (num(list(c["lines"])[n - 1]["kcal"]) ?? 0), accuracy: 1.5)
        // the burger swapped for the tenders: the title and the source line follow
        let tenders: JSON = ["name": "Original tenders, 4 pcs", "tier": "energy", "kcal": 669, "p": 42, "c": 40, "f": 30]
        let swapped = Takeaway.edited(c, off: [], dish: tenders, tip: false, restaurant: "Gami", kcal: 854)
        XCTAssertTrue(str(swapped["title"]).hasPrefix("Original tenders"))
        XCTAssertTrue(str(swapped["source"]).hasPrefix("Original tenders from Gami's kJ"))
        XCTAssertEqual(str(list(swapped["lines"])[0]["name"]), "Original tenders, 4 pcs")
        // the dish taken off: the source line is only the home foods
        XCTAssertFalse(str(Takeaway.edited(c, off: [0], dish: nil, tip: false, restaurant: "Gami", kcal: 854)["source"]).contains("Gami"))
        // the offered shake put in
        let best = Takeaway.plan(menu: gami, home: [], kcal: 600, protein: 45).combos[0].0
        var lone = Takeaway.json(best, note: "", restaurant: "Gami", kcal: 600)
        let before = num(lone["p"]) ?? 0
        lone["tip"] = Takeaway.tip(for: best, protein: 45, home: home)
        let added = Takeaway.edited(lone, off: [], dish: nil, tip: true, restaurant: "Gami", kcal: 600)
        XCTAssertEqual(list(added["lines"]).count, list(lone["lines"]).count + 1)
        XCTAssertGreaterThan(num(added["p"]) ?? 0, before)
    }

    /// The owner's burrito chat, 15 Nov: "under 700cals" was dropped by the next message, and every list led with the
    /// protein nobody had asked about.
    func testCaloriesSaidEarlierAreKept() {
        XCTAssertEqual(Takeaway.saidKcal(["Reckon I could do a burrito for under 700cals from DoorDash??", "Find some places"]), 700)
        XCTAssertEqual(Takeaway.saidKcal(["600 calories", "actually 750 kcal"]), 750, "the latest")
        XCTAssertNil(Takeaway.saidKcal(["Find some places", "2 burritos"]))
    }

    func testWithoutProteinAskedTheCaloriesDecide() {
        let r: JSON = ["found": true, "places": [
            ["name": "Guzman y Gomez", "dish": "Grilled Chicken Bowl", "kcal": 660, "protein_g": 44, "published": "full", "kj": 2760] as JSON,
            ["name": "Mad Mex", "dish": "Burrito", "kcal": 910, "protein_g": 65, "published": "none", "kj": 0] as JSON,
            ["name": "Zambrero", "dish": "Small Burrito", "kcal": 522, "protein_g": 21, "published": "full", "kj": 2186] as JSON] as [Any]]
        let out = Takeaway.places(r, area: "Melbourne", asked: "", meal: "Dinner", kcal: 700, protein: 58, proteinAsked: false)
        let names = list(dict(out["places"])["places"]).map { str($0["name"]) }
        XCTAssertEqual(names, ["Guzman y Gomez", "Zambrero", "Mad Mex"], "the two under 700 first, most protein first; the one over last")
        XCTAssertFalse(str(out["reply"]).contains("g protein"), str(out["reply"]))
    }

    /// "Don't see boneless" after a card (21 Nov, PUBCHA): the router may put the card's whole title in avoid; the
    /// dish goes either way, and the word alone takes every boneless one.
    func testADishTheyCantSeeIsLeftOut() {
        let whole = Takeaway.plan(menu: gami, home: [], kcal: 1400, protein: 80, avoid: ["Original boneless, 7 pcs, a water shake and ice cream"], place: "Gami")
        XCTAssertFalse(whole.combos.contains { $0.0.item.name.contains("boneless") })
        let word = Takeaway.plan(menu: gami, home: [], kcal: 1400, protein: 80, avoid: ["boneless"], place: "Gami")
        XCTAssertFalse(word.combos.contains { $0.0.item.name.lowercased().contains("boneless") })
        XCTAssertFalse(word.combos.isEmpty)
    }

    /// PUBCHA as the owner's claude.ai chat did it (21 Nov, design/takeaway-combos-mockup.html): nothing published, 1,400
    /// kcal and 80 g. Two dishes or part of one reach it; the card adds up and shows a range; asked again for others,
    /// none already shown come back; a dish asked about comes whole and as some of it.
    private let pubcha: [Takeaway.Item] = [
        .init(name: "Small Fried Boneless Chicken", kind: "main", tier: "none", kcal: 700, p: 40, c: 40, f: 40),
        .init(name: "Large Fried Boneless Chicken", kind: "main", tier: "none", kcal: 1300, p: 75, c: 75, f: 75),
        .init(name: "Beef Bulgogi Rice Bowl", kind: "main", tier: "none", kcal: 750, p: 32, c: 90, f: 25),
        .init(name: "Ginseng Chicken Soup", kind: "main", tier: "none", kcal: 650, p: 45, c: 50, f: 25),
        .init(name: "Seafood Pancake", kind: "main", tier: "none", kcal: 900, p: 28, c: 90, f: 45),
        .init(name: "Kimchi Dumplings, 6 pcs", kind: "side", tier: "none", kcal: 380, p: 14, c: 45, f: 15),
        .init(name: "Tteokbokki", kind: "main", tier: "none", kcal: 550, p: 10, c: 100, f: 10)]

    func testTwoDishesAndPartsOfOne() throws {
        let p = Takeaway.plan(menu: pubcha, home: [], kcal: 1400, protein: 80, place: "PUBCHA")
        XCTAssertTrue(p.meets)
        let best = p.combos[0].0
        XCTAssertLessThanOrEqual(best.kcal, 1410); XCTAssertGreaterThanOrEqual(best.p, 79.5)
        XCTAssertGreaterThanOrEqual(best.kcal, 1340, "close to what they have, not far under")
        XCTAssertFalse(p.combos.contains { $0.0.dishes.contains { $0.0.name == "Tteokbokki" } }, "low protein: never in an order")
        XCTAssertFalse(p.combos.contains { c in c.0.dishes.count == 2 && c.0.dishes[0].0.name.contains("Fried Boneless") && c.0.dishes[1].0.name.contains("Fried Boneless") },
                       "not the small and the large chicken together")
        let j = Takeaway.json(best, note: "Best fit", restaurant: "PUBCHA", kcal: 1400)
        XCTAssertEqual(list(j["lines"]).reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, num(j["kcal"]) ?? 0, accuracy: 2, "the card adds up")
        let lo = try XCTUnwrap(num(j["kcalLo"])), hi = try XCTUnwrap(num(j["kcalHi"]))
        XCTAssertLessThan(lo, num(j["kcal"]) ?? 0); XCTAssertGreaterThan(hi, num(j["kcal"]) ?? 0)
        XCTAssertTrue(str(j["source"]).contains("Type it"))
        // half of a dish: said on its line and in its name when added
        let half = Takeaway.json(Takeaway.Combo(dishes: [(pubcha[2], 1), (pubcha[0], 0.5)]), note: "", restaurant: "PUBCHA", kcal: 1400)
        XCTAssertEqual(str(half["title"]), "Beef Bulgogi Rice Bowl + ½ Small Fried Boneless Chicken")
        XCTAssertEqual(num(half["kcal"]), 1100)
        XCTAssertEqual(str(list(list(half["lines"])[1]["add"])[0]["name"]), "PUBCHA Small Fried Boneless Chicken (½)")

        // "any other options?": four more, none already shown
        let shown = Set(p.combos.map { $0.0.key })
        let more = Takeaway.plan(menu: pubcha, home: [], kcal: 1400, protein: 80, place: "PUBCHA", shown: shown, count: 4)
        XCTAssertEqual(more.combos.count, 4)
        XCTAssertTrue(more.combos.allSatisfy { !shown.contains($0.0.key) })

        // "what about the seafood pancake?": with it, the whole one and some of it
        let pancake = Takeaway.plan(menu: pubcha, home: [], kcal: 1400, protein: 80, want: ["seafood pancake"], place: "PUBCHA")
        XCTAssertTrue(pancake.combos.allSatisfy { c in c.0.dishes.contains { $0.0.name == "Seafood Pancake" } })
        XCTAssertTrue(pancake.combos.contains { c in c.0.dishes.contains { $0.0.name == "Seafood Pancake" && $0.1 < 0.99 } }, "some of it, to fit")
        XCTAssertEqual(Takeaway.dishes(["high protein"]), [], "how they'd like it, not a dish")
    }
}
