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

    func testRoutineChangesAreTheBigOnesOnly() {
        let routine: JSON = ["id": "r1", "name": "Chest", "exercises": [
            ["exercise": "Bench press", "sets": 3, "reps": 8, "kg": 80] as JSON,
            ["exercise": "Flyes", "sets": 3, "reps": 12, "kg": 20] as JSON]]
        let s = LiveSession(startedAt: 0, name: "Chest", routineId: "r1", exercises: [
            LiveExercise(name: "Bench press", sets: (0..<4).map { _ in LiveSet(reps: 6, kg: 85, done: true) }),
            LiveExercise(name: "Incline press", sets: (0..<3).map { _ in LiveSet(reps: 10, kg: 60) })])
        let ex = Store.routineExercises(s)
        XCTAssertEqual(ex.map { str($0["exercise"]) }, ["Bench press", "Incline press"])
        XCTAssertEqual(num(ex[0]["kg"]), 85)
        XCTAssertEqual(Store.routineChanges(from: routine, to: ex, name: "Chest"),
                       ["Added Incline press", "Dropped Flyes", "Bench press: 4 sets (was 3)"])
        // heavier and fewer reps on the same plan is no change: the routine just keeps up
        let same = LiveSession(startedAt: 0, name: "Chest", routineId: "r1", exercises: [
            LiveExercise(name: "Bench press", sets: (0..<3).map { _ in LiveSet(reps: 6, kg: 90) }),
            LiveExercise(name: "flyes", sets: (0..<3).map { _ in LiveSet(reps: 12, kg: 22) })])
        XCTAssertEqual(Store.routineChanges(from: routine, to: Store.routineExercises(same), name: "Chest"), [])
        XCTAssertEqual(Store.routineChanges(from: routine, to: Store.routineExercises(same), name: "Push day"), ["Renamed to Push day"])
    }

    func testUpdatingARoutineKeepsItsPlaceAndId() {
        var d = record()
        d["routines"] = [["id": "r1", "name": "Chest", "exercises": [Any]()] as JSON, ["id": "r2", "name": "Legs", "exercises": [Any]()] as JSON]
        Store.apply(["type": "updateRoutine", "routine": ["id": "r1", "name": "Chest and tris", "exercises": [["exercise": "Dips", "sets": 3] as JSON]] as JSON], to: &d, today: today)
        let rs = list(d["routines"])
        XCTAssertEqual(rs.map { str($0["id"]) }, ["r1", "r2"])
        XCTAssertEqual(str(rs[0]["name"]), "Chest and tris")
        XCTAssertEqual(list(rs[0]["exercises"]).count, 1)
    }

    func testOneRepMaxEstimate() {
        XCTAssertEqual(Store.est(kg: 100, reps: 5), 117)
        XCTAssertEqual(Store.est(kg: 0, reps: 12), 0)
    }

    func testALateFinishCountsOnTheDayItStarted() {
        var d: JSON = ["budget": 2000, "day": ["date": "2026-10-31", "items": [Any](), "workouts": [Any]()] as JSON,
                       "history": [["date": "2026-10-30", "budget": 2000, "kcal": 1500, "items": [Any](), "workouts": [Any]()] as JSON, ["date": "2026-10-28", "budget": 2000, "kcal": 1800] as JSON]]
        let w: JSON = ["id": "w1", "type": "Gym weights", "name": "Legs", "minutes": 60, "kcal": 300, "lifts": [Any]()]
        Store.apply(["type": "logWorkout", "workout": w, "date": "2026-10-30", "clearSession": true], to: &d, today: "2026-10-31")
        Store.apply(["type": "logWorkout", "workout": w, "date": "2026-10-30"], to: &d, today: "2026-10-31")   // a retry: still once
        XCTAssertTrue(list(dict(d["day"])["workouts"]).isEmpty)
        XCTAssertEqual(list(list(d["history"])[0]["workouts"]).count, 1)
        XCTAssertEqual(num(list(d["history"])[0]["burned"]), 300)
        // a day with nothing logged is made, in order
        Store.apply(["type": "logWorkout", "workout": ["id": "w2", "name": "Run", "kcal": 200, "lifts": [Any]()] as JSON, "date": "2026-10-29"], to: &d, today: "2026-10-31")
        XCTAssertEqual(list(d["history"]).map { str($0["date"]) }, ["2026-10-30", "2026-10-29", "2026-10-28"])
        // and it can be deleted from there
        Store.apply(["type": "deleteWorkout", "id": "w1", "at": 5], to: &d, today: "2026-10-31")
        XCTAssertTrue(list(list(d["history"])[0]["workouts"]).isEmpty)
        XCTAssertEqual(num(list(d["history"])[0]["burned"]), 0)
    }

    func testAFinishedSessionCantComeBack() {
        var d: JSON = ["day": ["date": "2026-10-31", "items": [Any](), "workouts": [Any]()] as JSON]
        let live: JSON = ["startedAt": 1000, "name": "Back"]
        Store.apply(["type": "session", "session": live], to: &d, today: "2026-10-31")
        Store.apply(["type": "logWorkout", "workout": ["id": "w1", "name": "Back", "kcal": 300, "lifts": [Any]()] as JSON, "clearSession": true, "sessionStart": 1000], to: &d, today: "2026-10-31")
        XCTAssertNotNil(dict(d["tombs"])["session:1000"])
        // a late save of the same session doesn't reopen it
        Store.apply(["type": "session", "session": live], to: &d, today: "2026-10-31")
        XCTAssertTrue(d["session"] is NSNull)
    }

    func testACorrectedFoodStaysOff() {
        var d: JSON = ["tombs": ["food:2026-10-30|low cal protein brownie|343": 1] as JSON, "day": ["date": "2026-10-31", "items": [Any]()] as JSON,
                       "history": [["date": "2026-10-30", "kcal": 683, "items": [["name": "Low Cal Protein Brownie", "kcal": 343] as JSON, ["name": "Low Cal Protein Brownie", "kcal": 340] as JSON]] as JSON]]
        Store.dropCorrectedFood(&d)
        XCTAssertEqual(num(list(d["history"])[0]["kcal"]), 340)
        XCTAssertEqual(list(list(d["history"])[0]["items"]).count, 1)
    }
}
