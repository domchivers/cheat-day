import XCTest
@testable import CheatDays

/// The week review says what's working before what to change, and never flags a food that's helping.
final class WeekReviewTests: XCTestCase {
    /// An item with protein: kcal per 100 g and protein per 100 g, so FoodMath works out the grams.
    private func food(_ name: String, kcal: Double, p100: Double, k100: Double, meal: String) -> JSON {
        ["name": name, "kcal": kcal, "kcalPer100": k100, "p100": p100, "c100": 0, "f100": 0, "meal": meal]
    }
    private var brownie: JSON { food("Protein brownie", kcal: 190, p100: 33, k100: 316, meal: "Snacks") }   // 60 g: 20 g protein
    private func day(_ items: [JSON], budget: Double = 1800) -> WeekReview.Day {
        WeekReview.Day(items: items, budget: budget, kcal: items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) })
    }

    /// The owner's week: on budget, protein hit, losing, with a protein brownie most days.
    func testAGoodWeekSaysSoAndPraisesTheBrownie() {
        let good = (0..<7).map { _ in day([food("Rice", kcal: 520, p100: 3, k100: 130, meal: "Dinner"), brownie,
                                           food("Toast", kcal: 300, p100: 9, k100: 260, meal: "Breakfast")]) }
        let r = WeekReview.make(days: good, proteinGoal: 40, pace: -0.4, want: -0.5)
        XCTAssertEqual(r?.title, "A good week")
        XCTAssertEqual(r?.rows.map(\.ok), [true, true, true])
        XCTAssertTrue(r?.tip.contains("protein brownie's earning its place: 20 g protein for 190 kcal") == true, r?.tip ?? "")
        XCTAssertTrue(WeekReview.proteinRich(brownie))
    }

    /// Protein short on most days: the meal with the least protein is named, with a link to ideas for it.
    func testShortProteinNamesTheMeal() {
        let days = (0..<7).map { i in day([food("Eggs", kcal: 150, p100: 13, k100: 150, meal: "Breakfast"),
                                           food("Chicken wrap", kcal: 500, p100: 12, k100: 250, meal: "Lunch"),
                                           food("Pasta", kcal: 600, p100: 2, k100: 150, meal: "Dinner")] + (i < 2 ? [food("Steak", kcal: 500, p100: 30, k100: 250, meal: "Dinner")] : [])) }
        let r = WeekReview.make(days: days, proteinGoal: 100, pace: -0.4, want: -0.5)
        XCTAssertEqual(r?.title, "Protein's short")
        XCTAssertEqual(r?.rows[1], WeekReview.Row(label: "Protein goal hit", value: "2 of 7 days", ok: false))
        XCTAssertEqual(r?.plan, "Dinner")
        XCTAssertTrue(r?.tip.hasPrefix("Dinners are where it drops: about 8 g") == true, r?.tip ?? "")
    }

    /// One big day out of seven is still a good week; a swap is only offered when the budget is being missed.
    func testOneOverDayIsFineAndSwapsWaitForAMiss() {
        var days = (0..<6).map { _ in day([food("Chicken breast", kcal: 1500, p100: 31, k100: 165, meal: "Dinner")]) }
        days.append(day([food("Pizza", kcal: 2600, p100: 11, k100: 260, meal: "Dinner")]))
        XCTAssertEqual(WeekReview.make(days: days, proteinGoal: nil, pace: nil, want: nil)?.title, "A good week")
        let over = (0..<7).map { _ in day([food("Pizza", kcal: 2200, p100: 11, k100: 260, meal: "Dinner")]) }
        let r = WeekReview.make(days: over, proteinGoal: nil, pace: nil, want: nil, swap: (food: "Pizza", saves: 300, pick: "Thin crust pizza", days: 7))
        XCTAssertEqual(r?.title, "A few days over budget")
        XCTAssertEqual(r?.tip, "Your pizza came up 7 days. Thin crust pizza instead saves 300 kcal each time.")
    }

    /// The owner's card: every day on budget and protein hit, but losing 0.6 kg a week on a plan to gain. It says
    /// which way it's off and against what, not "not moving".
    func testLosingOnAGainPlanSaysSo() {
        let days = (0..<7).map { _ in day([food("Chicken breast", kcal: 1500, p100: 31, k100: 165, meal: "Dinner")]) }
        let r = WeekReview.make(days: days, proteinGoal: 100, pace: -0.6, want: 0.25)
        XCTAssertEqual(r?.title, "Losing instead of gaining")
        XCTAssertEqual(r?.status, "Nearly there")
        XCTAssertEqual(r?.rows.last, WeekReview.Row(label: "Weight", value: "−0.6 kg a week", ok: false, note: "Last 4 weeks · plan +0.25 kg"))
        XCTAssertTrue(r?.tip.hasPrefix("You've lost 0.6 kg a week over the last 4 weeks, and your plan is gaining 0.25 kg a week.") == true, r?.tip ?? "")
        // a loss on plan is fine, a stall on a losing plan is "not moving", and going up on it says so
        XCTAssertEqual(WeekReview.make(days: days, proteinGoal: 100, pace: -0.6, want: -0.5)?.title, "A good week")
        XCTAssertEqual(WeekReview.make(days: days, proteinGoal: 100, pace: -1.2, want: -0.5)?.title, "Losing faster than planned")
        XCTAssertEqual(WeekReview.make(days: days, proteinGoal: 100, pace: -0.6, want: 0)?.title, "Losing when you meant to hold")
        XCTAssertEqual(WeekReview.make(days: days, proteinGoal: 100, pace: -0.1, want: -0.5)?.title, "Weight's not moving")
        XCTAssertEqual(WeekReview.make(days: days, proteinGoal: 100, pace: 0.2, want: -0.5)?.title, "Weight's going up")
    }

    func testTooFewDaysSaysNothing() {
        XCTAssertNil(WeekReview.make(days: [day([brownie]), day([brownie]), day([])], proteinGoal: 100, pace: nil, want: nil))
    }
}
