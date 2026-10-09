import XCTest
@testable import CheatDays

/// Workout plans: the split fits the days, kept routines get their gaps filled, weights go up only when earned, and the easier week comes round.
@MainActor
final class WorkoutPlanTests: XCTestCase {
    func testFourDaysIsUpperLower() {
        let p = WorkoutPlanner.build(goal: "muscle", days: 4, experience: "some", kit: "gym", minutes: 60, focus: ["Glutes"], keep: [], start: "2026-10-08")
        XCTAssertEqual(p.sessions.map(\.name), ["Upper", "Lower", "Upper", "Lower"])
        XCTAssertEqual(p.sessions.map(\.weekday), [1, 2, 4, 5])
        XCTAssertEqual(p.start, "2026-10-05")   // the Monday
        XCTAssertTrue(p.sessions[1].moves.contains { $0.exercise == "Hip thrust" })
        XCTAssertLessThanOrEqual(p.sessions[0].moves.count, 6)
    }

    func testKeptRoutinesGetTheGapsFilled() {
        let push: JSON = ["id": "r1", "name": "Push day", "exercises": [["exercise": "Bench press", "sets": 3, "reps": 8] as JSON, ["exercise": "Overhead press", "sets": 3, "reps": 10] as JSON]]
        let pull: JSON = ["id": "r2", "name": "Pull day", "exercises": [["exercise": "Barbell row", "sets": 3, "reps": 8] as JSON, ["exercise": "Lat pulldown", "sets": 3, "reps": 10] as JSON]]
        let p = WorkoutPlanner.build(goal: "muscle", days: 3, experience: "some", kit: "gym", minutes: 60, focus: [], keep: [push, pull], start: "2026-10-08")
        XCTAssertEqual(p.sessions.count, 3)
        XCTAssertEqual(p.sessions[0].name, "Push day")
        XCTAssertTrue(["Lower", "Legs"].contains(p.sessions[2].name), "the missing legs get a day")
    }

    func testWeightGoesUpOnlyWhenEveryRepIsThere() {
        let m = PlanMove(exercise: "Bench press", sets: 3, low: 6, high: 8)
        let up = Progression.target(m, last: [(8, 60), (8, 60), (8, 60)], deload: false)
        XCTAssertEqual(up.kg, 62.5); XCTAssertEqual(up.reps, 6); XCTAssertTrue(up.up)
        let stay = Progression.target(m, last: [(8, 60), (7, 60), (6, 60)], deload: false)
        XCTAssertEqual(stay.kg, 60); XCTAssertEqual(stay.reps, 7); XCTAssertFalse(stay.up)
        let easy = Progression.target(m, last: [(8, 60), (8, 60), (8, 60)], deload: true)
        XCTAssertEqual(easy.sets, 2); XCTAssertEqual(easy.kg, 55)
    }

    func testTheLastWeekOfTheBlockIsEasier() {
        let p = WorkoutPlan(goal: "muscle", experience: "some", kit: "gym", minutes: 60, focus: [], start: "2026-09-07", weeks: 6,
                            sessions: [PlanSession(weekday: 1, name: "Upper", moves: [])])
        XCTAssertEqual(p.week(on: "2026-09-09"), 1)
        XCTAssertEqual(p.week(on: "2026-10-12"), 6)
        XCTAssertTrue(p.isDeload(on: "2026-10-14"))
        XCTAssertEqual(p.week(on: "2026-10-19"), 1)
    }

    func testRedoingTheSignUpKeepsTheWorkoutPlan() {
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON, "budget": 1600]
        let plan = WorkoutPlanner.build(goal: "muscle", days: 2, experience: "new", kit: "dumbbells", minutes: 45, focus: [], keep: [], start: "2026-10-09")
        Store.apply(["type": "workoutPlan", "plan": plan.json], to: &d, today: "2026-10-09")
        Store.apply(["type": "plan", "budget": 1900, "prefs": ["loves": ["Pizza"]] as JSON], to: &d, today: "2026-10-09")
        XCTAssertEqual(WorkoutPlan(dict(d["prefs"])["workoutPlan"])?.sessions.count, 2)
    }
}
