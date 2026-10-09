import XCTest
@testable import CheatDays

/// The rules that keep logged food safe when the app and the website both change the same record.
@MainActor
final class StoreTests: XCTestCase {
    private let today = "2026-10-09"

    private func record() -> JSON {
        [
            "budget": 1650,
            "day": ["date": today, "items": [["id": "a1", "name": "Oats", "kcal": 320, "addedAt": "2026-10-09T07:30:00.000Z", "source": "manual"] as JSON], "workouts": [Any]()] as JSON,
            "history": [Any](),
            "recent": [Any](),
            "routines": [["id": "r1", "name": "Back & Biceps"] as JSON],   // something the native app doesn't touch
            "weighDays": [0, 3],
            "updatedAt": 1
        ]
    }

    private func item(_ id: String, _ name: String, _ kcal: Int) -> JSON {
        ["id": id, "name": name, "kcal": kcal, "source": "manual", "addedAt": ISO.now()]
    }

    func testAddKeepsWhatWasThere() {
        var d = record()
        Store.apply(["type": "add", "item": item("b2", "Banana", 95)], to: &d, today: today)
        let ids = list(dict(d["day"])["items"]).map { str($0["id"]) }
        XCTAssertEqual(ids, ["a1", "b2"])
        XCTAssertEqual(list(d["routines"]).count, 1, "fields the app doesn't know about pass through")
        XCTAssertEqual((d["weighDays"] as? [Int]) ?? [], [0, 3])
    }

    func testAddIsIdempotent() {
        var d = record()
        let op: JSON = ["type": "add", "item": item("b2", "Banana", 95)]
        Store.apply(op, to: &d, today: today)
        Store.apply(op, to: &d, today: today)
        XCTAssertEqual(list(dict(d["day"])["items"]).count, 2)
    }

    func testDeleteLeavesATombstoneSoItStaysDeleted() {
        var d = record()
        Store.apply(["type": "delete", "id": "a1", "at": nowMs()], to: &d, today: today)
        XCTAssertTrue(list(dict(d["day"])["items"]).isEmpty)
        XCTAssertNotNil(dict(d["tombs"])["item:a1"])
        // the same item arriving again from an older copy is not brought back
        Store.apply(["type": "add", "item": ["id": "a1", "name": "Oats", "kcal": 320] as JSON], to: &d, today: today)
        XCTAssertTrue(list(dict(d["day"])["items"]).isEmpty)
    }

    func testEditChangesAmountAndMeal() {
        var d = record()
        Store.apply(["type": "edit", "id": "a1", "kcal": 480, "shareLabel": "29% of the day", "meal": "Lunch"], to: &d, today: today)
        let it = list(dict(d["day"])["items"])[0]
        XCTAssertEqual(num(it["kcal"]), 480)
        XCTAssertEqual(str(it["meal"]), "Lunch")
    }

    func testNewDayFilesTheOldOneInHistory() {
        var d = record()
        Store.apply(["type": "add", "item": item("c3", "Toast", 200)], to: &d, today: "2026-10-10")
        let day = dict(d["day"])
        XCTAssertEqual(str(day["date"]), "2026-10-10")
        XCTAssertEqual(list(day["items"]).map { str($0["id"]) }, ["c3"])
        let filed = list(d["history"])
        XCTAssertEqual(filed.count, 1)
        XCTAssertEqual(str(filed[0]["date"]), today)
        XCTAssertEqual(num(filed[0]["kcal"]), 320)
        XCTAssertEqual(list(filed[0]["items"]).count, 1)
    }

    func testDayIsNotFiledTwice() {
        var d = record()
        d["history"] = [["date": today, "kcal": 320, "items": [Any]()] as JSON]
        Store.ensureDay(&d, today: "2026-10-10")
        XCTAssertEqual(list(d["history"]).count, 1)
    }

    func testRecentKeepsFifteenPlusFavourites() {
        var d = record()
        d["favs"] = ["food 0|": ["on": true, "at": "x"] as JSON]
        for i in 0..<20 { Store.apply(["type": "add", "item": item("x\(i)", "Food \(i)", 100 + i)], to: &d, today: today) }
        let recent = list(d["recent"])
        XCTAssertEqual(recent.count, 16, "15 recents plus the starred one")
        XCTAssertTrue(recent.contains { str($0["key"]) == "food 0|" }, "a favourite is never trimmed")
    }

    func testMealGuessing() {
        XCTAssertEqual(Meals.guess("Porridge with honey", hour: 8), "Breakfast")
        XCTAssertEqual(Meals.guess("Pizza", hour: 16), "Dinner")
        XCTAssertEqual(Meals.guess("Chicken wrap", hour: 13), "Lunch")
        XCTAssertEqual(Meals.guess("Crisps", hour: 23), "Snacks")
    }

    func testCountingPieces() {
        let timTam: JSON = ["name": "Tim Tam", "unit": "g", "kcalPer100": 518, "servingSize": 18, "kcalPerServing": 93, "unitLabel": "biscuit"]
        let c = FoodMath.conv(timTam)
        XCTAssertEqual(c.countKcal ?? 0, 93, accuracy: 0.01)
        XCTAssertEqual(c.countLabel, "biscuit")
        XCTAssertEqual(FoodMath.amountText(timTam, kcal: 186), "2 biscuits")
        XCTAssertEqual(Fmt.share(186, of: 1650), "11.3% of the day")
    }
}
