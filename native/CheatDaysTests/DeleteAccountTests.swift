import XCTest
@testable import CheatDays

/// Deleting the account asks for its password first (27 Nov): a wrong one never reaches the delete, a right one does.
/// The network is stood in for, so nothing here touches a real account.
@MainActor
final class DeleteAccountTests: XCTestCase {
    func testWrongPasswordDeletesNothing() async {
        var deleted = false
        let said = await Accounts.passwordFirst("guess", check: { _ in false }, then: { _ in deleted = true; return nil })
        XCTAssertFalse(deleted)
        XCTAssertEqual(said, Accounts.wrongPassword)
    }

    func testRightPasswordDeletes() async {
        var sent: String?
        let said = await Accounts.passwordFirst("right one", check: { $0 == "right one" }, then: { sent = $0; return nil })
        XCTAssertEqual(sent, "right one", "the server gets the password too, to check again")
        XCTAssertNil(said)
    }

    func testNoPasswordOrNoConnectionDeletesNothing() async {
        var deleted = false
        let empty = await Accounts.passwordFirst("", check: { _ in true }, then: { _ in deleted = true; return nil })
        let offline = await Accounts.passwordFirst("pw", check: { _ in nil }, then: { _ in deleted = true; return nil })
        XCTAssertFalse(deleted)
        XCTAssertNotNil(empty); XCTAssertNotNil(offline)
    }

    /// 1.4.75: the server marks the account for 30 days; the app says the date and that signing in keeps it.
    func testPendingSaysTheDate() {
        let d = #"{"pending":true,"delete_after":"2026-12-27T09:30:00.123+00:00"}"#.data(using: .utf8)!
        let note = Accounts.deletedNote(d)
        XCTAssertTrue(note.contains("27 December"), note)
        XCTAssertTrue(note.contains("Sign in before then"), note)
        XCTAssertNotNil(Accounts.isoDate("2026-12-27T09:30:00+00:00"), "without fractional seconds too")
        XCTAssertEqual(Accounts.deletedNote(#"{"deleted":true}"#.data(using: .utf8)!), "Account deleted.", "erased at once, or the older function")
    }

    func testSigningInCancelsAWaitingDeletion() async {
        let back = await Accounts.welcomeBack { true }
        XCTAssertEqual(back, Accounts.welcomeBackNote)
        let nothing = await Accounts.welcomeBack { false }
        XCTAssertNil(nothing, "no toast when nothing was waiting")
        let offline = await Accounts.welcomeBack { nil }
        XCTAssertNil(offline)
    }

    func testServerSayingNoIsShown() async {
        let said = await Accounts.passwordFirst("pw", check: { _ in true }, then: { _ in Accounts.wrongPassword })
        XCTAssertEqual(said, Accounts.wrongPassword)
    }
}
