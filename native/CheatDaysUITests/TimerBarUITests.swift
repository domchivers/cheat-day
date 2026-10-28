import XCTest

/// The workout timer bar must stay at the foot of the screen. Locking the phone (or leaving the app) with a set's
/// keyboard up once left the bar stranded mid-screen with the list squashed above it. Types into a box low down,
/// leaves the app with the keyboard up, comes back, and checks the bar and the list are where they started.
/// Needs the simulator's software keyboard (I/O > Keyboard > Connect Hardware Keyboard off).
final class TimerBarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-uitest-session"]
        app.launch()
    }

    private var bar: XCUIElement { app.descendants(matching: .any).matching(identifier: "timerBar").firstMatch }
    private var list: XCUIElement { app.descendants(matching: .any).matching(identifier: "sessionList").firstMatch }
    private var keyboard: XCUIElement { app.keyboards.firstMatch }

    func testTimerBarStaysAtTheFootAfterLeavingWithTheKeyboardUp() {
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no timer bar")
        let barBottom = bar.frame.maxY, listBottom = list.frame.maxY
        print("timerBar: start bar \(bar.frame), list \(list.frame)")

        for round in 1...5 {
            // a reps box near the bottom of the list, so it has to scroll clear of the keyboard
            let boxes = app.textFields.matching(identifier: "box-reps")
            let box = boxes.element(boundBy: min(round + 5, boxes.count - 1))
            if !box.isHittable { app.swipeUp() }
            box.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 4), "round \(round): no keyboard came up")
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertLessThanOrEqual(box.frame.maxY, keyboard.frame.minY + 2, "round \(round): box \(box.frame.maxY) is under the keyboard \(keyboard.frame.minY)")

            // leave with the keyboard up (the lock button does the same to the app), then come back
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: round % 2 == 0 ? 0.5 : 2)
            app.activate()
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "round \(round): no timer bar after coming back")
            Thread.sleep(forTimeInterval: 1)
            print("timerBar: round \(round) bar \(bar.frame), list \(list.frame), keyboard up \(keyboard.exists)")

            if keyboard.exists {
                // if iOS brings the keyboard back, the bar may hide behind it, but the list must not be squashed
                XCTAssertEqual(list.frame.maxY, listBottom, accuracy: 2, "round \(round): list squashed with the keyboard back up")
                app.buttons["Done"].firstMatch.tap()
                _ = keyboard.waitForNonExistence(timeout: 3)
                Thread.sleep(forTimeInterval: 0.6)
            }
            XCTAssertEqual(bar.frame.maxY, barBottom, accuracy: 2, "round \(round): timer bar at \(bar.frame.maxY), it started at \(barBottom)")
            XCTAssertEqual(list.frame.maxY, listBottom, accuracy: 2, "round \(round): list ends at \(list.frame.maxY), it started at \(listBottom)")
        }
    }
}
