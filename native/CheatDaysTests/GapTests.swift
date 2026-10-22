import XCTest
@testable import CheatDays

/// The leaderboard row, the assistant's food check, and the feed's helpers.
final class GapTests: XCTestCase {
    // friends see how far through the week's goals you are, like the website's week_pct
    @MainActor
    func testWeekPercentMatchesTheWebsite() {
        let pct = Store.weekPercent(progress: ["under": 5, "log": 3, "workouts": 1], goals: ["under": 5, "log": 7, "workouts": 3], active: ["under", "log", "workouts"])
        XCTAssertEqual(pct, 59)   // (1 + 3/7 + 1/3) / 3
        XCTAssertEqual(Store.weekPercent(progress: [:], goals: [:], active: []), 0)
        XCTAssertEqual(Store.weekPercent(progress: ["log": 9], goals: ["log": 7], active: ["log"]), 100)   // capped at the goal
    }

    // a database number only replaces the AI's when it's in the same ballpark
    func testOnlyPlausibleMatchesReplaceTheEstimate() {
        XCTAssertTrue(Assistant.plausible(165, aiKcal: 300, grams: 150))    // AI said 200 per 100 g
        XCTAssertFalse(Assistant.plausible(60, aiKcal: 300, grams: 150))    // far too low: a wrong match
        XCTAssertFalse(Assistant.plausible(400, aiKcal: 300, grams: 150))   // far too high
        XCTAssertFalse(Assistant.plausible(nil, aiKcal: 300, grams: 150))
        XCTAssertTrue(Assistant.plausible(250, aiKcal: 0, grams: 150))      // nothing to compare with
    }

    func testCheckedPartsRebuildTheTotals() {
        let est: JSON = ["name": "Chicken and rice", "kcal_total": 700, "portion_g": 400]
        let chicken = Assistant.checked(["name": "chicken", "grams": 150, "kcal": 300, "src": "ai"], kcal100: 165, p100: 31, c100: 0, f100: 3.6, source: "usda")
        let rice: JSON = ["name": "rice", "grams": 250, "kcal": 400, "protein_g": 7, "carbs_g": 85, "fat_g": 1, "src": "ai"]
        let out = Assistant.totals(est, parts: [chicken, rice])
        XCTAssertEqual(num(chicken["kcal"]), 248)
        XCTAssertEqual(num(out["kcal_total"]), 648)
        XCTAssertEqual(num(out["aiKcal"]), 700)
        XCTAssertEqual(num(out["portion_g"]), 400)
        XCTAssertEqual(num(out["protein_g"]) ?? 0, 53.5, accuracy: 0.1)
        // nothing checked: the AI's totals stand
        XCTAssertEqual(num(Assistant.totals(est, parts: [rice])["kcal_total"]), 700)
    }

    @MainActor
    func testFeedPhotosAreSmallSquares() {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 800)) }
        guard let d = Feed.square(img), let back = UIImage(data: d) else { return XCTFail("no photo") }
        XCTAssertEqual(back.size.width * back.scale, 640, accuracy: 1)
        XCTAssertEqual(back.size.height * back.scale, 640, accuracy: 1)
        XCTAssertLessThan(d.count, 120_000)
    }

    @MainActor
    func testFeedTimes() {
        XCTAssertEqual(Feed.ago(ISO.now()), "just now")
        let twoHours = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7300))
        XCTAssertEqual(Feed.ago(twoHours), "2 h ago")
    }

    // weights keep their decimals: a scale's 83.32 and a 61.25 kg lift aren't rounded away
    func testWeightsKeepTwoDecimals() {
        XCTAssertEqual(Fmt.kg(83.32), "83.32")
        XCTAssertEqual(Fmt.kg(61.25), "61.25")
        XCTAssertEqual(Fmt.kg(82.4), "82.4")
        XCTAssertEqual(Fmt.kg(80), "80")
        XCTAssertEqual(Fmt.kg(83.326), "83.33")
        XCTAssertEqual(Fmt.kg2(83.324), 83.32)
        XCTAssertEqual(Fmt.one(82.4), "82.4")   // was 82: anything over 10 lost its decimal
    }

    // the scale's reading from Health: replaces an older one, keeps a later correction, skips an identical one
    func testHealthReadingsAndYourOwn() {
        let scale: JSON = ["day": "2026-10-13", "weight": 83.32, "takenAt": "2026-10-13T07:42:00Z", "updatedAt": "2026-10-13T07:42:00Z", "from": "health"]
        XCTAssertTrue(HealthSync.shouldImport(scale, over: nil))
        XCTAssertTrue(HealthSync.shouldImport(scale, over: ["day": "2026-10-13", "weight": 83.3, "updatedAt": "2026-10-13T06:00:00.000Z"]))     // typed before: replaced
        XCTAssertFalse(HealthSync.shouldImport(scale, over: ["day": "2026-10-13", "weight": 83.1, "updatedAt": "2026-10-13T09:00:00.000Z"]))    // corrected after: kept
        XCTAssertTrue(HealthSync.shouldImport(scale, over: ["day": "2026-10-13", "weight": 83.3, "updatedAt": "2026-10-13T07:42:00Z", "from": "health"]))   // an old import: corrected
        XCTAssertFalse(HealthSync.shouldImport(scale, over: scale))   // nothing new
    }

    // after midnight, yesterday can come back out of History with its food (the website's unrollDay)
    func testBringingYesterdayBack() {
        var d: JSON = ["day": ["date": "2026-10-23", "items": [Any](), "workouts": [Any]()] as JSON,
                       "history": [["date": "2026-10-22", "kcal": 1800, "items": [["name": "Toast", "kcal": 160] as JSON], "workouts": [Any]()] as JSON]]
        Store.apply(["type": "unroll", "date": "2026-10-22"], to: &d, today: "2026-10-23")
        XCTAssertEqual(str(dict(d["day"])["date"]), "2026-10-22")
        XCTAssertEqual(list(dict(d["day"])["items"]).count, 1)
        XCTAssertFalse(str(list(dict(d["day"])["items"])[0]["id"]).isEmpty)
        XCTAssertTrue(list(d["history"]).isEmpty)
        XCTAssertEqual(str(d["dayKeep"]), "2026-10-22")
        // not over a day that already has food
        var e: JSON = ["day": ["date": "2026-10-23", "items": [["id": "x", "name": "Tea", "kcal": 20] as JSON]] as JSON,
                       "history": [["date": "2026-10-22", "items": [["name": "Toast", "kcal": 160] as JSON]] as JSON]]
        Store.apply(["type": "unroll", "date": "2026-10-22"], to: &e, today: "2026-10-23")
        XCTAssertEqual(str(dict(e["day"])["date"]), "2026-10-23")
    }
}
