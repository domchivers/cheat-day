import XCTest
@testable import CheatDays

/// Templates as slots (21 Nov, design/templates-mockup.html): clips cut to their slots on the beat, the words from
/// the log.
final class TemplateTests: XCTestCase {
    private func clip(_ length: Double, start: Double = 0) -> Clip {
        Clip(source: URL(fileURLWithPath: "/tmp/c.mov"), length: length, start: start, end: length)
    }
    private func slots(_ n: Int, beats: Int = 4) -> [EditTemplate.Slot] { (0..<n).map { EditTemplate.Slot(name: "S\($0)", beats: beats) } }

    /// Each cut lands on the beat its slot ends on, the joins' overlap counted.
    func testCutsLandOnTheBeat() {
        let beats = stride(from: 0.25, to: 20, by: 0.5).map { $0 }
        for join in [nil, "Dissolve", "Whip"] as [String?] {
            let laid = EditTemplate.lay([clip(8), clip(8), clip(8)], slots: slots(3), beats: beats, join: join, look: "Warm")
            XCTAssertEqual(laid.count, 3)
            let starts = ClipJoin.starts(laid)
            XCTAssertEqual(starts[1], 1.75, accuracy: 0.01, "\(join ?? "cut"): the second starts on the fourth beat")
            XCTAssertEqual(starts[2], 3.75, accuracy: 0.01)
            XCTAssertEqual(ClipJoin.total(laid), 5.75, accuracy: 0.01, "ends on the twelfth")
            XCTAssertTrue(laid.allSatisfy { $0.look == "Warm" })
            XCTAssertEqual(laid[0].transition?.kind, join)
            XCTAssertNil(laid[2].transition, "nothing after the last")
        }
    }

    /// A clip plays from where it's set to start (Which part), moved back only as far as it must to last its slot;
    /// one too short plays whole.
    func testWhichPartAndShortClips() {
        let beats = stride(from: 0.0, to: 20, by: 0.5).map { $0 }
        let laid = EditTemplate.lay([clip(10, start: 3), clip(10, start: 9.5), clip(0.8)], slots: slots(3), beats: beats, join: nil, look: "Normal")
        XCTAssertEqual(laid[0].start, 3, accuracy: 0.001); XCTAssertEqual(laid[0].end, 5, accuracy: 0.001)
        XCTAssertEqual(laid[1].start, 8, accuracy: 0.001, "moved back to fit its two seconds")
        XCTAssertEqual(laid[2].start, 0); XCTAssertEqual(laid[2].end, 0.8, accuracy: 0.001)
        // no beat found: two a second
        let plain = EditTemplate.lay([clip(10)], slots: slots(1), beats: [], join: nil, look: "Normal")
        XCTAssertEqual(plain[0].span, 2, accuracy: 0.001)
    }

    func testWordsComeFromTheLog() {
        let day = EditTemplate.all.first { $0.id == "day" }!
        let log = EditTemplate.Log(today: "2026-11-21", items: [
            ["name": "Oats", "kcal": 300, "meal": "Breakfast"], ["name": "Berries", "kcal": 120, "meal": "Breakfast"],
            ["name": "Burrito bowl", "kcal": 640, "meal": "Lunch"],
        ])
        let s = day.slots(log)
        XCTAssertEqual(s.map(\.name), ["Breakfast", "Lunch"])
        XCTAssertEqual(s[0].detail, "Oats, Berries · 420 kcal")
        XCTAssertEqual(s[1].detail, "Burrito bowl · 640 kcal")
        // nothing logged: named slots, no numbers made up
        XCTAssertTrue(day.slots(EditTemplate.Log(today: "2026-11-21")).allSatisfy { $0.detail.isEmpty })

        let gym = EditTemplate.all.first { $0.id == "gym" }!
        let lifts = gym.slots(EditTemplate.Log(today: "2026-11-21", workouts: [["name": "Push", "lifts": [["exercise": "Bench press", "sets": 3, "reps": 8, "kg": 80] as JSON] as [JSON]] as JSON]))
        XCTAssertEqual(lifts.first?.name, "Bench press"); XCTAssertEqual(lifts.first?.detail, "3 × 8 · 80 kg")

        let cheat = EditTemplate.all.first { $0.id == "cheat" }!.slots(log)
        XCTAssertEqual(cheat.last?.name, "Today"); XCTAssertEqual(cheat.last?.detail, "1060 kcal")
        XCTAssertEqual(cheat.first?.name, "Burrito bowl", "the biggest first")

        let before = EditTemplate.all.first { $0.id == "before" }!.slots(EditTemplate.Log(today: "2026-11-21", weights: [("2026-03-03", 92.4), ("2026-11-21", 84.1)]))
        XCTAssertEqual(before.count, 2); XCTAssertTrue(before[0].detail.hasPrefix("92.4 kg")); XCTAssertTrue(before[1].detail.hasPrefix("84.1 kg"))
    }

    func testLabelsSitOverTheirClips() {
        let beats = stride(from: 0.0, to: 20, by: 0.5).map { $0 }
        let s = [EditTemplate.Slot(name: "Lunch", detail: "640 kcal"), EditTemplate.Slot(name: "Dinner", detail: "800 kcal")]
        let laid = EditTemplate.lay([clip(8), clip(8)], slots: s, beats: beats, join: "Push", look: "Pop")
        let words = EditTemplate.labels(laid, slots: s)
        XCTAssertEqual(words.map(\.text), ["Lunch", "Dinner"])
        XCTAssertTrue(words.allSatisfy { $0.kind == "label" && $0.part == "template" })
        XCTAssertEqual(words[0].from, 0); XCTAssertEqual(words[0].to, words[1].from, accuracy: 0.001)
        XCTAssertEqual(words[1].to, ClipJoin.total(laid), accuracy: 0.001)
    }
}
