import XCTest
@testable import CheatDays

/// Amor Roma's tiramisu, 14 Nov: a long black and half a box of cocoa-dusted tiramisu went 560, 249, 396 and 233 kcal
/// over four messages, every time at cocoa powder's 20 g protein a 100 g.
final class SteadyTests: XCTestCase {
    private func part(_ name: String, _ g: Double, kcal: Double, p: Double, c: Double, f: Double, size: String = "") -> JSON {
        ["name": name, "grams": g, "kcal": kcal, "protein_g": p, "carbs_g": c, "fat_g": f, "size": size, "numbers_from": "estimate"]
    }
    private func card(_ parts: [JSON]) -> JSON { ["name": "Long black and half a box of classic tiramisu", "parts": parts] }
    private func grams(_ e: JSON, _ name: String) -> Double? { CheatDays.list(e["parts"]).first { str($0["name"]) == name }.flatMap { num($0["grams"]) } }
    private let coffee = ["name": "Long black", "grams": 180.0, "kcal": 4.0, "protein_g": 0.3, "carbs_g": 0.0, "fat_g": 0.0, "size": "", "numbers_from": "estimate"] as JSON

    // 1. a dessert at more protein than a dessert can have isn't cocoa powder, and isn't counted as checked
    func testCocoaDustedTiramisuIsNotCocoaPowder() {
        XCTAssertNil(FoodReference.match("Tiramisu, cocoa dusted"))
        XCTAssertNil(FoodReference.match("Cocoa dusted tiramisu"))
        XCTAssertEqual(FoodReference.match("Cocoa powder")?.kcal, 327, "cocoa itself still is")
        XCTAssertTrue(Assistant.wrongFor(part("Tiramisu, cocoa dusted", 170, kcal: 556, p: 34, c: 25, f: 35)))
        XCTAssertFalse(Assistant.wrongFor(part("Tiramisu, cocoa dusted", 75, kcal: 190, p: 3.5, c: 12, f: 14)))
        let flagged = Assistant.sane(card([part("Tiramisu, cocoa dusted", 170, kcal: 556, p: 34, c: 25, f: 35)]))
        XCTAssertEqual(Assistant.checkedCount(CheatDays.list(flagged["parts"]).map { var x = $0; x["src"] = "afcd"; return x }), 0)
    }

    @MainActor
    func testTiramisuIsCheckedAgainstTiramisu() async {
        let e = await Assistant.ground(["name": "Tiramisu", "kcal_total": 556, "parts": [part("Tiramisu, cocoa dusted", 170, kcal: 556, p: 34, c: 25, f: 35)]])
        let p = CheatDays.list(e["parts"])[0]
        XCTAssertEqual(str(p["match"]), "Tiramisu, coffee, homemade")
        XCTAssertEqual(num(p["kcal"]), 432)   // 254 a 100 g
        XCTAssertEqual(num(p["protein_g"]) ?? 0, 8, accuracy: 0.1)
    }

    func testDessertsPastriesIceCreamAndSaucesHaveProteinCeilings() {
        XCTAssertEqual(Sanity.range("Tiramisu")?.proteinMax, 10)
        XCTAssertEqual(Sanity.range("Chocolate mousse")?.proteinMax, 10)
        XCTAssertEqual(Sanity.range("Croissant, plain")?.proteinMax, 12)
        XCTAssertEqual(Sanity.range("Vanilla ice cream")?.proteinMax, 6)
        XCTAssertEqual(Sanity.range("Hoisin sauce")?.proteinMax, 5)
        XCTAssertNotEqual(Sanity.range("Fish cake")?.label, "a cake or dessert", "a fish cake isn't a dessert")
        XCTAssertNotEqual(Sanity.range("Soy sauce")?.label, "a sauce or dressing", "soy sauce has real protein")
        XCTAssertNotEqual(Sanity.range("Satay sauce")?.label, "a sauce or dressing", "peanut sauces have real protein")
        XCTAssertNotEqual(Sanity.range("Ham and cheese croissant")?.label, "a pastry")
    }

    // 2. their weight is never put aside for a new look at the photo
    func testTheirWeightLocksThePart() {
        let first = Assistant.held(card([part("Tiramisu, cocoa dusted", 170, kcal: 432, p: 8, c: 27.5, f: 31.5, size: "range 60–170 g; 10 × ~17 g pieces, against the saucer"), coffee]),
                                   before: nil, said: "Long black and half the tiramisu, was very light and fluffy.").estimate
        let tir = CheatDays.list(first["parts"])[0]
        XCTAssertEqual(num(tir["low"]), 60); XCTAssertEqual(num(tir["high"]), 170)
        let second = Assistant.held(card([part("Tiramisu, cocoa dusted", 75, kcal: 190, p: 3.5, c: 12, f: 14), coffee]),
                                    before: first, said: "I'd say the box weight was around 150 g").estimate
        let locked = CheatDays.list(second["parts"])[0]
        XCTAssertEqual(locked["locked"] as? Bool, true)
        XCTAssertEqual(num(locked["low"]), 68); XCTAssertEqual(num(locked["high"]), 83)
        XCTAssertNil(CheatDays.list(second["parts"])[1]["locked"], "the coffee didn't change")
        let third = Assistant.held(card([part("Tiramisu, cocoa dusted", 120, kcal: 305, p: 5.6, c: 19, f: 22), coffee]),
                                   before: second, said: "Maybe can check female hand size in the photo")
        XCTAssertEqual(grams(third.estimate, "Tiramisu, cocoa dusted"), 75)
        XCTAssertEqual(num(third.estimate["kcal_total"]), 195)
        XCTAssertTrue(third.notes.first?.contains("75 g") == true)
        let fourth = Assistant.held(card([part("Tiramisu, cocoa dusted", 70, kcal: 178, p: 3.3, c: 11, f: 13), coffee]),
                                    before: third.estimate, said: "Pieces are about 1.5 m")
        XCTAssertEqual(grams(fourth.estimate, "Tiramisu, cocoa dusted"), 75, "a size doesn't move their weight")
        let fifth = Assistant.held(card([part("Tiramisu, cocoa dusted", 100, kcal: 254, p: 4.7, c: 16, f: 18.5), coffee]),
                                   before: third.estimate, said: "Actually I ate 100g of it")
        XCTAssertEqual(grams(fifth.estimate, "Tiramisu, cocoa dusted"), 100, "a new weight from them does")
    }

    // the same chat asked again after the fix: the old card's cocoa-powder numbers aren't copied onto the new one
    func testAnOldCardsWrongNumbersAreNotCarriedOn() {
        var bad = part("Tiramisu, cocoa dusted", 70, kcal: 229, p: 14, c: 10, f: 14); bad["src"] = "reference"; bad["match"] = "Cocoa powder"
        var good = part("Tiramisu, cocoa dusted", 70, kcal: 178, p: 3.3, c: 11.3, f: 13); good["src"] = "afcd"; good["match"] = "Tiramisu, coffee, homemade"
        let kept = Assistant.keepingEarlier(card([good]), card([bad]))
        XCTAssertEqual(str(CheatDays.list(kept["parts"])[0]["match"]), "Tiramisu, coffee, homemade")
        XCTAssertEqual(num(CheatDays.list(Assistant.steady(card([good]), earlier: [card([bad])])["parts"])[0]["kcal"]), 178)
        var batch = part("Chicken breast, boiled, 553 g batch", 100, kcal: 160, p: 37.4, c: 0, f: 2); batch["numbers_from"] = "them"
        XCTAssertFalse(Assistant.stale(batch), "their own boiled-down batch is theirs")
    }

    // 3. asking again with nothing new changes nothing
    func testAskingAgainChangesNothing() {
        let first = Assistant.held(card([part("Tiramisu, cocoa dusted", 80, kcal: 203, p: 3.8, c: 13, f: 15, size: "range 60–120 g")]), before: nil, said: "half the tiramisu").estimate
        let again = Assistant.held(card([part("Tiramisu, cocoa dusted", 110, kcal: 279, p: 5.2, c: 18, f: 20)]), before: first, said: "Can you check again?")
        XCTAssertEqual(grams(again.estimate, "Tiramisu, cocoa dusted"), 80)
        XCTAssertTrue(Assistant.asksAgainOnly("are you sure?"))
        XCTAssertTrue(Assistant.asksAgainOnly("Recheck"))
        XCTAssertFalse(Assistant.asksAgainOnly("check against the hand in the photo"))
        XCTAssertFalse(Assistant.asksAgainOnly("check again, it was 150 g"))
    }

    // 4. a new estimate outside the last range, with nothing hard from them, is brought back inside it
    func testOutsideTheRangeIsClamped() {
        let first = Assistant.held(card([part("Tiramisu, cocoa dusted", 80, kcal: 203, p: 3.8, c: 13, f: 15, size: "range 60–120 g")]), before: nil, said: "half the tiramisu").estimate
        let wider = Assistant.held(card([part("Tiramisu, cocoa dusted", 170, kcal: 432, p: 8, c: 27.5, f: 31.5, size: "range 140–200 g")]), before: first, said: "use the cup to size it")
        XCTAssertEqual(grams(wider.estimate, "Tiramisu, cocoa dusted"), 120)
        XCTAssertEqual(num(CheatDays.list(wider.estimate["parts"])[0]["kcal"]), 305)
        XCTAssertTrue(wider.notes.first?.contains("60–120 g") == true)
        let narrower = Assistant.held(card([part("Tiramisu, cocoa dusted", 75, kcal: 190, p: 3.5, c: 12, f: 14, size: "range 65–90 g")]), before: first, said: "use the cup to size it")
        XCTAssertEqual(grams(narrower.estimate, "Tiramisu, cocoa dusted"), 75)
        let p = CheatDays.list(narrower.estimate["parts"])[0]
        XCTAssertEqual(num(p["low"]), 65); XCTAssertEqual(num(p["high"]), 90)
        XCTAssertTrue(narrower.notes.isEmpty)
        let theirs = Assistant.held(card([part("Tiramisu, cocoa dusted", 170, kcal: 432, p: 8, c: 27.5, f: 31.5)]), before: first, said: "I had 10 pieces, about 17 g each")
        XCTAssertEqual(grams(theirs.estimate, "Tiramisu, cocoa dusted"), 170, "their count outranks the range")
    }

    // 5 and 7 are the AI's (density, count × grams per piece, in the rules); the range it writes is read back here
    func testTheRangeIsReadFromTheSize() {
        XCTAssertEqual(Assistant.range(inSize: "range 60–120 g; 10 × ~8 g pieces, against the saucer")?.low, 60)
        XCTAssertEqual(Assistant.range(inSize: "Range 60-120 g")?.high, 120)
        XCTAssertEqual(Assistant.range(inSize: "range about 60 g to 120 g")?.high, 120)
        XCTAssertNil(Assistant.range(inSize: "about 8 × 10 cm, against the cup"))
        XCTAssertTrue(Assistant.rules.contains("10 × ~7.5 g"))
        XCTAssertTrue(Assistant.rules.contains("light, fluffy, airy"))
    }

    // 6. a food's size in metres is asked about
    func testMetresAreQuestioned() {
        XCTAssertEqual(Assistant.unitQuestion("pieces about 1.5 m"), "Did you mean 1.5 cm?")
        XCTAssertNil(Assistant.unitQuestion("pieces about 1.5 cm"))
        XCTAssertNil(Assistant.unitQuestion("150 ml of milk"))
        XCTAssertNil(Assistant.unitQuestion("walked 20 m"), "20 m is a real distance, not a slip for a food's size")
    }

    func testAWeightOrCountIsTold() {
        XCTAssertTrue(Assistant.givesAmount("I'd say the box weight was around 150 g"))
        XCTAssertTrue(Assistant.givesAmount("I had 10"))
        XCTAssertTrue(Assistant.givesAmount("6 pieces"))
        XCTAssertFalse(Assistant.givesAmount("pieces about 1.5 cm"))
        XCTAssertFalse(Assistant.givesAmount("Maybe can check female hand size"))
    }
}
