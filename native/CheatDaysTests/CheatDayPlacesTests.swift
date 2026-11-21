import XCTest
@testable import CheatDays

/// A place on the cheat day (21 Nov, design/cheat-day-planner-mockup.html): the takeaway planner's order as a slot,
/// kept as the menu made it when the planner rewrites the day.
final class CheatDayPlacesTests: XCTestCase {
    private let bowl = Takeaway.Item(name: "Beef Bulgogi Bibimbap", kind: "main", tier: "none", kcal: 790, p: 38, c: 100, f: 26)
    private let chicken = Takeaway.Item(name: "Small Fried Boneless Chicken", kind: "main", tier: "none", kcal: 1080, p: 76, c: 50, f: 64)

    func testAnOrderAsASlot() throws {
        let card = Takeaway.json(Takeaway.Combo(dishes: [(bowl, 1), (chicken, 0.5)]), note: "Best fit", restaurant: "PUBCHA", kcal: 1400)
        let s = CheatPlan.slot(card, place: "PUBCHA", tips: ["Original is the lightest flavour."], time: "19:00")
        XCTAssertEqual(str(s["title"]), "PUBCHA"); XCTAssertEqual(str(s["place"]), "PUBCHA")
        XCTAssertEqual(str(s["detail"]), "Beef Bulgogi Bibimbap\n½ Small Fried Boneless Chicken")
        XCTAssertEqual(num(s["kcal"]), 1330); XCTAssertEqual(num(s["protein"]), 76)
        XCTAssertEqual(num(s["carbs"]) ?? 0, 125, accuracy: 1); XCTAssertEqual(num(s["fat"]) ?? 0, 58, accuracy: 1)
        XCTAssertNotNil(s["kcalLo"], "guessed: a range")
        let parts = list(s["parts"])
        XCTAssertEqual(parts.count, 2); XCTAssertEqual(num(parts[1]["share"]), 0.5)
        XCTAssertEqual(parts.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, 1330, accuracy: 1, "its parts add up to it")
    }

    func testThePlannersRewriteKeepsThePlace() {
        let card = Takeaway.json(Takeaway.Combo(dishes: [(bowl, 1)]), note: "", restaurant: "PUBCHA", kcal: 1400)
        let place = CheatPlan.slot(card, place: "PUBCHA", tips: [], time: "19:00")
        let mango: JSON = ["time": "21:15", "title": "Mango bingsu", "kcal": 470, "protein": 9]
        // the planner gave the place back with its own numbers and a later time
        let rewrite: [JSON] = [["time": "19:30", "title": "PUBCHA", "kcal": 900, "protein": 20], mango]
        let out = CheatPlan.keepingPlaces(rewrite, from: [place, mango])
        XCTAssertEqual(num(out[0]["kcal"]), 790, "the menu's numbers, not the planner's")
        XCTAssertEqual(str(out[0]["time"]), "19:30", "the planner's time")
        XCTAssertEqual(str(out[1]["title"]), "Mango bingsu")
    }

    func testWhenItGoesIn() {
        XCTAssertEqual(CheatDayView.time(for: "PUBCHA for lunch", isToday: false), "12:30")
        XCTAssertEqual(CheatDayView.time(for: "PUBCHA", isToday: false), "19:00")
    }
}
