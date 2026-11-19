import XCTest
@testable import CheatDays

/// A food asked for as lean never takes a full-fat entry's numbers (19 Nov: non-fat Greek yoghurt counted as the ~10% fat one).
final class FatClashTests: XCTestCase {
    func testLeanAskedFullFatEntryClashes() {
        XCTAssertTrue(FoodReference.fatClash("Greek yoghurt, non-fat", "Yoghurt, natural, greek style (~10% fat)"))
        XCTAssertTrue(FoodReference.fatClash("Greek yoghurt, 0% fat", "Yoghurt, natural, greek style (~10% fat)"))
        XCTAssertTrue(FoodReference.fatClash("Light thickened cream", "Cream, thickened, regular fat"))
        XCTAssertTrue(FoodReference.fatClash("Skim milk", "Milk, cow, fluid, whole milk"))
        XCTAssertTrue(FoodReference.fatClash("Fat-free yoghurt", "Yoghurt, natural", fat100: 3.2))
    }

    func testFineMatchesStayFine() {
        XCTAssertFalse(FoodReference.fatClash("Greek yoghurt", "Yoghurt, natural, greek style (~10% fat)"))
        XCTAssertFalse(FoodReference.fatClash("Greek yoghurt, non-fat", "Yoghurt, natural, low fat (<0.5%)", fat100: 0.3))
        XCTAssertFalse(FoodReference.fatClash("Light soy sauce", "Sauce, soy, regular salt", fat100: 0.1))
        XCTAssertFalse(FoodReference.fatClash("Low fat milk", "Milk, cow, fluid, reduced fat (~1%)", fat100: 1.2))
    }

    func testSameFoodTurnsTheClashAway() {
        XCTAssertFalse(FoodReference.sameFood(asked: "Greek yoghurt, non-fat", got: "Yoghurt, natural, greek style (~10% fat)"))
    }
}
