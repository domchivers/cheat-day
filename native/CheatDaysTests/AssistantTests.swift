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
        XCTAssertEqual(Assistant.schema["required"] as? [String], ["reply", "kind"])
        let text = String(data: try! JSONSerialization.data(withJSONObject: Assistant.schema), encoding: .utf8)!
        XCTAssertFalse(text.contains("nullable"), "Claude refuses a schema full of nulls as too large")
    }

    /// The owner's "110g cabbage, 170g cucumber": the AI's guesses (28 and 27 kcal, 6 g carbs each) put right from the food data.
    @MainActor
    func testFoodsAddedThroughAChangeAreChecked() async {
        let answer: JSON = ["kind": "edit", "reply": "Got it, adding cabbage and cucumber.", "edit": ["actions": [
            ["action": "add", "name": "Cabbage, raw", "grams": 110, "kcal": 28, "protein_g": 1.4, "carbs_g": 6.5, "fat_g": 0.1] as JSON,
            ["action": "add", "name": "Cucumber, raw", "grams": 170, "kcal": 27, "protein_g": 1.1, "carbs_g": 5.8, "fat_g": 0.2] as JSON,
            ["action": "remove", "target": "Toast", "name": "", "grams": 0, "kcal": 0] as JSON] as [Any]] as JSON]
        let out = Assistant.saneEdit(await Assistant.groundEdit(answer))
        let acts = list(dict(out["edit"])["actions"])
        XCTAssertEqual(num(acts[0]["kcal"]), 26, "white cabbage, 24 kcal per 100 g")
        XCTAssertEqual(num(acts[0]["carbs_g"]) ?? 0, 4.2, accuracy: 0.1)
        XCTAssertEqual(num(acts[1]["kcal"]), 19, "cucumber, 11 kcal per 100 g")
        XCTAssertEqual(str(acts[0]["src"]), "afcd")
        XCTAssertEqual(str(acts[2]["action"]), "remove", "a removal is left alone")
        XCTAssertFalse(str(out["reply"]).lowercased().contains("adding"), "nothing's on the list until it's tapped")
    }

    func testAnEstimateNeverSaysItsLogged() {
        let out = Assistant.saneEdit(["kind": "estimate", "reply": "Half a teaspoon is about 22 kcal. Logging it now."])
        XCTAssertTrue(str(out["reply"]).contains("tap Add"))
    }

    func testAnEstimateAddsWithItsServing() {
        let b = Assistant.basis(name: "Chicken katsu curry", kcal: 820, grams: 450, p: 38, c: 95, f: 30)
        XCTAssertEqual(num(b["kcalPerServing"]), 820)
        XCTAssertEqual(num(b["servingSize"]), 450)
        XCTAssertEqual(num(b["kcalPer100"]) ?? 0, 182.2, accuracy: 0.1)
    }
}
