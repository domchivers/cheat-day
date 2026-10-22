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
}
