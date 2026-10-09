import XCTest
@testable import CheatDays

/// Weigh-ins: one row per day, merged, newest weight becomes the weight used for workout burns.
@MainActor
final class BodyTests: XCTestCase {
    func testWeighInMergesTheDayAndSetsWeight() {
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON,
                       "body": [["day": "2026-10-01", "weight": 82.4, "fat": 21.0] as JSON] as [Any],
                       "tombs": ["body:2026-10-08": 1] as JSON]
        Store.apply(["type": "body", "row": ["day": "2026-10-01", "weight": 82.1, "updatedAt": "x"] as JSON], to: &d, today: "2026-10-09")
        Store.apply(["type": "body", "row": ["day": "2026-10-08", "weight": 81.6, "updatedAt": "y"] as JSON], to: &d, today: "2026-10-09")
        let rows = list(d["body"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(num(rows[0]["weight"]), 82.1)
        XCTAssertEqual(num(rows[0]["fat"]), 21.0, "other readings on that day are kept")
        XCTAssertEqual(num(d["weightKg"]), 81.6)
        XCTAssertNil(dict(d["tombs"])["body:2026-10-08"], "a new reading undoes an old deletion")
    }
}
