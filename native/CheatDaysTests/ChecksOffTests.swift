import XCTest
@testable import CheatDays

/// What each check does to the weighed plates (DatasetFixtures): the set scored with every check on, then with each
/// one switched off in turn (Assistant.off). A check whose switching off makes the plates more accurate is hurting them;
/// one that changes nothing isn't earning its place on these plates. A measurement, not a pass mark: its "CHECKS-OFF:"
/// lines in the log are the result. The follow-up checks (held, unfolded, keepingEarlier, steady) need earlier cards,
/// which these single plates don't have, so they show no change here; ReplayTests and SteadyTests cover them.
@MainActor
final class ChecksOffTests: XCTestCase {
    struct Score { var kcal = 0.0; var within = 0; var protein = 0.0; var cards: [String: Double] = [:] }

    func score(_ plates: [JSON]) async -> Score {
        func sum(_ e: JSON, _ k: String) -> Double { list(e["parts"]).reduce(0) { $0 + (num($1[k]) ?? 0) } }
        var s = Score(), err: [Double] = [], perr: [Double] = []
        for plate in plates {
            let e = dict(plate["estimate"]), truth = dict(plate["truth"]), id = str(plate["id"])
            let tk = num(truth["kcal"]) ?? 1, tp = max(num(truth["protein_g"]) ?? 1, 1)
            let out = await Assistant.checkedCard(Assistant.shown(e, said: "Lunch", photos: true, before: nil, via: "Claude").estimate, before: nil, earlier: [])
            let k = sum(out, "kcal")
            s.cards[id] = k
            err.append(abs(k - tk) / tk * 100); perr.append(abs(sum(out, "protein_g") - tp) / tp * 100)
        }
        s.kcal = err.reduce(0, +) / Double(max(err.count, 1))
        s.protein = perr.reduce(0, +) / Double(max(perr.count, 1))
        s.within = err.filter { $0 <= 20 }.count
        return s
    }

    func testEachCheckSwitchedOff() async throws {
        let table = FoodTable.testing
        FoodTable.testing = .us
        let was = (Assistant.findLabel, Assistant.findFoods)
        Assistant.ownFoods = false
        Assistant.findFoods = { _ in nil }
        Assistant.findLabel = { _ in nil }
        defer { FoodTable.testing = table; Assistant.ownFoods = true; (Assistant.findLabel, Assistant.findFoods) = was; Assistant.off = [] }

        let plates = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DatasetFixtures.json.utf8)) as? [JSON])
        Assistant.off = []
        let all = await score(plates)
        func line(_ s: Score) -> String { "calories off by \(String(format: "%.1f", s.kcal))%, within 20%: \(s.within), protein off by \(String(format: "%.1f", s.protein))%" }
        print("CHECKS-OFF: \(plates.count) plates, every check on: \(line(all))")
        for check in Assistant.switchable {
            Assistant.off = [check]
            let s = await score(plates)
            let changed = s.cards.filter { abs($0.value - (all.cards[$0.key] ?? 0)) >= 1 }.count
            let verdict = changed == 0 ? "changes nothing here" : s.kcal < all.kcal - 0.2 ? "HURTS: better without it" : s.kcal > all.kcal + 0.2 ? "helps" : "about even"
            print("CHECKS-OFF: \(check) off: \(line(s)); \(changed) plates changed; \(verdict)")
        }
    }
}
