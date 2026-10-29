import XCTest

/// Steps through the show-me tour, keeping a screenshot of each step to check the outlines sit on what they circle.
final class TourUITests: XCTestCase {
    func testTourStepsThrough() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-tour"]
        app.launch()
        var steps = 0
        while app.buttons["Next"].waitForExistence(timeout: 5) || app.buttons["Done"].exists {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "tour-step-\(steps + 1)"
            shot.lifetime = .keepAlways
            add(shot)
            steps += 1
            if app.buttons["Done"].exists { app.buttons["Done"].tap(); break }
            app.buttons["Next"].tap()
            XCTAssertLessThan(steps, 10, "the tour should end")
        }
        XCTAssertGreaterThanOrEqual(steps, 4, "at least the Today steps and the tabs show")
        XCTAssertFalse(app.buttons["Next"].waitForExistence(timeout: 1))
    }

    func testPlanCupboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-plan"]
        app.launch()
        XCTAssertTrue(app.buttons["Scan a barcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Photo of a label"].exists)
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "Tesco Chicken breast fillets")).firstMatch.exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "plan-cupboard"; a.lifetime = .keepAlways; add(a)
    }

    func testRecipeSwap() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-recipe"]
        app.launch()
        let swap = app.buttons["Swap Chicken thigh for your own"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "recipe-before"; before.lifetime = .keepAlways; add(before)
        swap.tap()
        let pick = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Tesco Chicken breast fillets")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 3))
        pick.tap()
        XCTAssertTrue(app.staticTexts["YOUR LABEL"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["434"].exists, "total should be 434 kcal: 150 g at 106 from the label (159) + 230 + 37 + 8")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "recipe-swapped"; after.lifetime = .keepAlways; add(after)
    }

    func testScaleSetupIntro() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-scale"]
        app.launch()
        XCTAssertTrue(app.buttons["Connect Apple Health"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Not now"].exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "scale-setup"; a.lifetime = .keepAlways; add(a)
    }

    func testSignInScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-signin"]
        app.launch()
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 5))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "signin"; a.lifetime = .keepAlways; add(a)
        app.buttons["New account"].tap()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 2))
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "signin-new"; b.lifetime = .keepAlways; add(b)

        // a new password: the 8-character line shows only while it's too short
        let hint = app.staticTexts["At least 8 characters"]
        XCTAssertFalse(hint.exists)
        app.textFields["Email"].tap(); app.textFields["Email"].typeText("test@example.com")
        let pw = app.secureTextFields["Password"]
        pw.tap(); pw.typeText("abc")
        XCTAssertTrue(hint.waitForExistence(timeout: 2))
        let c = XCTAttachment(screenshot: app.screenshot()); c.name = "signin-short"; c.lifetime = .keepAlways; add(c)
        pw.typeText("defgh")
        XCTAssertFalse(hint.waitForExistence(timeout: 1))
    }
}
