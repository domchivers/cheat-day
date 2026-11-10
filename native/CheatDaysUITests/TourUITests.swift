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
            guard steps < 10 else { XCTFail("the tour should end"); break }   // stuck: stop, don't loop for ever
        }
        XCTAssertGreaterThanOrEqual(steps, 4, "at least the Today steps and the tabs show")
        XCTAssertFalse(app.buttons["Next"].waitForExistence(timeout: 1))
    }

    /// The planner as a chat: what the meal should come to and an example of how to ask (25 g protein with no goal),
    /// the cooking time as one button, the scanned food as a chip, and ＋ for a barcode or a label.
    func testPlanChat() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-plan"]
        app.launch()
        let intro = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "What do you fancy?")).firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Fresh Farm Chicken breast fillets")).firstMatch.exists, "the scanned food as a chip")
        XCTAssertTrue(intro.label.contains("25 g protein"), "the meal's own numbers, 25 g with no goal")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Something high protein")).firstMatch.exists, "an example of how to ask")
        XCTAssertTrue(app.buttons["Cooking: Quick, 15 min"].exists, "how much cooking, as one button")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "plan-chat"; a.lifetime = .keepAlways; add(a)

        // ＋ offers the two ways to add a food you have
        app.buttons["Add a food you have"].tap()
        XCTAssertTrue(app.buttons["Scan a barcode"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Photo of a label"].exists)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "plan-add"; b.lifetime = .keepAlways; add(b)
        intro.tap()   // away from the menu: closes it
    }

    func testRecipeSwap() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-recipe"]
        app.launch()
        let menu = app.buttons["Change Chicken thigh"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "recipe-before"; before.lifetime = .keepAlways; add(before)
        menu.tap()
        app.buttons["Swap for my own"].tap()
        let pick = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fresh Farm Chicken breast fillets")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 3))
        pick.tap()
        XCTAssertTrue(app.staticTexts["YOURS"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["434"].exists, "total should be 434 kcal: 150 g at 106 from the label (159) + 230 + 37 + 8")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "recipe-swapped"; after.lifetime = .keepAlways; add(after)

        // remove the soy sauce from its menu: 434 - 8 = 426, and it can be put back
        app.buttons["Change Soy sauce"].tap()
        app.buttons["Remove from recipe"].tap()
        XCTAssertTrue(app.staticTexts["426"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Put back"].exists)
        let removed = XCTAttachment(screenshot: app.screenshot()); removed.name = "recipe-removed"; removed.lifetime = .keepAlways; add(removed)
        app.buttons["Put back"].tap()
        XCTAssertTrue(app.staticTexts["434"].waitForExistence(timeout: 3))

        // down to the cooked weight card, after the method: the one way to log, by the grams on your plate
        let addPlate = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Add 4")).firstMatch
        for _ in 0..<4 where !addPlate.isHittable { app.swipeUp() }
        XCTAssertTrue(addPlate.exists)
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Log a portion")).firstMatch.exists)
        let cooked = XCTAttachment(screenshot: app.screenshot()); cooked.name = "recipe-cooked"; cooked.lifetime = .keepAlways; add(cooked)
    }

    func testScaleSetupIntro() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-scale"]
        app.launch()
        XCTAssertTrue(app.buttons["Connect Apple Health"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Not now"].exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "scale-setup"; a.lifetime = .keepAlways; add(a)
    }

    func testWeighInSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-weigh"]
        app.launch()
        XCTAssertTrue(app.buttons["Type it"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Screenshot"].exists)
        XCTAssertTrue(app.buttons["Apple Health"].exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "weigh-in"; a.lifetime = .keepAlways; add(a)
        // a number keyboard has no return key: the Done bar above it puts it away
        app.textFields.firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 2), "Done above the keyboard")
        let k = XCTAttachment(screenshot: app.screenshot()); k.name = "keyboard-done"; k.lifetime = .keepAlways; add(k)
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "Done puts the keyboard away")
        app.buttons["Screenshot"].tap()
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "weigh-in-screenshot"; b.lifetime = .keepAlways; add(b)
    }

    func testBodyChart() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-body"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Body"].waitForExistence(timeout: 5))
        sleep(1)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "body-chart"; a.lifetime = .keepAlways; add(a)
        app.swipeUp()
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "body-goals"; b.lifetime = .keepAlways; add(b)
    }

    func testWalkingOnWorkouts() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-walk"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Walking"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 workouts · 0 kcal"].exists, "walking isn't counted as a workout")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "+ walking")).firstMatch.exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "workouts-walking"; a.lifetime = .keepAlways; add(a)
    }

    func testRankBadges() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-ranks"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Legend"].waitForExistence(timeout: 5))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "rank-badges"; a.lifetime = .keepAlways; add(a)
        app.buttons["Open ranks"].tap()
        XCTAssertTrue(app.staticTexts["The ladder"].waitForExistence(timeout: 3) || app.staticTexts["THE LADDER"].exists)
        sleep(1)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "ranks-screen"; b.lifetime = .keepAlways; add(b)
    }

    /// Goals and badges: the week as tiles, the streak and rank, and all the badges as coins.
    func testGoalsAndBadges() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-ranks"]
        app.launch()
        XCTAssertTrue(app.buttons["Open goals"].waitForExistence(timeout: 5))
        app.buttons["Open goals"].tap()
        XCTAssertTrue(app.buttons["Change targets"].waitForExistence(timeout: 4), "targets behind one button")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "goals-screen"; a.lifetime = .keepAlways; add(a)
        app.buttons["Change targets"].tap()
        XCTAssertTrue(app.staticTexts["Weekly targets"].waitForExistence(timeout: 3))
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "goals-targets"; b.lifetime = .keepAlways; add(b)
        app.buttons["Done"].tap()
        let all = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "All badges")).firstMatch
        if !all.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(all.waitForExistence(timeout: 3), "all badges a tap away")
        all.tap()
        XCTAssertTrue(app.navigationBars["Badges"].waitForExistence(timeout: 3))
        let c = XCTAttachment(screenshot: app.screenshot()); c.name = "all-badges"; c.lifetime = .keepAlways; add(c)
    }

    /// The sticker tray as it opens, and every sticker on a story: screenshots to check nothing's squeezed or broken.
    func testStickers() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-stickers"]
        app.launch()
        XCTAssertTrue(app.buttons["Yours"].waitForExistence(timeout: 5), "the tray opens on Yours")
        sleep(1)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "stickers-tray"; a.lifetime = .keepAlways; add(a)
        app.buttons["3D"].tap(); sleep(1)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "stickers-3d"; b.lifetime = .keepAlways; add(b)
        app.swipeDown(velocity: .fast); sleep(1)
        let c = XCTAttachment(screenshot: app.screenshot()); c.name = "stickers-story"; c.lifetime = .keepAlways; add(c)
    }

    /// The real editor: a sticker from Yours and one from 3D go on, one is dragged and pinched, and the food sticker opens its sheet.
    func testEditorStickers() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-editor"]
        app.launch()
        let stickers = app.buttons["Stickers"]
        XCTAssertTrue(stickers.waitForExistence(timeout: 5))
        stickers.tap()
        let left = app.buttons["tile-left"]
        XCTAssertTrue(left.waitForExistence(timeout: 3), "the tray's calories-left tile")
        left.tap()
        let placed = app.descendants(matching: .any)["placed-left"]
        XCTAssertTrue(placed.waitForExistence(timeout: 3), "tapping a tile puts it on the story")
        sleep(1)
        let before = placed.frame
        let start = placed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)))
        sleep(1)
        XCTAssertLessThan(placed.frame.midY, before.midY - 80, "it moves with the finger")
        let moved = placed.frame
        placed.pinch(withScale: 1.8, velocity: 1.5)
        sleep(1)
        XCTAssertGreaterThan(placed.frame.width, moved.width * 1.2, "a pinch makes it bigger")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "editor-moved"; a.lifetime = .keepAlways; add(a)

        stickers.tap()
        XCTAssertTrue(app.buttons["3D"].waitForExistence(timeout: 3))
        app.buttons["3D"].tap()
        let three = app.buttons["tile-3d"].firstMatch
        XCTAssertTrue(three.waitForExistence(timeout: 3))
        three.tap()
        XCTAssertTrue(app.descendants(matching: .any)["placed-sticker3d"].waitForExistence(timeout: 3), "a 3D sticker goes on too")

        stickers.tap()
        XCTAssertTrue(app.buttons["Yours"].waitForExistence(timeout: 3))
        app.buttons["Yours"].tap()
        let poll = app.buttons["tile-food"]
        XCTAssertTrue(poll.waitForExistence(timeout: 3))
        poll.tap()
        XCTAssertTrue(app.navigationBars["Food sticker"].waitForExistence(timeout: 4), "the food sticker's own sheet opens once the tray has gone")
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "editor-food"; b.lifetime = .keepAlways; add(b)
    }

    /// A profile's tag and label line, and the sheet of all the tags.
    func testProfileTags() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-honors"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Founder of Cheat Days"].waitForExistence(timeout: 5), "the label under the name")
        sleep(1)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "profile-tags"; a.lifetime = .keepAlways; add(a)
        app.buttons["Founder"].firstMatch.tap(); sleep(1)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "profile-tags-sheet"; b.lifetime = .keepAlways; add(b)
    }

    func testMealCheck() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-mealcheck"]
        app.launch()
        XCTAssertTrue(app.staticTexts["About your lunch"].waitForExistence(timeout: 5), "toast alone for lunch gets a check")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "g protein")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["TO DO BETTER"].exists, "only 7 g protein, and the day behind")
        XCTAssertTrue(app.textFields["Ask about it, or plan dinner"].exists, "the chat box, even after a meal")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "meal-check"; a.lifetime = .keepAlways; add(a)
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

    /// The takeaway card the owner checks: just one restaurant with a shake offered, a combo with ✕ and ⇄, and the estimate card with icons.
    func testTakeawayCards() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-takeaway"]
        app.launch()
        let off = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Take off")).firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 8), "the ✕ on a line")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Swap")).firstMatch.exists, "the ⇄ on the dish")
        XCTAssertFalse(app.staticTexts["LOW PROTEIN AT SEOUL CHICKEN PRAHRAN"].exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "takeaway-lunch"; a.lifetime = .keepAlways; add(a)
        app.swipeUp()
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "takeaway-dinner"; b.lifetime = .keepAlways; add(b)
        let drop = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Take off")).allElementsBoundByIndex.last { $0.isHittable }
        drop?.tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Put back")).firstMatch.waitForExistence(timeout: 3))
        let c = XCTAttachment(screenshot: app.screenshot()); c.name = "takeaway-dropped"; c.lifetime = .keepAlways; add(c)
        app.swipeUp()
        let d = XCTAttachment(screenshot: app.screenshot()); d.name = "estimate-icons"; d.lifetime = .keepAlways; add(d)
        // places found in South Yarra, each a button that plans it (not tapped: that searches the web)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Plan Olive Street Greek"].waitForExistence(timeout: 3), "a found place to tap")
        let e = XCTAttachment(screenshot: app.screenshot()); e.name = "takeaway-places"; e.lifetime = .keepAlways; add(e)
    }
}
