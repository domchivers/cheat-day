import UIKit
import XCTest
@testable import CheatDays

/// Stage B's overlays: recipe and workout mode laid one a clip, a caption's lit word, and drafts keeping them.
final class EditOverlaysTests: XCTestCase {
    private func clip(_ seconds: Double) -> Clip { Clip(source: URL(fileURLWithPath: "/tmp/x.mov"), length: 20, start: 0, end: seconds) }

    /// 22 Nov, "Gif not working??": a GIF is never drawn by ImageRenderer (which makes it a yellow box).
    @MainActor func testAGIFIsItsFramesNeverARenderedBox() {
        let url = "https://media.giphy.com/media/test-only/200w.gif"
        defer { EditOverlays.gifs[url] = nil }
        var t = EditText(kind: "card", text: "GIF", x: 0.5, y: 0.4, from: 1, to: 2)
        t.card = "{\"type\":\"gif\",\"url\":\"\(url)\",\"w\":200,\"h\":100}"
        XCTAssertEqual(EditOverlays.gifURLs([t]), [url])
        let size = CGSize(width: 1080, height: 1920)

        EditOverlays.gifs[url] = nil
        XCTAssertTrue(EditOverlays.pieces([t], frame: size).isEmpty, "none loaded: nothing drawn")

        let one = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
        EditOverlays.gifs[url] = one
        let still = EditOverlays.pieces([t], frame: size)
        XCTAssertEqual(still.count, 1, "one frame: held")
        XCTAssertEqual(still.first?.to ?? 0, 2, accuracy: 0.001)

        EditOverlays.gifs[url] = UIImage.animatedImage(with: [one, one], duration: 0.5)
        XCTAssertEqual(EditOverlays.pieces([t], frame: size).count, 4, "two frames a quarter of a second each, round again")
    }

    func testRecipeModeStepsOneAClipMacrosOnTheLast() {
        let clips = [clip(3), clip(4), clip(5)]
        let meal: JSON = ["kind": "meal", "name": "Protein pizza", "kcal": 640, "macros": ["p": 52, "c": 70, "f": 16] as JSON,
                          "payload": ["steps": ["Make the dough", "Add the sauce", "Bake it"]] as JSON]
        let made = EditOverlays.recipe(meal, clips: clips)
        // two steps (the last clip is the macros), then the macros
        XCTAssertEqual(made.map(\.kind), ["step", "step", "macros"])
        XCTAssertEqual(made[0].text, "1. Make the dough")
        XCTAssertEqual(made[1].from, 3, accuracy: 0.001); XCTAssertEqual(made[1].to, 7, accuracy: 0.001)
        XCTAssertEqual(made[2].text, "640 kcal"); XCTAssertEqual(made[2].detail, "P 52 g · C 70 g · F 16 g")
        XCTAssertEqual(made[2].from, 7, accuracy: 0.001)
    }

    func testRecipeStepsWrittenAsObjects() {
        let meal: JSON = ["kind": "meal", "kcal": 300, "payload": ["steps": [["text": "Chop"] as JSON, ["text": "Fry"] as JSON]] as JSON]
        let made = EditOverlays.recipe(meal, clips: [clip(2), clip(2), clip(2)])
        XCTAssertEqual(made.filter { $0.kind == "step" }.map(\.text), ["1. Chop", "2. Fry"])
    }

    func testWorkoutModeAnExerciseAClip() {
        let w: JSON = ["kind": "workout", "payload": ["lifts": [["exercise": "Bench press", "sets": 3, "reps": 8, "kg": 60] as JSON,
                                                                ["exercise": "Push ups", "sets": 2, "reps": 15, "kg": 0] as JSON]] as JSON]
        let made = EditOverlays.workout(w, clips: [clip(4), clip(4), clip(4)])
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].text, "Bench press"); XCTAssertEqual(made[0].detail, "3 × 8 · 60 kg")
        XCTAssertEqual(made[1].detail, "2 × 15")
        XCTAssertEqual(made[1].from, 4, accuracy: 0.001)
    }

    func testCaptionLightsTheWordBeingSaid() {
        let c = EditText(kind: "caption", text: "this is pizza", from: 1, to: 3,
                         words: [.init(text: "this", at: 1), .init(text: "is", at: 1.4), .init(text: "pizza", at: 1.9)])
        XCTAssertEqual(c.lit(at: 1.0), 0)
        XCTAssertEqual(c.lit(at: 1.5), 1)
        XCTAssertEqual(c.lit(at: 2.5), 2)
    }

    func testOverlaysRoundTrip() throws {
        let t = EditText(kind: "calories", text: "Pizza", detail: "52 g protein", x: 0.4, y: 0.3, from: 2, to: 6, number: 640)
        let back = try JSONDecoder().decode(EditText.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }
}
