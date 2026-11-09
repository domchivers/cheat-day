import XCTest
@testable import CheatDays

/// Foods added together show as one dish on Today; foods added one at a time stay rows of their own.
final class DishesTests: XCTestCase {
    private func food(_ id: String, _ name: String, at seconds: Double, dish: String? = nil, dishName: String? = nil, undished: Bool = false) -> JSON {
        var f: JSON = ["id": id, "name": name, "kcal": 10, "meal": "Dinner", "addedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 + seconds))]
        if let dish { f["dish"] = dish; f["dishName"] = dishName ?? "" }
        if undished { f["undished"] = true }
        return f
    }

    /// The owner's dinner: nine foods from one edit card, tagged, become one "Chicken udon salad" row.
    func testTaggedFoodsAreOneDish() {
        let items = (0..<9).map { food("f\($0)", "Food \($0)", at: Double($0) * 0.01, dish: "d1", dishName: "Chicken udon salad") } + [food("x", "Apple", at: 600)]
        let rows = Dishes.rows(items, meal: "Dinner")
        XCTAssertEqual(rows.count, 2)
        guard case .dish(let d) = rows[0] else { return XCTFail("the dish first, where its first food was") }
        XCTAssertEqual(d.name, "Chicken udon salad"); XCTAssertEqual(d.items.count, 9); XCTAssertEqual(d.kcal, 90)
        guard case .food(let f) = rows[1] else { return XCTFail() }
        XCTAssertEqual(str(f["name"]), "Apple")
    }

    /// From before tags: three or more added within two seconds are one tap's worth, named after the meal.
    func testFoodsAddedTogetherBeforeTagsAreADish() {
        let items = [food("a", "Chicken", at: 0), food("b", "Cabbage", at: 0.2), food("c", "Carrot", at: 0.4), food("d", "Crumpet", at: 3600)]
        let rows = Dishes.rows(items, meal: "Dinner")
        XCTAssertEqual(rows.count, 2)
        guard case .dish(let d) = rows[0] else { return XCTFail() }
        XCTAssertEqual(d.name, "Dinner · 3 foods")
        // two at once is just two foods, and split ones stay apart
        XCTAssertEqual(Dishes.rows([food("a", "A", at: 0), food("b", "B", at: 0.1)], meal: "Dinner").count, 2)
        XCTAssertEqual(Dishes.rows([food("a", "A", at: 0, undished: true), food("b", "B", at: 0.1, undished: true), food("c", "C", at: 0.2, undished: true)], meal: "Dinner").count, 3)
    }

    /// A dish down to one food (the rest deleted) is just that food.
    func testOneLeftIsAFood() {
        let rows = Dishes.rows([food("a", "Chicken", at: 0, dish: "d1", dishName: "Salad")], meal: "Dinner")
        guard case .food = rows.first else { return XCTFail() }
    }

    /// Rename gives a time-grouped dish a tag; Split takes it off and keeps the foods apart for good.
    func testRenameAndSplit() {
        var items = [food("a", "A", at: 0), food("b", "B", at: 0.1), food("c", "C", at: 0.2)]
        Store.renameDish(&items, ids: ["a", "b", "c"], name: "Stir fry")
        XCTAssertEqual(Set(items.map { str($0["dish"]) }), ["a"])
        guard case .dish(let d) = Dishes.rows(items, meal: "Dinner").first else { return XCTFail() }
        XCTAssertEqual(d.name, "Stir fry")
        Store.renameDish(&items, ids: ["a", "b", "c"], name: nil)
        XCTAssertEqual(Dishes.rows(items, meal: "Dinner").count, 3)
    }
}
