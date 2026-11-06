import XCTest
@testable import CheatDays

/// The adaptive check-in's maths on the owner's real Saturday weigh-ins (design/adaptive-calorie-checkin.md, §9).
final class AdaptiveTests: XCTestCase {
    private let saturdays: [Adaptive.Reading] = [("2026-10-03", 82.35), ("2026-10-10", 81.85), ("2026-10-17", 81.80),
                                                 ("2026-10-24", 81.30), ("2026-10-31", 79.95)].map { Adaptive.Reading(day: $0.0, kg: $0.1) }
    private let thursday = Adaptive.Reading(day: "2026-10-29", kg: 80.6)

    /// Every Saturday counts in a line through them all, not first against last; the Thursday is shown but not counted.
    func testTheRateIsTheLineThroughTheWeighInDay() {
        let r = Adaptive.rate(saturdays + [thursday], weighDay: 6, end: "2026-11-01")
        XCTAssertEqual(r?.perWeek ?? 0, -0.535, accuracy: 0.01)
        XCTAssertEqual(r?.method, "last 5 Saturdays")
        XCTAssertEqual(r?.used.count, 5)
        XCTAssertEqual(r?.left, [thursday])
    }

    /// The 31 Oct reading sits about 1.1 kg under the line through the four before it: a likely water swing.
    func testTheLatestReadingFarOffTheEarlierLineIsASwing() {
        let r = Adaptive.rate(saturdays, weighDay: 6, end: "2026-11-01")
        XCTAssertEqual(r?.swing ?? 0, -1.075, accuracy: 0.01)
        XCTAssertEqual(Adaptive.rate(Array(saturdays.prefix(4)), weighDay: 6, end: "2026-11-01")?.perWeek ?? 0, -0.32, accuracy: 0.01)
        XCTAssertNil(Adaptive.rate(Array(saturdays.prefix(4)), weighDay: 6, end: "2026-11-01")?.swing)
    }

    /// A reading marked as not the usual way stays off the line; with no weigh-in day, every usual reading counts.
    func testUnusualReadingsAreLeftOut() {
        var odd = saturdays; odd[4].usual = false
        let r = Adaptive.rate(odd, weighDay: 6, end: "2026-11-01")
        XCTAssertEqual(r?.used.count, 4)
        XCTAssertEqual(r?.left.map(\.day), ["2026-10-31"])
        let any = Adaptive.rate(saturdays + [thursday], weighDay: nil, end: "2026-11-01")
        XCTAssertEqual(any?.used.count, 5)   // the last 4 weeks: 10 Oct on, the Thursday included
        XCTAssertEqual(any?.method, "last 4 weeks")
    }

    /// Three weigh-ins over two weeks or more, or there's no rate.
    func testTooFewOrTooCloseTogetherGivesNoRate() {
        XCTAssertNil(Adaptive.rate(Array(saturdays.prefix(2)), weighDay: 6, end: "2026-11-01"))
        let close = ["2026-10-24", "2026-10-28", "2026-10-31"].map { Adaptive.Reading(day: $0, kg: 80) }
        XCTAssertNil(Adaptive.rate(close, weighDay: nil, end: "2026-11-01"))
    }

    /// The owner's export, 12 Sep to 31 Oct (the last reading of each day): nearly all Saturdays, one Thursday.
    /// Saturday is found without the setting, and the rate drops from −0.59 (every weigh-in) to −0.45.
    func testTheUsualDayIsFoundAndTheMidweekReadingLeftOut() {
        let export = [("2026-09-12", 83.25), ("2026-09-19", 83.05), ("2026-09-26", 82.45), ("2026-10-03", 82.35), ("2026-10-10", 81.85),
                      ("2026-10-17", 81.80), ("2026-10-24", 81.30), ("2026-10-29", 80.65), ("2026-10-31", 79.95)].map { Adaptive.Reading(day: $0.0, kg: $0.1) }
        let end = "2026-11-06"
        XCTAssertEqual(Adaptive.usualDay(export, end: end), 6)
        XCTAssertEqual(Adaptive.rate(export, weighDay: nil, end: end)?.perWeek ?? 0, -0.59, accuracy: 0.01)
        let r = Adaptive.rate(export, weighDay: Adaptive.usualDay(export, end: end), end: end)
        XCTAssertEqual(r?.perWeek ?? 0, -0.45, accuracy: 0.01)
        XCTAssertEqual(r?.method, "last 6 Saturdays")
        // someone who weighs most days has no usual day
        let daily = (0..<20).map { Adaptive.Reading(day: DayKey.shift(end, days: -$0), kg: 80) }
        XCTAssertNil(Adaptive.usualDay(daily, end: end))
    }

    /// Under 75 isn't worth it, and never more than 150 a day at once.
    func testTheStepHasADeadZoneAndACap() {
        XCTAssertNil(Adaptive.step(target: 2560, now: 2500))
        XCTAssertEqual(Adaptive.step(target: 2588, now: 2500), 88)
        XCTAssertEqual(Adaptive.step(target: 2800, now: 2500), 150)
        XCTAssertEqual(Adaptive.step(target: 2100, now: 2500), -150)
    }

    /// The owner's week (Mon–Fri 2,350, Sat 3,250, Sun 2,500) with +100 a day: +125 on every day but Saturday.
    func testAChangeLeavesTheTreatDayAlone() {
        let out = Adaptive.spread(100, budget: 2350, days: [6: 3250, 0: 2500], treat: 6)
        XCTAssertEqual(out.budget, 2475)
        XCTAssertEqual(out.days[0], 2625)
        XCTAssertEqual(out.days[6], 3250)
        // a treat day that was the everyday budget keeps it
        XCTAssertEqual(Adaptive.spread(100, budget: 2350, days: [:], treat: 6).days[6], 2350)
    }

    /// On a 0.45 kg goal at 80 kg the range is about 0.33 to 0.57; twice the goal, or the wrong way, acts in one week.
    func testTheRangeAroundTheGoal() {
        let tol = Adaptive.tolerance(want: -0.45, kg: 80)
        XCTAssertEqual(tol, 0.12, accuracy: 0.001)
        XCTAssertFalse(Adaptive.off(-0.535, want: -0.45, tol: tol))
        XCTAssertTrue(Adaptive.off(-0.6, want: -0.45, tol: tol))
        XCTAssertFalse(Adaptive.farOff(-0.6, want: -0.45, tol: tol))
        XCTAssertTrue(Adaptive.farOff(-0.9, want: -0.45, tol: tol))
        XCTAssertTrue(Adaptive.farOff(0.05, want: -0.45, tol: tol))
    }
}
