import XCTest
@testable import CheatDays

/// Past cards replayed through every step after the AI (tidied, held, the food tables, earlier cards), with no
/// network: the web label lookup and the food server are stand-ins, and their own scans and logs are left out. Each
/// one is a card that once came out wrong; the AI's answer is as it was, so only the app's own steps are tested.
@MainActor
final class ReplayTests: XCTestCase {
    private func offline(label: JSON? = nil) {
        let was = (Assistant.findLabel, Assistant.findFoods)
        Assistant.ownFoods = false
        Assistant.findFoods = { _ in nil }
        Assistant.findLabel = { _ in label }
        addTeardownBlock { @MainActor in
            Assistant.ownFoods = true
            (Assistant.findLabel, Assistant.findFoods) = was
        }
    }

    /// The whole chain after the AI, as the chat runs it.
    private func replay(_ e: JSON, said: String, photos: Bool = false, before: JSON? = nil, earlier: [JSON] = []) async -> JSON {
        let shown = Assistant.shown(e, said: said, photos: photos, before: before, via: "Claude").estimate
        return await Assistant.checkedCard(shown, before: before, earlier: earlier)
    }

    private func part(_ name: String, _ g: Double, _ k: Double, _ p: Double, _ c: Double, _ f: Double, from: String = "estimate") -> JSON {
        ["name": name, "grams": g, "kcal": k, "protein_g": p, "carbs_g": c, "fat_g": f, "numbers_from": from]
    }

    /// The owner's hotpot recheck, 15 Nov: a label found on the web gave the soup base 1,269 kcal for a 41 g serving,
    /// so the 26 g they drank came out at 793 and the card at 1,426 where the AI had said about 820.
    func testTheHotpotRecheckStaysNearTheAIs() async {
        offline(label: ["found": true, "serving_g": 41, "kcal": 1269, "protein_g": 10, "carbs_g": 70, "fat_g": 105, "source": "a web page"])
        let e: JSON = ["name": "Hotpot noodles with fatty beef rolls and cabbage", "kcal_total": 820, "portion_g": 466, "parts": [
            part("LIHAILONG Spicy Instant Pot soup base, drunk", 26, 120, 1, 3, 11, from: "brand"),
            part("Instant noodles from the pack, boiled", 180, 300, 7, 45, 10),
            part("Fatty beef rolls, simmered", 125, 360, 20, 0, 31),
            part("Cabbage, simmered in the soup", 135, 42, 1.7, 6, 0.2),
        ] as [Any]]
        let out = await replay(e, said: "Recheck: I ate all the noodles and veg, only left the broth. The beef rolls are the fatty kind", photos: true)
        let parts = list(out["parts"])
        for p in parts { XCTAssertTrue(Assistant.physical(p), "\(str(p["name"])) can't be true: \(num(p["kcal"]) ?? 0) kcal for \(num(p["grams"]) ?? 0) g") }
        let base = parts.first { str($0["name"]).contains("soup base") }
        XCTAssertNotEqual(str(base?["src"]), "web", "the impossible label isn't used")
        XCTAssertLessThan(num(base?["kcal"]) ?? 999, 200)
        let total = num(out["kcal_total"]) ?? 0
        XCTAssertTrue((650...1000).contains(total), "the card came out at \(total)")
        // the beef was matched to Swedish minced meat rolls once
        let beef = parts.first { str($0["name"]).lowercased().contains("beef") }
        XCTAssertFalse(str(beef?["match"]).lowercased().contains("minced"), str(beef?["match"]))
    }

    /// A branded product's label that can be true is used, per its serving.
    func testAPossibleLabelIsUsed() async {
        offline(label: ["found": true, "serving_g": 85, "kcal": 385, "protein_g": 8, "carbs_g": 52, "fat_g": 16, "source": "the maker's page"])
        let out = await replay(["name": "Mi goreng", "kcal_total": 400, "parts": [part("Indomie Mi Goreng, cooked", 85, 400, 8, 54, 17, from: "brand")] as [Any]],
                               said: "Had a mi goreng")
        let p = list(out["parts"])[0]
        XCTAssertEqual(str(p["src"]), "web")
        XCTAssertEqual(num(p["kcal"]), 385)
    }

    /// Lamb gyros came out as lean lamb fillet (160 kcal a 100 g); it's the fatty spit meat.
    func testLambGyrosIsTheSpitMeat() async {
        offline()
        let out = await replay(["name": "Lamb gyros plate", "kcal_total": 240, "parts": [part("Lamb gyros meat, grilled", 150, 240, 30, 0, 13)] as [Any]],
                               said: "Lamb gyros plate, just the meat")
        let p = list(out["parts"])[0]
        XCTAssertEqual(str(p["match"]), "Lamb gyros meat")
        XCTAssertEqual(num(p["kcal"]) ?? 0, 402, accuracy: 3)
    }

    /// Asked again without new photos, the parts already worked out keep the last card's numbers.
    func testAFollowUpKeepsTheLastCardsNumbers() async {
        offline()
        let before: JSON = ["name": "Hotpot", "kcal_total": 409, "portion_g": 311, "parts": [
            ["name": "Beef rolls, thin sliced, simmered in the soup", "grams": 125, "kcal": 194, "protein_g": 20, "carbs_g": 0, "fat_g": 12.5, "src": "ai"] as JSON,
            ["name": "Cabbage, simmered in the soup", "grams": 135, "kcal": 42, "protein_g": 1.7, "carbs_g": 6, "fat_g": 0.2, "src": "ai"] as JSON,
        ] as [Any]]
        let e: JSON = ["name": "Hotpot", "kcal_total": 520, "parts": [
            part("Beef rolls, thin sliced, simmered in the soup", 125, 300, 22, 0, 23),
            part("Cabbage, simmered in the soup", 135, 60, 2, 9, 0.5),
        ] as [Any]]
        let out = await replay(e, said: "What's the protein in that?", before: before, earlier: [before])
        let cab = list(out["parts"]).first { str($0["name"]).hasPrefix("Cabbage") }
        XCTAssertEqual(num(cab?["kcal"]) ?? 0, 42, accuracy: 1)
    }

    /// Every step that changed the card is on its trace, starting with what the AI said, and the report has it all.
    func testTheTraceRecordsEachStep() async {
        offline(label: ["found": true, "serving_g": 41, "kcal": 1269, "protein_g": 10, "carbs_g": 70, "fat_g": 105, "source": "a web page"])
        let e: JSON = ["name": "Lamb gyros plate", "kcal_total": 240, "parts": [part("Lamb gyros meat, grilled", 150, 240, 30, 0, 13)] as [Any]]
        let out = await replay(e, said: "Lamb gyros plate")
        let trace = list(out["trace"])
        XCTAssertEqual(str(trace.first?["step"]), "AI (Claude)")
        XCTAssertEqual((trace.first?["lines"] as? [String])?.first, "Lamb gyros meat, grilled · 150 g · 240 kcal · P30 C0 F13 · estimate")
        XCTAssertTrue(trace.contains { str($0["step"]) == "checked against the food tables" })
        XCTAssertEqual((trace.last?["lines"] as? [String])?.last, "total \(Int(num(out["kcal_total"]) ?? 0)) kcal")
        let report = Assistant.report([Assistant.Turn(me: true, text: "Lamb gyros plate"), Assistant.Turn(me: false, text: "About 400.", result: ["estimate": out])])
        XCTAssertTrue(report.contains("Me: Lamb gyros plate"))
        XCTAssertTrue(report.contains("[checked against the food tables]"))
        XCTAssertTrue(report.contains("(Lamb gyros meat)"))
        // a step that changes nothing isn't added
        XCTAssertEqual(list(Assistant.traced("again", out)["trace"]).count, trace.count)
    }
}
