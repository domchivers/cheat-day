import XCTest
@testable import CheatDays

/// Group chats (25 Nov, design/group-chats-mockup.html).
@MainActor
final class GroupChatTests: XCTestCase {
    func testAGroupsChatId() {
        XCTAssertEqual(Messages.groupId("g:1234"), "1234")
        XCTAssertNil(Messages.groupId("5678"), "a friend's id isn't a group")
    }

    func testPreviewSaysWhoInAGroup() {
        let me = "me-id"
        let mine: JSON = ["from_user": me, "group_id": "g1", "kind": "text", "text": "legs at 6?"]
        XCTAssertEqual(Messages.preview(mine, me: me), "You: legs at 6?")
        let fresh: JSON = ["group_id": "g1", "text": "New group"]
        XCTAssertEqual(Messages.preview(fresh, me: me), "New group", "a group with nothing said yet")
        let oneToOne: JSON = ["from_user": "friend", "to_user": me, "kind": "text", "text": "Yooo"]
        XCTAssertEqual(Messages.preview(oneToOne, me: me), "Yooo", "one-to-one stays as it was")
    }

    func testInviteLink() {
        XCTAssertEqual(Messages.inviteLink(["invite": "ab12cd34ef"]), "cheatdays://group/ab12cd34ef")
    }
}
