import XCTest
@testable import CheatDays

/// "Change my portion to 150g" is a new amount, worked out with maths, not by a model.
final class TweakTests: XCTestCase {
    func testANewAmountIsReadOff() {
        XCTAssertEqual(Tweak.amount("change my portion to 150g"), 150)
        XCTAssertEqual(Tweak.amount("150 g"), 150)
        XCTAssertEqual(Tweak.amount("It was 200ml"), 200)
        XCTAssertEqual(Tweak.amount("make it 92.5 grams"), 92.5)
    }

    func testAChangeToTheFoodIsNotANewAmount() {
        XCTAssertNil(Tweak.amount("50g less rice"))
        XCTAssertNil(Tweak.amount("add 20g cheese"))
        XCTAssertNil(Tweak.amount("it was a large one"))
        XCTAssertNil(Tweak.amount("2 eggs, 150g"))
    }

    /// 180 g to 150 g is five sixths of the calories, with the weight 150 and still one portion.
    func testANewAmountScalesEverything() async throws {
        let item: JSON = ["name": "Chicken bowl", "kcal": 540.0, "grams": 180.0, "unit": "g", "unitLabel": "portion",
                          "kcalPerServing": 540.0, "servingSize": 180.0, "pServ": 45.0, "cServ": 40.0, "fServ": 20.0]
        let r = try await Tweak.ask(item, change: "change my portion to 150g")
        XCTAssertEqual(num(r.item["kcal"]), 450)
        XCTAssertEqual(num(r.item["grams"]), 150)
        XCTAssertEqual(num(r.item["servingSize"]), 150)
        XCTAssertEqual(r.reply, "Now 150 g: 450 kcal instead of 540.")
    }
}
