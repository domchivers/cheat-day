import Foundation

/// Start running (25 Nov, design/start-running-mockup.html): run and walk, building to 30 minutes without stopping
/// over 8 weeks. Every run is a 5-minute walk, the week's run and walk turns, then a 5-minute walk. A week moves on
/// after three runs of it done to the end, so a missed week waits, and a hard one can be done again.
enum RunStart {
    static let tag = "start-running"
    static let runsPerWeek = 3, lastWeek = 8, warmUp = 300, coolDown = 300

    /// One stretch of a run: running or walking, for so many seconds.
    struct Part: Equatable { let run: Bool; let seconds: Int }

    /// Each week's middle: (run, walk) in seconds, over and over.
    private static let turns: [Int: [(Int, Int)]] = [
        1: Array(repeating: (60, 120), count: 6),
        2: Array(repeating: (90, 120), count: 6),
        3: Array(repeating: (120, 120), count: 5),
        4: Array(repeating: (180, 90), count: 5),
        5: Array(repeating: (300, 120), count: 3),
        6: Array(repeating: (480, 120), count: 3),
        7: [(900, 60), (600, 0)],
        8: [(1800, 0)],
    ]

    /// The whole run, warm-up to cool-down.
    static func parts(week: Int) -> [Part] {
        let w: Int = min(lastWeek, max(1, week))
        var out: [Part] = [Part(run: false, seconds: warmUp)]
        for t in turns[w] ?? [] {
            out.append(Part(run: true, seconds: t.0))
            if t.1 > 0 { out.append(Part(run: false, seconds: t.1)) }
        }
        // the last walk turn runs into the cool-down
        if let last = out.last, !last.run { out[out.count - 1] = Part(run: false, seconds: last.seconds + coolDown) }
        else { out.append(Part(run: false, seconds: coolDown)) }
        return out
    }

    static func seconds(week: Int) -> Int { parts(week: week).reduce(0) { $0 + $1.seconds } }
    static func minutes(week: Int) -> Int { Int((Double(seconds(week: week)) / 60).rounded()) }

    /// "Run 1½ min, walk 2 · six times"
    static func middle(week: Int) -> String {
        let w: Int = min(lastWeek, max(1, week))
        switch w {
        case 7: return "Run 15 min, walk 1, run 10"
        case 8: return "Run 30 min without stopping"
        default:
            let t: (Int, Int) = turns[w]?.first ?? (60, 120)
            let n: Int = turns[w]?.count ?? 0
            let times: String = ["", "once", "twice", "three times", "four times", "five times", "six times"][min(6, n)]
            return "Run \(clock(t.0)) min, walk \(clock(t.1)) · \(times)"
        }
    }

    /// 90 → "1½", 120 → "2"
    static func clock(_ s: Int) -> String {
        let m: Int = s / 60, half: Bool = s % 60 >= 30
        return half ? (m == 0 ? "½" : "\(m)½") : "\(m)"
    }

    /// mm:ss
    static func mmss(_ s: Int) -> String { String(format: "%d:%02d", max(0, s) / 60, max(0, s) % 60) }

    /// Runs done to the end, from logged workouts: the week they're on and which run of it is next.
    static func progress(done: Int) -> (week: Int, run: Int, finished: Bool) {
        let finished: Bool = done >= lastWeek * runsPerWeek
        if finished { return (lastWeek, runsPerWeek, true) }
        return (done / runsPerWeek + 1, done % runsPerWeek + 1, false)
    }

    /// The kcal of a run: the running at a run's rate and the walking at a walk's, each for what it was.
    static func kcal(runSeconds: Double, walkSeconds: Double, kg: Double) -> Double {
        let run: Double = (Activities.all.first { $0.name == "Run" }?.met ?? 9.8) * (Activities.effort["easy"] ?? 0.8)
        let walk: Double = Activities.all.first { $0.name == "Walk" }?.met ?? 3.5
        return ((run * runSeconds + walk * walkSeconds) * kg / 3600).rounded()
    }
}

extension Store {
    /// Start running runs done to the end, ever.
    var startRunsDone: Int {
        let all: [JSON] = todayWorkouts + allPastWorkouts.map { (p: (date: String, index: Int, workout: JSON)) -> JSON in p.workout }
        return all.filter { str($0["plan"]) == RunStart.tag && ($0["complete"] as? Bool) != false }.count
    }
    var startRun: (week: Int, run: Int, finished: Bool) { RunStart.progress(done: startRunsDone) }

    /// A Start running run, timed by the app: logged as a run, with what it was. A watch's copy of it from Apple
    /// Health that came in first goes, so it isn't counted twice.
    /// With a mapped route (25 Nov): its distance and each kilometre's time go in the record, the route itself only in
    /// a file on the phone (RouteStore), never in the account. Returns the workout's id.
    @discardableResult
    func logStartRun(week: Int, run: Int, runSeconds: Double, walkSeconds: Double, complete: Bool, route: [RoutePoint] = []) -> String {
        for w in todayWorkouts where str(w["from"]) == "health" && str(w["type"]) == "Run" {
            RouteStore.delete(str(w["id"])); deleteWorkout(str(w["id"]))
        }
        let minutes: Double = (runSeconds + walkSeconds) / 60
        let id: String = uid()
        var w: JSON = ["id": id, "type": "Run", "name": "Start running · week \(week), run \(run)", "minutes": Int(minutes.rounded()),
                       "effort": "easy", "kcal": RunStart.kcal(runSeconds: runSeconds, walkSeconds: walkSeconds, kg: weightKg),
                       "lifts": [Any](), "at": ISO.now(), "plan": RunStart.tag, "week": week, "complete": complete]
        let meters: Double = RouteMath.meters(route)
        if route.count > 1 && meters >= 50 {
            RouteStore.save(route, id: id)
            w["km"] = (meters / 10).rounded() / 100
            w["splits"] = RouteMath.splits(route).map { (s: (km: Double, seconds: Double)) -> JSON in ["km": (s.km * 100).rounded() / 100, "s": s.seconds.rounded()] }
        }
        perform(["type": "logWorkout", "workout": w])
        return id
    }
}
