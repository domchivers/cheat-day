import XCTest

/// Strong and steady (24 Nov, design/strong-steady-mockup.html), and Goal held mid-swipe: screens the Mac can't reach
/// without signing in, kept as screenshots to check by eye.
final class StrongSteadyUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Build a plan (25 Nov, design/plan-any-workout-mockup.html): the tiles, a card each, then the week.
    /// Strong and steady asks about weights at home, and leaves out the lifting questions.
    func testBuildAPlanStrongAndSteady() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-workoutplan"]
        app.launch()
        XCTAssertTrue(app.staticTexts["What's in your week?"].waitForExistence(timeout: 6))
        sleep(1)
        shot(app, "build-plan-tiles")
        app.buttons["Strong and steady"].tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Any weights at home?"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["How long have you been lifting?"].exists)
        let dumbbells = app.buttons["Light dumbbells"]
        XCTAssertTrue(dumbbells.waitForExistence(timeout: 3))
        dumbbells.tap()
        sleep(1)
        shot(app, "build-plan-steady")
        app.buttons["See my week"].tap()
        XCTAssertTrue(app.buttons["Start this plan"].waitForExistence(timeout: 3))
        sleep(1)
        shot(app, "build-plan-steady-week")
    }

    /// No weights at all: a run and yoga make a plan on their own, with rest days between.
    func testBuildAPlanWithNoWeights() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-workoutplan"]
        app.launch()
        XCTAssertTrue(app.staticTexts["What's in your week?"].waitForExistence(timeout: 6))
        app.buttons["Running"].tap()
        app.buttons["Yoga / Pilates"].tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 3), "the run's card")
        XCTAssertFalse(app.buttons["Set up weights"].exists)
        sleep(1)
        shot(app, "build-plan-run-yoga")
        app.buttons["Start running"].tap()
        XCTAssertTrue(app.staticTexts["Run 30 min without stopping"].waitForExistence(timeout: 3), "the 8 weeks")
        sleep(1)
        shot(app, "build-plan-start-running")
        app.buttons["See my week"].tap()
        let start = app.buttons["Start this plan"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(app.staticTexts["Rest"].exists)
        sleep(1)
        shot(app, "build-plan-run-yoga-week")
    }

    /// Start running's timer (25 Nov): before Start, then a few seconds into the warm-up walk.
    func testStartRunningTimer() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-runtimer"]
        app.launch()
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        sleep(1)
        shot(app, "run-timer-ready")
        start.tap()
        XCTAssertTrue(app.staticTexts["WARM-UP WALK"].waitForExistence(timeout: 4))
        sleep(3)
        shot(app, "run-timer-warmup")
        XCTAssertTrue(app.buttons["Pause"].exists)
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Carry on"].waitForExistence(timeout: 2))
    }

    /// A mapped run's page (25 Nov, design/run-route-mockup.html): the map, the numbers, each kilometre.
    func testAMappedRunsPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-runmap"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Each kilometre"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["average pace"].exists)
        sleep(3)   // map tiles
        shot(app, "run-map")
    }

    /// Workouts' three ways in (26 Nov, design/start-run-mockup.html): Weights, Run and Log one side by side, and with
    /// no plan, Get a workout plan right under them.
    func testWorkoutsThreeWaysIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-walk"]
        app.launch()
        XCTAssertTrue(app.buttons["Start a run"].waitForExistence(timeout: 6))
        // (the fixture has a session left going, so Weights reads as going back to it)
        XCTAssertTrue(app.buttons["Start a weights session"].exists || app.buttons["Back to your session"].exists)
        XCTAssertTrue(app.buttons["Log a walk, run or class"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Get a workout plan'")).firstMatch.exists, "under the three, with no plan")
        sleep(1)
        shot(app, "workouts-three-ways-in")
    }

    /// Run's ready screen: map, time, km, pace, Start run, and Start running's run offered; then a moment in.
    func testFreeRunReady() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-freerun"]
        app.launch()
        let start = app.buttons["Start run"]
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["Following Start running? Week 2, run 1 is in your plan"].exists)
        sleep(3)   // map tiles
        shot(app, "free-run-ready")
        start.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        sleep(2)
        shot(app, "free-run-running")
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
