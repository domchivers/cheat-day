import XCTest

/// Strong and steady (24 Nov, design/strong-steady-mockup.html), and Goal held mid-swipe: screens the Mac can't reach
/// without signing in, kept as screenshots to check by eye.
final class StrongSteadyUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Build a plan: Strong and steady asks about weights at home instead of where, and leaves out the lifting questions.
    func testBuildAPlanStrongAndSteady() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-workoutplan"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Strong and steady'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 6), "the Strong and steady choice")
        card.tap()
        let weights = app.staticTexts["Any weights at home?"]
        XCTAssertTrue(weights.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["How long have you been lifting?"].exists)
        XCTAssertFalse(app.staticTexts["Where?"].exists)
        sleep(1)
        shot(app, "build-plan-steady")
        let dumbbells = app.buttons["Light dumbbells"]
        XCTAssertTrue(dumbbells.waitForExistence(timeout: 3))
        dumbbells.tap()
        app.swipeUp()
        sleep(1)
        shot(app, "build-plan-steady-dumbbells")
    }

    /// Sign-up's How you train for someone of 67: Strong and steady is marked, and picked to start with.
    func testHowYouTrainAt67() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-howyoutrain"]
        app.launch()
        XCTAssertTrue(app.staticTexts["How you train"].waitForExistence(timeout: 6))
        // (inside the choice's button, so part of its label)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Good at 60+'")).firstMatch.waitForExistence(timeout: 3), "the badge")
        XCTAssertTrue(app.staticTexts["Any weights at home?"].waitForExistence(timeout: 3), "picked to start with")
        sleep(1)
        shot(app, "how-you-train-67")
    }

    /// Goal held 40 points into a swipe back to Plan: its card should keep the 16-point sides it has at rest (24 Nov:
    /// it came out 8 points wider and the small print under Body fat re-wrapped).
    func testGoalHeldMidSwipe() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-plantabs-mid"]
        app.launch()
        let open = app.buttons["Open your plan"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.staticTexts["Your goal"].waitForExistence(timeout: 4))
        sleep(1)
        shot(app, "your-goal-mid-swipe")
    }
}
