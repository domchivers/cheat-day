import XCTest
@testable import CheatDays

/// A meal as it happens: when a chat is one, the running tally's sums, each piece keeping its price, what's sent back
/// to Claude, and the one entry that's changed in place rather than added again.
@MainActor
final class MealChatTests: XCTestCase {
    private func part(_ name: String, _ kcal: Double, p: Double, c: Double = 0, f: Double = 0, g: Double = 0) -> JSON {
        ["name": name, "kcal": kcal, "protein_g": p, "carbs_g": c, "fat_g": f, "grams": g]
    }
    private func card(_ parts: [JSON], next: [JSON] = [], notes: String = "") -> JSON {
        ["kind": "meal", "estimate": ["name": "Shared dinner", "notes": notes, "parts": parts] as JSON, "plan": ["suggestions": next] as JSON]
    }

    // MARK: when it's a meal

    func testTheSharedDinnerStartsOne() {
        XCTAssertTrue(MealChat.starts("Everything we ordered. Got to share it all, haven't eaten yet. Need to hit 107g protein for today still and have 1334 kcals"))
        XCTAssertTrue(MealChat.starts("Pizza night split with 3 friends from Domino's"))
        XCTAssertTrue(MealChat.starts("Hotpot night, sharing with 3 mates"))
        XCTAssertTrue(MealChat.starts("What else to eat? Other bits"))
    }

    func testAnOrdinaryMessageDoesNot() {
        XCTAssertFalse(MealChat.starts("2 eggs on toast and a flat white"))
        XCTAssertFalse(MealChat.starts("A recipe under 600 kcal"))
        XCTAssertFalse(MealChat.starts("Can you split this into its parts"))
        XCTAssertFalse(MealChat.starts("What fits the rest of today?"))
    }

    func testOnceAMealAlwaysAMeal() {
        let turns = [Assistant.Turn(me: true, text: "Sharing it all, haven't eaten yet"),
                     Assistant.Turn(me: false, text: "Protein first.", result: card([])),
                     Assistant.Turn(me: true, text: "The squid")]
        XCTAssertTrue(MealChat.wanted(turns), "\"The squid\" alone is part of the meal")
        XCTAssertFalse(MealChat.wanted([Assistant.Turn(me: true, text: "The squid")]))
    }

    // MARK: the sums

    func testCountsAfterTheComma() {
        XCTAssertEqual(MealChat.counted("Lamb skewers, 5")?.n, 5)
        XCTAssertEqual(MealChat.counted("Lamb chop, 3 pieces")?.unit, "piece")
        XCTAssertEqual(MealChat.counted("Lamb chop, 3 pieces")?.food, "lamb chop")
        XCTAssertEqual(MealChat.counted("Stinky tofu, ⅓ square")?.n ?? 0, 1 / 3.0, accuracy: 0.001)
        XCTAssertEqual(MealChat.counted("Stinky tofu, 1/3 square")?.n ?? 0, 1 / 3.0, accuracy: 0.001)
        XCTAssertEqual(MealChat.counted("Potato, 2 small pieces")?.unit, "piece")
        XCTAssertNil(MealChat.counted("Noodles, a few forkfuls"))
        XCTAssertNil(MealChat.counted("Noodles"))
    }

    func testAPieceKeepsItsPrice() {
        // 2 chop pieces at 65 each, then 3: one more piece's worth and nothing else, though Claude said 200
        let before = [part("Lamb chop, 2 pieces", 130, p: 10, c: 0, f: 9, g: 50), part("Lamb skewers, 5", 325, p: 24, c: 2, f: 25)]
        let now = [part("Lamb chop, 3 pieces", 200, p: 14, c: 1, f: 15, g: 80), part("Lamb skewers, 5", 327, p: 24, c: 3, f: 24), part("Squid, 2", 85, p: 12)]
        let held = MealChat.held(now, before: before)
        XCTAssertEqual(num(held[0]["kcal"]), 195)
        XCTAssertEqual(num(held[0]["protein_g"]), 15)
        XCTAssertEqual(num(held[0]["grams"]), 75)
        XCTAssertEqual(num(held[1]["kcal"]), 325, "the same count is the same numbers, exactly")
        XCTAssertEqual(num(held[1]["carbs_g"]), 2)
        XCTAssertEqual(num(held[2]["kcal"]), 85, "a food new to the tally is as Claude priced it")
    }

    func testAnotherUnitIsntHeld() {
        let before = [part("Lamb chop, 1 chop", 190, p: 14)]
        let now = [part("Lamb chop, 3 pieces", 190, p: 14)]
        XCTAssertEqual(num(MealChat.held(now, before: before)[0]["kcal"]), 190)
    }

    func testTotalsAreAddedUpHere() {
        let t = MealChat.totals([part("Lamb skewers, 5", 325, p: 24, c: 2, f: 25), part("Squid, 2", 85, p: 12, c: 3, f: 2)])
        XCTAssertEqual(t, MealChat.Totals(kcal: 410, p: 36, c: 5, f: 27))
    }

    func testAQuestionKeepsTheTally() {
        let before = card([part("Lamb skewers, 5", 325, p: 24)], notes: "Lamb skewers: 10 skewers, 65 kcal and 4.8 g protein for ONE skewer")
        let answer: JSON = ["reply": "Yes, the tofu sheet.", "kind": "estimate", "estimate": ["name": "", "notes": "", "parts": [Any]()] as JSON,
                            "plan": ["suggestions": [part("Tofu sheet", 120, p: 8)]] as JSON]
        let out = MealChat.shaped(answer, before: before, said: "Instead of noodles the tofu sheet??", photos: false, base: ["kcal": 1334, "p": 107])
        XCTAssertEqual(str(out["kind"]), "meal")
        XCTAssertEqual(MealChat.tally(out).count, 1, "\"instead of noodles?\" is not eating, and not an empty tally either")
        XCTAssertEqual(num(dict(out["estimate"])["kcal_total"]), 325)
        XCTAssertTrue(str(dict(out["estimate"])["notes"]).hasPrefix("Lamb skewers"), "the price list carries on")
        XCTAssertEqual(MealChat.next(out).count, 1)
        XCTAssertEqual(num(dict(out["mealBase"])["kcal"]), 1334)
    }

    func testNewPhotosCanRepriceAPiece() {
        let before = card([part("Lamb chop, 2 pieces", 130, p: 10)])
        let answer: JSON = ["kind": "estimate", "estimate": ["parts": [part("Lamb chop, 2 pieces", 110, p: 9)]] as JSON, "plan": ["suggestions": [Any]()] as JSON]
        let out = MealChat.shaped(answer, before: before, said: "Here's the chop", photos: true, base: [:])
        XCTAssertEqual(num(MealChat.tally(out)[0]["kcal"]), 110)
    }

    // MARK: what it's measured against

    func testTheirOwnNumbers() {
        let s = MealChat.stated("Need to hit 107g protein for today still and have 1334 kcals")
        XCTAssertEqual(s.protein, 107)
        XCTAssertEqual(s.kcal, 1334)
        let t = MealChat.stated("950 left and protein 70 g to go, 1,200 calories")
        XCTAssertEqual(t.protein, 70)
        XCTAssertEqual(t.kcal, 1200)
        XCTAssertNil(MealChat.stated("Had 2 squid actually").kcal)
    }

    // MARK: what's sent back

    func testTheWholeChatGoesWithTheLatestCardOnly() {
        var turns: [Assistant.Turn] = []
        for i in 0..<12 {   // past the eight turns an ordinary chat keeps
            turns.append(Assistant.Turn(me: true, text: "Message \(i)"))
            turns.append(Assistant.Turn(me: false, text: "Answer \(i)", result: card([part("Squid, \(i + 1)", Double(40 * (i + 1)), p: 6, g: 30)],
                                                                                       next: [["name": "Lamb chop", "amount": "1 piece"]], notes: "Squid: 5, 40 kcal and 6 g protein for ONE")))
        }
        turns.append(Assistant.Turn(me: true, text: "What did I have?"))
        let sent = MealChat.earlier(turns)
        XCTAssertTrue(sent.hasPrefix("They: Message 0\nYou: Answer 0"), "from the very first message")
        XCTAssertEqual(sent.components(separatedBy: "[eaten so far").count, 2, "the tally once, from the latest card")
        XCTAssertTrue(sent.contains("You: Answer 11 [eaten so far, 480 kcal: Squid, 12 30 g 480 kcal P6] [price list for one piece: Squid: 5, 40 kcal and 6 g protein for ONE] [you suggested next: Lamb chop, 1 piece]"))
        XCTAssertFalse(sent.contains("What did I have?"), "their latest message goes after, as They now say")
    }

    // MARK: the one entry

    private let today = "2026-11-22"
    private func record() -> JSON {
        ["budget": 2000, "day": ["date": today, "items": [["id": "a1", "name": "Oats", "kcal": 320] as JSON], "workouts": [Any]()] as JSON,
         "history": [Any](), "recent": [Any](), "updatedAt": 1]
    }
    private func items(_ d: JSON) -> [JSON] { list(dict(d["day"])["items"]) }

    func testAddingAgainChangesTheSameEntry() {
        var d = record()
        let first = [part("Lamb skewers, 5", 325, p: 24, c: 2, f: 25), part("Squid, 2", 85, p: 12, c: 3, f: 2)]
        for op in MealChat.entryOps(first, name: "Shared dinner", meal: "Dinner", over: nil, in: d, today: today, id: "m1") { Store.apply(op, to: &d, today: today) }
        XCTAssertEqual(items(d).count, 2)
        let more = first + [part("Lamb chop, 3 pieces", 195, p: 15, c: 0, f: 13)]
        for op in MealChat.entryOps(more, name: "Shared dinner", meal: "Dinner", over: "m1", in: d, today: today, id: "m2") { Store.apply(op, to: &d, today: today) }
        let meals = items(d).filter { str($0["name"]) == "Shared dinner" }
        XCTAssertEqual(meals.count, 1, "one entry, never one per tap")
        XCTAssertEqual(str(meals.first?["id"]), "m2")
        XCTAssertEqual(num(meals.first?["kcal"]), 605)
        XCTAssertEqual(str(meals.first?["meal"]), "Dinner")
        XCTAssertEqual(meals.first?["ingredients"] as? [String], ["Lamb skewers, 5", "Squid, 2", "Lamb chop, 3 pieces"])
        XCTAssertEqual(FoodMath.macros(meals.first ?? [:], kcal: 605)?.p ?? 0, 51, accuracy: 0.01, "the protein is the tally's, not scaled from kcal")
        XCTAssertTrue(MealChat.matches(meals.first, parts: more))
        XCTAssertFalse(MealChat.matches(meals.first, parts: first))
        XCTAssertEqual(str(items(d).first?["id"]), "a1", "the rest of the day is untouched")
    }

    func testAnEntryTakenOffIsntTakenOffAgain() {
        let d = record()
        let ops = MealChat.entryOps([part("Squid, 2", 85, p: 12)], name: "Dinner", meal: "Dinner", over: "gone", in: d, today: today, id: "m3")
        XCTAssertEqual(ops.map { str($0["type"]) }, ["add"])
    }

    func testTheEntryIsTheLatestOne() {
        var older = card([]), newer = card([])
        older["mealEntry"] = "m1"; newer["mealEntry"] = "m2"
        let turns = [Assistant.Turn(me: false, text: "", result: older), Assistant.Turn(me: true, text: "had more"), Assistant.Turn(me: false, text: "", result: newer)]
        XCTAssertEqual(MealChat.entryId(turns), "m2")
        XCTAssertNil(MealChat.entryId([Assistant.Turn(me: false, text: "", result: card([]))]))
    }
}
