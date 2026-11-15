import XCTest
@testable import CheatDays

/// Weighed plates (Nutrition5k, see DatasetFixtures) replayed through every step after the AI, offline: the AI's
/// estimate for each photo as Claude gave it, then the app's own checks, scored against the scale. It fails when the
/// checks make a plate impossible, move one wildly from what the AI said, or leave the set less accurate than the AI
/// alone or than the score it last had. Its "DATASET:" lines in the log are the score and the worst plates.
@MainActor
final class DatasetReplayTests: XCTestCase {
    /// The set's mean calorie error after the app's checks, last time it was measured (the AI alone: 35%). Lower it
    /// when a change improves it; a change that makes it worse fails here.
    static let scoreToBeat = 40.0

    func testWeighedPlatesThroughTheAppsChecks() async throws {
        let was = (Assistant.findLabel, Assistant.findFoods)
        Assistant.ownFoods = false
        Assistant.findFoods = { _ in nil }
        Assistant.findLabel = { _ in nil }
        defer { Assistant.ownFoods = true; (Assistant.findLabel, Assistant.findFoods) = was }

        let plates = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DatasetFixtures.json.utf8)) as? [JSON])
        XCTAssertGreaterThan(plates.count, 50)
        func sum(_ e: JSON, _ k: String) -> Double { list(e["parts"]).reduce(0) { $0 + (num($1[k]) ?? 0) } }
        var aiErr: [Double] = [], appErr: [Double] = [], aiP: [Double] = [], appP: [Double] = [], rows: [(Double, String)] = []
        for plate in plates {
            let e = dict(plate["estimate"]), truth = dict(plate["truth"]), id = str(plate["id"])
            let tk = num(truth["kcal"]) ?? 1, tp = max(num(truth["protein_g"]) ?? 1, 1)
            let out = await Assistant.checkedCard(Assistant.shown(e, said: "Lunch", photos: true, before: nil, via: "Claude").estimate, before: nil, earlier: [])
            let ai = sum(e, "kcal"), app = sum(out, "kcal")
            for p in list(out["parts"]) { XCTAssertTrue(Assistant.physical(p), "\(id) \(str(p["name"])): \(num(p["kcal"]) ?? 0) kcal for \(num(p["grams"]) ?? 0) g") }
            XCTAssertTrue(app <= 3 * ai + 50 && app >= ai / 3 - 50, "\(id): the checks moved \(Int(ai)) kcal to \(Int(app))")
            aiErr.append(abs(ai - tk) / tk * 100); appErr.append(abs(app - tk) / tk * 100)
            aiP.append(abs(sum(e, "protein_g") - tp) / tp * 100); appP.append(abs(sum(out, "protein_g") - tp) / tp * 100)
            // the plates the checks moved most, and which way
            let moved = list(out["parts"]).compactMap { p -> String? in
                let m = str(p["match"]); return m.isEmpty ? nil : "\(str(p["name"])) → \(m)"
            }.prefix(4).joined(separator: "; ")
            let delta = abs(app - tk) / tk * 100 - abs(ai - tk) / tk * 100
            rows.append((delta, "\(id) scale \(Int(tk)) · AI \(Int(ai)) · app \(Int(app)) · \(moved)"))
            // where each part's numbers came from, for the plates the checks made worse: which table entry, found how
            if delta >= 10 {
                let asked = list(e["parts"])
                for (i, p) in list(out["parts"]).enumerated() {
                    let a = i < asked.count ? asked[i] : [:], name = str(a["name"]), tags = Assistant.tags(a)
                    print("DATASET-PART: \(id) \(name) [\(tags.joined(separator: ","))] \(Int(num(a["grams"]) ?? 0)) g \(Int(num(a["kcal"]) ?? 0)) → \(Int(num(p["kcal"]) ?? 0)) kcal"
                          + " · src \(str(p["src"])) · match \(str(p["match"]))" + (str(p["swapped"]).isEmpty ? "" : " · SWAPPED")
                          + " · range \(Sanity.range(name)?.label ?? "-") · ref \(FoodReference.match(name)?.name ?? "-")"
                          + " · find \(FoodTable.current.find(name)?.name ?? "-") · best \(FoodTable.current.best(name, tags: tags)?.name ?? "-")")
                }
            }
        }
        func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(max(x.count, 1)) }
        func within(_ x: [Double]) -> Int { x.filter { $0 <= 20 }.count }
        print("DATASET: \(plates.count) plates. Calories off by \(Int(mean(aiErr).rounded()))% (AI alone) → \(Int(mean(appErr).rounded()))% (after the app's checks); within 20%: \(within(aiErr)) → \(within(appErr))")
        print("DATASET: protein off by \(Int(mean(aiP).rounded()))% → \(Int(mean(appP).rounded()))%")
        for r in rows.sorted(by: { $0.0 > $1.0 }).prefix(8) { print("DATASET: worse by \(Int(r.0)) points: \(r.1)") }
        for r in rows.sorted(by: { $0.0 < $1.0 }).prefix(5) { print("DATASET: better by \(Int(-r.0)) points: \(r.1)") }
        XCTAssertLessThanOrEqual(mean(appErr), mean(aiErr) + 3, "the app's checks leave the plates less accurate than the AI alone")
        XCTAssertLessThanOrEqual(mean(appErr), Self.scoreToBeat, "worse than the last score")
    }
}
