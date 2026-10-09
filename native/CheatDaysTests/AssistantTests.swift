import XCTest
@testable import CheatDays

/// The assistant's chats are kept like the website's (no photos, newest first, deletions stick), and its schema asks for every answer shape.
final class AssistantTests: XCTestCase {
    func testChatsKeepNoPhotosAndDeletionsStick() {
        var t = Assistant.Turn(me: true, text: "What's this?")
        t.images = [UIImage()]
        let rec = Assistant.record(id: "c1", turns: [t, Assistant.Turn(me: false, text: "A flat white", result: ["kind": "answer"])])
        XCTAssertEqual(str(list(rec["turns"])[0]["text"]), "What's this? (1 photo)")
        XCTAssertEqual(str(rec["title"]), "What's this?")
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON]
        Assistant.applyChatOp(["type": "chat", "chat": rec], to: &d)
        XCTAssertEqual(list(d["chats"]).count, 1)
        Assistant.applyChatOp(["type": "deleteChat", "id": "c1", "at": 1], to: &d)
        Assistant.applyChatOp(["type": "chat", "chat": rec], to: &d)   // a late save of the deleted chat
        XCTAssertTrue(list(d["chats"]).isEmpty)
    }

    func testSchemaCoversEveryKind() {
        let props = dict(Assistant.schema["properties"])
        for k in ["reply", "kind", "estimate", "plan", "edit", "recipe", "lighter"] { XCTAssertNotNil(props[k], k) }
        XCTAssertEqual(dict(props["kind"])["enum"] as? [String], ["answer", "estimate", "plan", "edit", "recipe", "lighter"])
    }

    func testAnEstimateAddsWithItsServing() {
        let b = Assistant.basis(name: "Chicken katsu curry", kcal: 820, grams: 450, p: 38, c: 95, f: 30)
        XCTAssertEqual(num(b["kcalPerServing"]), 820)
        XCTAssertEqual(num(b["servingSize"]), 450)
        XCTAssertEqual(num(b["kcalPer100"]) ?? 0, 182.2, accuracy: 0.1)
    }
}
