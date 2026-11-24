import XCTest
@testable import CheatDays

/// Start running (25 Nov, design/start-running-mockup.html): 8 weeks of run and walk to 30 minutes without stopping.
@MainActor
final class RunStartTests: XCTestCase {
    func testEachWeekIsAWalkEitherSideOfItsTurns() {
        XCTAssertEqual(RunStart.minutes(week: 1), 28)
        XCTAssertEqual(RunStart.minutes(week: 2), 31, "the mockup's week 2")
        XCTAssertEqual(RunStart.parts(week: 2).filter(\.run).count, 6)
        XCTAssertEqual(RunStart.parts(week: 2).first, RunStart.Part(run: false, seconds: 300))
        XCTAssertEqual(RunStart.parts(week: 2).last, RunStart.Part(run: false, seconds: 420), "the last walk turn runs into the cool-down")
        XCTAssertEqual(RunStart.parts(week: 8), [RunStart.Part(run: false, seconds: 300), RunStart.Part(run: true, seconds: 1800), RunStart.Part(run: false, seconds: 300)])
        XCTAssertEqual(RunStart.parts(week: 7).filter(\.run).map(\.seconds), [900, 600])
        XCTAssertEqual(RunStart.parts(week: 99), RunStart.parts(week: 8))
        for w in 1...8 { XCTAssertFalse(RunStart.parts(week: w).contains { $0.seconds <= 0 }) }
    }

    func testTheWeeksSayWhatTheyAre() {
        XCTAssertEqual(RunStart.middle(week: 1), "Run 1 min, walk 2 · six times")
        XCTAssertEqual(RunStart.middle(week: 2), "Run 1½ min, walk 2 · six times")
        XCTAssertEqual(RunStart.middle(week: 4), "Run 3 min, walk 1½ · five times")
        XCTAssertEqual(RunStart.middle(week: 8), "Run 30 min without stopping")
        XCTAssertEqual(RunStart.mmss(90), "1:30")
    }

    func testAWeekMovesOnAfterThreeRunsDone() {
        XCTAssertEqual(RunStart.progress(done: 0).week, 1)
        XCTAssertEqual(RunStart.progress(done: 2).run, 3)
        XCTAssertEqual(RunStart.progress(done: 3).week, 2)
        XCTAssertEqual(RunStart.progress(done: 3).run, 1)
        XCTAssertFalse(RunStart.progress(done: 23).finished)
        XCTAssertTrue(RunStart.progress(done: 24).finished)
    }

    /// Running counted as an easy run and walking as walking: week 2 at 80 kg is about 200, not a 31-minute run's 320.
    func testTheKcalCountsTheWalkingAsWalking() {
        let k: Double = RunStart.kcal(runSeconds: 540, walkSeconds: 1320, kg: 80)
        XCTAssertEqual(k, 197, accuracy: 3)
    }

    func testAPlansRunCanBeStartRunning() throws {
        let a = PlanActivity(type: "Run", days: [2, 4, 6], minutes: 31, effort: "easy", aim: "start")
        XCTAssertTrue(a.startRunning)
        XCTAssertEqual(a.label, "Start running")
        let back = PlanActivity(a.json)
        XCTAssertEqual(back, a)
        XCTAssertFalse(PlanActivity(type: "Swim", days: [1], minutes: 30, effort: "easy", aim: "start").startRunning)
    }
}
