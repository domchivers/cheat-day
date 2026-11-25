import XCTest
@testable import CheatDays

/// Personal bests and weeks in a row (26 Nov, design/bests-weekgoal-mockup.html).
final class BestsTests: XCTestCase {
    /// A straight route north, a point every 100 m, each 100 m taking these seconds.
    private func route(_ secondsPer100: [Double]) -> [RoutePoint] {
        let step: Double = 100.0 / 111_195.0
        var t: Double = 0
        var out: [RoutePoint] = [RoutePoint(lat: -37.85, lon: 144.97, t: 0, run: true)]
        for (i, s) in secondsPer100.enumerated() {
            t += s
            out.append(RoutePoint(lat: -37.85 + step * Double(i + 1), lon: 144.97, t: t, run: true))
        }
        return out
    }

    /// The fastest stretch of a distance, wherever it is along the run.
    func testFastestStretch() {
        let even: [RoutePoint] = route(Array(repeating: 30, count: 30))   // 3 km at 5:00 /km
        XCTAssertEqual(Bests.fastest(even, meters: 1000) ?? 0, 300, accuracy: 2)
        // the second kilometre quicker, at 4:00
        let quick: [RoutePoint] = route(Array(repeating: 30, count: 10) + Array(repeating: 24, count: 10) + Array(repeating: 30, count: 10))
        XCTAssertEqual(Bests.fastest(quick, meters: 1000) ?? 0, 240, accuracy: 3)
        XCTAssertNil(Bests.fastest(route(Array(repeating: 30, count: 5)), meters: 1000), "half a kilometre has no 1 km")
        XCTAssertEqual(Bests.efforts(even, kind: .run)["run1k"] ?? 0, 300, accuracy: 2)
        XCTAssertNil(Bests.efforts(even, kind: .run)["run5k"])
    }

    /// Weeks in a row: this week counts once it's hit; one week short in four is let off, never two together.
    func testWeeksInARow() {
        XCTAssertEqual(Bests.weeksInARow(goal: 3, counts: [3, 3, 3]), 3)
        XCTAssertEqual(Bests.weeksInARow(goal: 3, counts: [1, 3, 3]), 2, "this week still going doesn't break it")
        XCTAssertEqual(Bests.weeksInARow(goal: 3, counts: [1, 1, 3, 3]), 2, "last week short, let off")
        XCTAssertEqual(Bests.weeksInARow(goal: 3, counts: [3, 1, 1, 3]), 1, "two short together end it")
        XCTAssertEqual(Bests.weeksInARow(goal: 3, counts: [3, 1, 3, 1, 3]), 2, "two short in four end it")
        XCTAssertEqual(Bests.weeksInARow(goal: 3, counts: [3, 3, 1, 3, 3, 3, 1, 3]), 6, "one short a month, twice")
        XCTAssertEqual(Bests.weeksInARow(goal: 0, counts: [5, 5]), 0, "no goal, no weeks")
        XCTAssertEqual(Bests.weeksInARow(goal: 3, counts: [0]), 0)
    }

    /// What a best looks like, and what it beat.
    func testBestText() {
        let fiveK: BestDef = BestDef.all.first { $0.key == "run5k" }!
        XCTAssertEqual(fiveK.text(1661), "27:41")
        XCTAssertTrue(fiveK.better(1661, than: 1699))
        let long: BestDef = BestDef.all.first { $0.key == "rideLong" }!
        XCTAssertEqual(long.text(42.31), "42.3 km")
        XCTAssertTrue(long.better(43, than: 42.3))
        XCTAssertEqual(Bests.time(3735), "1:02:15")
        let beaten = BestEntry(def: fiveK, value: 1699, date: "2026-11-03", workout: ["id": "a"])
        XCTAssertEqual(BestNews(def: fiveK, value: 1661, place: 1, other: beaten).line, "38 s faster than 28:19 on 3 Nov")
    }
}
