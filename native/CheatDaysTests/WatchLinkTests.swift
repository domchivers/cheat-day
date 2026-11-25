import XCTest
import UIKit
@testable import CheatDays

/// The watch app's messages (25 Nov, design/watch-app-v5-mockup.html).
@MainActor
final class WatchLinkTests: XCTestCase {
    func testTodayGoesThereAndBack() {
        var t = WatchToday.empty
        t.date = "2026-11-25"; t.budget = 2100; t.eaten = 1460; t.protein = 92; t.proteinGoal = 150
        t.meals = [WatchToday.Meal(name: "Lunch", kcal: 610, foods: [WatchToday.Food(id: "a", name: "Chicken wrap", kcal: 480, amount: "1 wrap", icon: "food-1f32f")])]
        let back = WatchCoding.value(WatchToday.self, WatchCoding.data(t))
        XCTAssertEqual(back, t)
        XCTAssertEqual(back?.left, 640)
    }

    func testTodayFromTheRecordUsesBundledIcons() {
        let t = WatchLink.today(Store.shared)
        for m in t.meals { for f in m.foods { XCTAssertNotNil(UIImage(named: f.icon), "the watch has no icon \(f.icon) for \(f.name)") } }
        XCTAssertEqual(t.colours.accent.count, 6, "the accent as six hex digits")
    }

    func testAnswerWithAnEstimate() {
        let e = WatchEstimate(id: "x", name: "Flat white and banana", meal: "Snacks", kcal: 225, protein: 9, parts: [])
        let back = WatchCoding.value(WatchAnswer.self, WatchCoding.data(WatchAnswer(text: "About 225 kcal.", estimate: e)))
        XCTAssertEqual(back?.estimate?.meal, "Snacks")
    }
}
