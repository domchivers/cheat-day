import XCTest
@testable import CheatDays

/// Workouts are stored in the web app's shapes; these check the native side writes them the same way.
@MainActor
final class WorkoutTests: XCTestCase {
    private let today = "2026-10-09"

    private func record() -> JSON {
        ["budget": 1650, "weightKg": 80,
         "day": ["date": today, "items": [Any](), "workouts": [Any]()] as JSON,
         "session": ["startedAt": 1_791_506_926_196, "name": "Back", "routineId": NSNull(), "restUntil": NSNull(),
                     "exercises": [["exercise": "Lat pulldown", "sets": [["reps": 10, "kg": 93, "done": true, "pb": false] as JSON] as [Any]] as JSON] as [Any]] as JSON,
         "exercises": ["lat pulldown": ["name": "Lat pulldown", "best1rm": 124, "bestSet": ["kg": 93, "reps": 10] as JSON] as JSON] as JSON,
         "recentWorkouts": [Any](), "routines": [Any](), "updatedAt": 1]
    }

    func testSessionReadsAndWritesTheWebShape() {
        let s = LiveSession(record()["session"])
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.name, "Back")
        XCTAssertEqual(s?.exercises.first?.name, "Lat pulldown")
        XCTAssertEqual(s?.exercises.first?.sets.first?.kg, 93)
        XCTAssertEqual(s?.setsDone, 1)
        let back = s!.json
        XCTAssertEqual(num(back["startedAt"]), 1_791_506_926_196)
        XCTAssertTrue(back["routineId"] is NSNull)
        let sets = list(list(back["exercises"])[0]["sets"])
        XCTAssertEqual(sets[0]["done"] as? Bool, true)
    }

    func testLoggingAWorkoutUpdatesRecordsAndClearsTheSession() {
        var d = record()
        let w: JSON = ["id": "w1", "type": "Gym weights", "name": "Back", "minutes": 45, "effort": "moderate", "kcal": 300,
                       "lifts": [["exercise": "Lat pulldown", "sets": 1, "reps": 10, "kg": 95, "detail": [["reps": 10, "kg": 95] as JSON] as [Any]] as JSON] as [Any]]
        Store.apply(["type": "logWorkout", "workout": w, "clearSession": true], to: &d, today: today)
        XCTAssertTrue(d["session"] is NSNull)
        XCTAssertEqual(list(dict(d["day"])["workouts"]).map { str($0["id"]) }, ["w1"])
        let rec = dict(dict(d["exercises"])["lat pulldown"])
        XCTAssertEqual(num(rec["best1rm"]), 127, "95 kg × 10 is a new best")
        XCTAssertEqual(num(dict(rec["bestSet"])["kg"]), 95)
        XCTAssertEqual(num(d["pbCount"]), 1)
        XCTAssertEqual(str(list(d["recentWorkouts"]).first?["key"]), "gym weights|back")
        // logging the same workout again changes nothing
        Store.apply(["type": "logWorkout", "workout": w], to: &d, today: today)
        XCTAssertEqual(list(dict(d["day"])["workouts"]).count, 1)
    }

    func testDeletedWorkoutStaysDeleted() {
        var d = record()
        let w: JSON = ["id": "w2", "type": "Walk", "name": "Walk", "minutes": 30, "kcal": 140, "lifts": [Any]()]
        Store.apply(["type": "logWorkout", "workout": w], to: &d, today: today)
        Store.apply(["type": "deleteWorkout", "id": "w2", "at": nowMs()], to: &d, today: today)
        Store.apply(["type": "logWorkout", "workout": w], to: &d, today: today)
        XCTAssertTrue(list(dict(d["day"])["workouts"]).isEmpty)
    }

    func testRoutineWithTheSameNameIsReplaced() {
        var d = record()
        Store.apply(["type": "routine", "routine": ["id": "r1", "name": "Legs", "exercises": [Any]()] as JSON], to: &d, today: today)
        Store.apply(["type": "routine", "routine": ["id": "r2", "name": "legs", "exercises": [Any]()] as JSON], to: &d, today: today)
        XCTAssertEqual(list(d["routines"]).map { str($0["id"]) }, ["r2"])
    }

    func testOnlyKnownSettingsCanBeSet() {
        var d = record()
        Store.apply(["type": "set", "key": "weighDays", "value": [1, 4]], to: &d, today: today)
        Store.apply(["type": "set", "key": "budget", "value": 99], to: &d, today: today)
        XCTAssertEqual((d["weighDays"] as? [Int]) ?? [], [1, 4])
        XCTAssertNil(d["budget"].flatMap { num($0) == 99 ? $0 : nil }, "the budget isn't a setting this operation may change")
    }

    func testOneRepMaxEstimate() {
        XCTAssertEqual(Store.est(kg: 100, reps: 5), 117)
        XCTAssertEqual(Store.est(kg: 0, reps: 12), 0)
    }
}
