import XCTest
@testable import CheatDays

/// Typing a food with its numbers logs it straight away; questions still go to the AI.
final class QuickLogTests: XCTestCase {
    func testShortForm() {
        let l = QuickLog.parseLine("chicken sandwich - 600 kcal - 60p 30f 10c")
        XCTAssertEqual(l, QuickLog.Line(name: "Chicken sandwich", kcal: 600, p: 60, c: 10, f: 30))
    }

    func testWordsAndKilojoules() {
        let a = QuickLog.parseLine("protein shake 1046 kJ 40g protein 5 fats 8 carbs")
        XCTAssertEqual(a?.name, "Protein shake")
        XCTAssertEqual(a?.kcal, 250)                       // 1046 kJ ÷ 4.184
        XCTAssertEqual(a?.p, 40); XCTAssertEqual(a?.f, 5); XCTAssertEqual(a?.c, 8)
        let b = QuickLog.parseLine("wrap calories: 450, protein 35g, fat 12, carbohydrates 40")
        XCTAssertEqual(b, QuickLog.Line(name: "Wrap", kcal: 450, p: 35, c: 40, f: 12))
        XCTAssertEqual(QuickLog.parseLine("soup 800 kilojoules")?.kcal, 191)
    }

    func testCaloriesFromMacrosAlone() {
        XCTAssertEqual(QuickLog.parseLine("steak 50p 20f")?.kcal, 380)   // 4×50 + 9×20
    }

    func testSeveralLines() {
        let lines = QuickLog.instant("eggs 140 kcal 12p\ntoast 160 cal; flat white 120kcal")
        XCTAssertEqual(lines?.map(\.name), ["Eggs", "Toast", "Flat white"])
    }

    func testQuestionsGoToTheAI() {
        XCTAssertNil(QuickLog.instant("is 600 kcal a lot for lunch?"))
        XCTAssertNil(QuickLog.instant("what should I eat with 600 kcal left"))
        XCTAssertNil(QuickLog.instant("chicken sandwich"))                      // no numbers: the AI works it out
        XCTAssertNotNil(QuickLog.instant("2 pancakes 350 kcal"))
        XCTAssertEqual(QuickLog.parseLine("2 pancakes 350 kcal")?.p, nil)       // "pancakes" isn't protein
    }

    /// "Want around 60g protein from it", after asking about 918 g of chicken, was logged as a food called "Want around
    /// from it": a wish or a follow-up goes to the AI, with the chat
    func testWishesAndFollowUpsGoToTheAI() {
        XCTAssertNil(QuickLog.instant("Want around 60g protein from it"))
        XCTAssertNil(QuickLog.instant("need 40g protein"))
        XCTAssertNil(QuickLog.instant("about 500 kcal of that"))
        XCTAssertNotNil(QuickLog.instant("protein shake 250 cal 40p"))
        XCTAssertNotNil(QuickLog.instant("chicken sandwich - 600 kcal - 60p 30f 10c"))
    }

    /// 27 Nov: "1,240 kcal" logged as 1 kcal, the comma read as a decimal point. Three digits after a comma are
    /// thousands; anything else is a decimal comma.
    func testThousandsCommas() {
        XCTAssertEqual(QuickLog.parseLine("pizza 1,240 kcal")?.kcal, 1240)
        XCTAssertEqual(QuickLog.parseLine("yoghurt 150 kcal 12,5g protein")?.p, 12.5)
        XCTAssertEqual(QuickLog.parseLine("feast 1,240.5 kcal")?.kcal, 1241, "1240.5, rounded to a whole calorie")
        XCTAssertEqual(Fmt.number("1,240"), 1240)
        XCTAssertEqual(Fmt.number("1,240.5"), 1240.5)
        XCTAssertEqual(Fmt.number("12,5"), 12.5)
        XCTAssertEqual(Fmt.number("0,125"), 0.125, "a lone 0 before the comma is a decimal")
        XCTAssertEqual(Fmt.number("1,240,000"), 1_240_000)
        XCTAssertEqual(Fmt.typed("22,5"), 22.5)
        XCTAssertEqual(Assistant.calorieTarget("what can I eat for 1,240 calories?"), 1240)
        XCTAssertEqual(Tweak.amount("1,200g"), 1200)
    }
}
