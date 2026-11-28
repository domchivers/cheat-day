import XCTest
@testable import CheatDays

/// The paywall (28 Nov) must never stand in the way of tests, the demo or UI tests, and never locks anything
/// while the plans haven't loaded (no App Store Connect products yet: TestFlight stays open).
@MainActor
final class SubscriptionTests: XCTestCase {
    func testTestsAreNeverLocked() {
        XCTAssertTrue(Subscription.bypass, "unit tests run with XCTestConfigurationFilePath set")
        XCTAssertFalse(Subscription.shared.locked)
    }

    func testNoPlansNoLock() {
        let s = Subscription.shared
        XCTAssertTrue(s.products.isEmpty || s.loaded, "products only arrive with a load")
        if s.products.isEmpty { XCTAssertFalse(s.locked, "nothing to buy, nothing locked") }
    }

    func testPlanIDs() {
        XCTAssertEqual(Subscription.yearlyID, "com.cheatdays.app.yearly")
        XCTAssertEqual(Subscription.monthlyID, "com.cheatdays.app.monthly")
    }
}
