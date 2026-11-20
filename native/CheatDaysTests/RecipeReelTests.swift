import XCTest
@testable import CheatDays

/// A saved recipe laid over the clips (21 Nov, design/editor-recipe-mockup.html): its card, ingredients, a step a clip
/// (or spread, or moved), and a portion's numbers on the last clip.
final class RecipeReelTests: XCTestCase {
    private func clip(_ seconds: Double) -> Clip { Clip(source: URL(fileURLWithPath: "/tmp/x.mov"), length: 20, start: 0, end: seconds) }
    private let meal: JSON = ["kind": "meal", "name": "Chicken tinga tacos", "kcal": 520, "macros": ["p": 41, "c": 48, "f": 17],
                              "payload": ["items": [["name": "red onion", "grams": 150, "unit": "g"], ["name": "chicken thigh", "grams": 500]],
                                          "steps": [["text": "Fry the onion"], ["text": "Simmer the chicken"], ["text": "Shred it"]]]]

    func testEveryPartWhereItGoes() {
        let clips = [clip(3), clip(3), clip(3), clip(3)]
        let starts = ClipJoin.starts(clips)
        let out = EditOverlays.reel(meal, clips: clips, plan: .init())
        XCTAssert(out.allSatisfy { $0.part == "recipe" })
        let card = out.first { $0.kind == "card" }
        XCTAssertEqual(card?.from, 0); XCTAssertEqual(str(card?.cardJSON?["type"]), "recipe"); XCTAssertEqual(card?.cardJSON?["steps"] as? Int, 3)
        let ing = out.first { $0.kind == "ingredients" }
        XCTAssertEqual(ing?.text, "150 g red onion\n500 g chicken thigh"); XCTAssertEqual(ing?.from ?? -1, card?.to ?? -2, accuracy: 0.001)
        let steps = out.filter { $0.kind == "step" }
        XCTAssertEqual(steps.map(\.detail), ["1/3", "2/3", "3/3"])
        for (i, s) in steps.enumerated() { XCTAssertEqual(s.from, starts[i], accuracy: 0.001, "step \(i + 1) on clip \(i + 1)") }
        let end = out.first { $0.kind == "calories" }
        XCTAssertEqual(end?.number, 520); XCTAssertEqual(end?.from ?? -1, starts[3], accuracy: 0.001)
        XCTAssertEqual(end?.detail, "P 41 g · C 48 g · F 17 g")
    }

    func testMovedSpreadShortenedAndOff() {
        let clips = [clip(3), clip(3), clip(3), clip(3)]
        let starts = ClipJoin.starts(clips)
        var plan = EditOverlays.RecipePlan()
        plan.clipOf[0] = 2; plan.words[1] = "Simmer"
        var out = EditOverlays.reel(meal, clips: clips, plan: plan)
        let steps = out.filter { $0.kind == "step" }
        XCTAssertEqual(steps[0].from, starts[2], accuracy: 0.001); XCTAssertEqual(steps[1].text, "Simmer")
        // more steps than clips before the end: spread evenly over them
        out = EditOverlays.reel(meal, clips: [clip(3), clip(3)], plan: .init())
        let spread = out.filter { $0.kind == "step" }
        XCTAssertEqual(spread.count, 3); XCTAssertEqual(spread[1].from, spread[0].to, accuracy: 0.001)
        plan = .init(); plan.title = false; plan.ingredients = false; plan.countUp = false; plan.show = ["p"]
        out = EditOverlays.reel(meal, clips: clips, plan: plan)
        XCTAssertFalse(out.contains { $0.kind == "card" || $0.kind == "ingredients" })
        XCTAssertEqual(out.first { $0.kind == "macros" }?.detail, "P 41 g")
        plan.method = false; plan.macros = false
        XCTAssertTrue(EditOverlays.reel(meal, clips: clips, plan: plan).isEmpty)
    }
}
