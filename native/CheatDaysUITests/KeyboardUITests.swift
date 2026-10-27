import XCTest

/// The assistant's chat box must sit above the keyboard every time, not just most times. Opens the assistant as a
/// sheet over and over, brings the keyboard up in the different ways people do, and checks where the box ends up.
/// Needs the simulator's software keyboard (I/O > Keyboard > Connect Hardware Keyboard off).
final class KeyboardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-uitest-assistant"]
        app.launch()
    }

    private var box: XCUIElement { app.descendants(matching: .any).matching(identifier: "chatBox").firstMatch }
    private var keyboard: XCUIElement { app.keyboards.firstMatch }

    private func checkAboveKeyboard(_ what: String) {
        XCTAssertTrue(keyboard.waitForExistence(timeout: 4), "\(what): no keyboard came up")
        Thread.sleep(forTimeInterval: 0.8)   // let the lift animation finish
        let b = box.frame, k = keyboard.frame
        XCTAssertLessThanOrEqual(b.maxY, k.minY + 2, "\(what): chat box bottom \(b.maxY) is under the keyboard top \(k.minY)")
        XCTAssertGreaterThan(b.minY, k.minY - 260, "\(what): chat box \(b.minY) floating far above the keyboard \(k.minY)")
    }

    private func keyboardAway() {
        // a tap on the chat (the welcome text at the top, clear of the buttons) puts the keyboard away
        app.scrollViews["chat"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3), "a tap on the chat didn't put the keyboard away")
    }

    private func checkAtBottom(_ what: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(box.frame.maxY, screen.maxY - 120, "\(what): chat box left up at \(box.frame.maxY) after the keyboard went")
    }

    func testChatBoxRidesTheKeyboard() {
        for round in 1...10 {
            app.buttons["openAssistant"].tap()
            XCTAssertTrue(box.waitForExistence(timeout: 5), "round \(round): no chat box")
            if round % 2 == 0 { Thread.sleep(forTimeInterval: 0.1) }   // tap straight away while the sheet is still landing
            else { Thread.sleep(forTimeInterval: 1) }

            box.tap()
            checkAboveKeyboard("round \(round), first tap")
            keyboardAway()
            checkAtBottom("round \(round), after first tap")

            // tap the right-hand end of the box (the empty part, not the text)
            box.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            checkAboveKeyboard("round \(round), tap on the empty end")

            // a long question wraps and grows the box (no Return: that would send it)
            if round == 1 || round == 6 { box.typeText("what could I have for dinner tonight that fits what is left and has plenty of protein in it ") }
            checkAboveKeyboard("round \(round), three lines")
            keyboardAway()
            checkAtBottom("round \(round), after typing")

            box.tap()
            checkAboveKeyboard("round \(round), tap again")
            app.buttons["Close"].tap()
            _ = box.waitForNonExistence(timeout: 3)
        }
    }
}
