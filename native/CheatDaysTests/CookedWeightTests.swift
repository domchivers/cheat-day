import XCTest
@testable import CheatDays

/// The finished pot's weight: meat loses water, rice and pasta gain it, oil and sauces stay.
final class CookedWeightTests: XCTestCase {
    func testABraiseLosesAboutAThird() {
        XCTAssertEqual(CookedWeight.factor("Beef chuck steak, cubed"), 0.62)
        XCTAssertEqual(CookedWeight.estimate([("Beef chuck roast", 1000)]), 620)
    }

    func testRiceGainsAndCookedRiceStays() {
        XCTAssertEqual(CookedWeight.factor("Basmati rice"), 2.6)
        XCTAssertEqual(CookedWeight.factor("White rice, cooked"), 1)
        XCTAssertEqual(CookedWeight.factor("Vegetable oil"), 1)
    }

    func testAPotAddsUp() {
        // 600 g chuck (372) + 2 onions 300 g (240) + 100 g curry roux (100) + 30 g oil (30) = 742
        XCTAssertEqual(CookedWeight.estimate([("Beef chuck", 600), ("Onion, sliced", 300), ("Japanese curry roux blocks", 100), ("Vegetable oil", 30)]), 740)
        XCTAssertNil(CookedWeight.estimate([("Salt", 0)]))
    }

    func testAPotMissingTheRiceIsFlagged() throws {
        // the owner's curry: 818 g chuck, 210 g carrots, 30 g roux, 750 g water and 450 g cooked rice listed,
        // but only the curry weighed (515 g)
        let est = try XCTUnwrap(CookedWeight.estimate([("Beef chuck steak", 818), ("Carrots", 210), ("S&B Golden Curry mix", 30),
                                                      ("Water", 750), ("Rice, cooked", 450)]))
        XCTAssertTrue(CookedWeight.looksOff(weighed: 515, estimate: est))
        XCTAssertFalse(CookedWeight.looksOff(weighed: est * 0.9, estimate: est))
    }
}
