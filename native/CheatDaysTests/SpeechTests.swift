import XCTest
@testable import CheatDays

/// Speaking into the chat (21 Nov): what was said is kept when the recognizer begins again from nothing after a pause,
/// and the same words heard better aren't counted twice.
final class SpeechTests: XCTestCase {
    @MainActor func testAFreshStartIsntTheSameWordsHeardBetter() {
        // after a pause, the words start again from nothing: a fresh start
        XCTAssertTrue(Speech.beganAgain("and no limes", after: "have 449 grams of chicken breast to boil"))
        // the same words, one changed or more of them: not
        XCTAssertFalse(Speech.beganAgain("have 449 grams of chicken breasts to boil", after: "have 449 grams of chicken breast to boil"))
        XCTAssertFalse(Speech.beganAgain("Have 449 g", after: "have 449 grams of chicken"))
        // too little before to tell
        XCTAssertFalse(Speech.beganAgain("no", after: "hi there"))
    }
}
