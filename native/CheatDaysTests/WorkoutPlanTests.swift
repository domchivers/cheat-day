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

    /// 24 Nov, design/strong-steady-mockup.html: two short days at home, A and B, every move one a living room can do.
    func testStrongAndSteadyIsTwoGentleDaysAtHome() {
        let p = WorkoutPlanner.build(goal: "steady", days: 2, experience: "lots", kit: "none", minutes: 30, focus: ["Chest"], keep: [], start: "2026-11-24")
        XCTAssertEqual(p.sessions.map(\.name), ["Steady A", "Steady B"])
        XCTAssertEqual(p.sessions.map(\.weekday), [1, 4], "Monday and Thursday")
        XCTAssertEqual(p.experience, "new")
        XCTAssertEqual(p.sessions[0].moves.map(\.exercise), ["Sit to stand", "Wall push-up", "Step-up", "Heel raise", "Heel-to-toe walk"])
        XCTAssertEqual(p.sessions[1].moves.map(\.exercise), ["Glute bridge", "Bent-over row", "Side leg raise", "Bird dog"])
        for s in p.sessions { for m in s.moves {
            XCTAssertNotNil(Training.how(m.exercise, kit: "none"), m.exercise)
            XCTAssertNotNil(Muscles.group(m.exercise), m.exercise + " isn't in the library")
        } }
        // light dumbbells: a weight where it helps, and the first time it says to pick one
        let d = WorkoutPlanner.build(goal: "steady", days: 2, experience: "new", kit: "dumbbells", minutes: 30, focus: [], keep: [], start: "2026-11-24")
        XCTAssertEqual(d.sessions[1].moves.map(\.exercise), ["Glute bridge", "Dumbbell row", "Heel raise", "Dumbbell curl", "Side leg raise"])
        XCTAssertEqual(Training.how("Sit to stand", kit: "dumbbells"), "A dumbbell held at your chest")
        XCTAssertTrue(Progression.target(d.sessions[1].moves[3], last: nil, deload: false).hint.hasPrefix("New: pick a weight"))
        XCTAssertTrue(Progression.target(p.sessions[0].moves[0], last: nil, deload: false).hint.hasPrefix("New: aim for 8–12 reps"))
        // a band: band moves; and a band on a gym plan is bodyweight
        let b = WorkoutPlanner.build(goal: "steady", days: 3, experience: "new", kit: "band", minutes: 30, focus: [], keep: [], start: "2026-11-24")
        XCTAssertEqual(b.sessions.map(\.name), ["Steady A", "Steady B", "Steady A"])
        XCTAssertTrue(b.sessions[1].moves.map(\.exercise).contains("Band row"))
        XCTAssertEqual(WorkoutPlanner.build(goal: "muscle", days: 2, experience: "new", kit: "band", minutes: 45, focus: [], keep: [], start: "2026-11-24").kit, "none")
    }

    /// 25 Nov, design/plan-any-workout-mockup.html: a plan can be runs and classes with no weights at all, and keeps them.
    func testAPlanOfRunsAndYogaWithNoWeights() throws {
        let run = PlanActivity(type: "Run", days: [2, 6], minutes: 30, effort: "easy")
        let yoga = PlanActivity(type: "Yoga / stretch", days: [0], minutes: 45, effort: "moderate")
        let p = WorkoutPlan(goal: "fitness", experience: "some", kit: "none", minutes: 45, focus: [], start: "2026-11-23", sessions: [], activities: [run, yoga])
        let back = try XCTUnwrap(WorkoutPlan(p.json), "a plan with no sessions still reads back")
        XCTAssertEqual(back.activities, [run, yoga])
        XCTAssertEqual(back.title, "Run, yoga · 3 days")
        XCTAssertEqual(back.activities(on: "2026-11-24").map(\.type), ["Run"], "Tuesday")
        XCTAssertTrue(back.activities(on: "2026-11-25").isEmpty)
        XCTAssertEqual(back.nextDay(after: "2026-11-24")?.date, "2026-11-28", "Saturday's run is next")
        XCTAssertEqual(run.dayNames, "Tue and Sat")
        XCTAssertNil(WorkoutPlan(WorkoutPlan(goal: "fitness", experience: "some", kit: "none", minutes: 45, focus: [], start: "2026-11-23", sessions: []).json))
    }

    func testWeightsGoOnTheDaysPickedAndACoachSpotsClashes() {
        let p = WorkoutPlanner.build(goal: "muscle", days: 2, experience: "some", kit: "gym", minutes: 45, focus: [], keep: [], start: "2026-11-24", weekdays: [4, 1])
        XCTAssertEqual(p.sessions.map(\.weekday), [1, 4], "Monday and Thursday, Monday first")
        // a hard run the day after full body (legs in it): said once, with why
        let friday = PlanActivity(type: "Run", days: [5], minutes: 30, effort: "moderate")
        XCTAssertEqual(PlanKinds.tips(sessions: p.sessions, activities: [friday]).count, 1)
        XCTAssertTrue(PlanKinds.tips(sessions: p.sessions, activities: [PlanActivity(type: "Run", days: [6], minutes: 30, effort: "easy")]).isEmpty)
        // every day busy: a word about rest
        let daily = PlanActivity(type: "Yoga / stretch", days: [0, 2, 3, 5, 6], minutes: 20, effort: "easy")
        XCTAssertTrue(PlanKinds.tips(sessions: p.sessions, activities: [daily]).contains { $0.contains("rest day") })
        // new things go on free days, weekends first
        XCTAssertEqual(PlanKinds.freeDays(1, taken: [1, 4]), [6])
        XCTAssertEqual(PlanKinds.freeDays(2, taken: [1, 4, 6]), [2, 0])
        for k in PlanKinds.all { if let t = k.type { XCTAssertTrue(Activities.all.contains { $0.name == t }, t + " isn't an activity you can log") } }
    }
}
