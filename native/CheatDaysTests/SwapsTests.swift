import XCTest
@testable import CheatDays

/// Healthier picks: the common treats get a lighter one from the food list, the lighter ones themselves don't.
final class SwapsTests: XCTestCase {
    func testPicks() {
        XCTAssertEqual(Swaps.pick(for: "Walkers crisps", kcal: 250)?.name, "Popcorn, salted")
        XCTAssertEqual(Swaps.pick(for: "Coca-Cola", kcal: 139)?.name, "Coke Zero / Diet Coke")
        XCTAssertNil(Swaps.pick(for: "Coke Zero", kcal: 1), "already the light one")
        XCTAssertNil(Swaps.pick(for: "Light beer", kcal: 150), "already the light one")
        XCTAssertNil(Swaps.pick(for: "Chicken breast, cooked, skinless", kcal: 200), "nothing to swap")
        if let p = Swaps.pick(for: "Pint of lager", kcal: 250) { XCTAssertGreaterThanOrEqual(p.saves, 40) }
    }
}
