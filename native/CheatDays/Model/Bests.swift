import Foundation

/// Personal bests and weeks in a row (26 Nov, design/bests-weekgoal-mockup.html). Found from what's already saved:
/// a mapped run's or ride's fastest 1, 5, 10 (and 20) km from its route, and every run, ride, walk and hike's distance
/// and climb. Nothing to set up. The times are the workout's own clock, which pauses itself at the lights, as its splits.
struct BestDef: Identifiable {
    enum What { case fastest(Double), longest, climbed }
    let key: String
    let kind: MoveKind
    /// "5 km", "Longest ride"
    let title: String
    /// On a tile: "5 km run"
    let tile: String
    let what: What
    var id: String { key }

    var fastest: Double? { if case .fastest(let m) = what { return m } else { return nil } }

    static let all: [BestDef] = [
        BestDef(key: "run1k", kind: .run, title: "1 km", tile: "1 km run", what: .fastest(1000)),
        BestDef(key: "run5k", kind: .run, title: "5 km", tile: "5 km run", what: .fastest(5000)),
        BestDef(key: "run10k", kind: .run, title: "10 km", tile: "10 km run", what: .fastest(10000)),
        BestDef(key: "runLong", kind: .run, title: "Longest run", tile: "Longest run", what: .longest),
        BestDef(key: "ride10k", kind: .ride, title: "10 km", tile: "10 km ride", what: .fastest(10000)),
        BestDef(key: "ride20k", kind: .ride, title: "20 km", tile: "20 km ride", what: .fastest(20000)),
        BestDef(key: "rideLong", kind: .ride, title: "Longest ride", tile: "Longest ride", what: .longest),
        BestDef(key: "rideClimb", kind: .ride, title: "Most climbed", tile: "Ride climb", what: .climbed),
        BestDef(key: "walkLong", kind: .walk, title: "Longest walk", tile: "Longest walk", what: .longest),
        BestDef(key: "walkClimb", kind: .walk, title: "Most climbed", tile: "Walk climb", what: .climbed),
        BestDef(key: "hikeLong", kind: .hike, title: "Longest hike", tile: "Longest hike", what: .longest),
        BestDef(key: "hikeClimb", kind: .hike, title: "Most climbed", tile: "Hike climb", what: .climbed),
    ]

    /// Lower is better for a time; higher for a distance or a climb.
    func better(_ a: Double, than b: Double) -> Bool { fastest != nil ? a < b : a > b }

    /// "27:41", "42.3 km", "312 m"
    func text(_ v: Double) -> String {
        switch what {
        case .fastest: return Bests.time(v)
        case .longest: return String(format: "%.1f km", v)
        case .climbed: return "\(Int(v.rounded())) m"
        }
    }
}

/// One best: the value and the workout it came from.
struct BestEntry: Identifiable {
    let def: BestDef
    let value: Double
    let date: String
    let workout: JSON
    var id: String { def.key }
    var workoutId: String { str(workout["id"]) }
}

/// What a just-finished workout did against the bests before it.
struct BestNews: Identifiable {
    let def: BestDef
    let value: Double
    /// 1 for a new best, 2 for the second best.
    let place: Int
    /// The best it beat (a new best) or the one it's behind (second), if there was one.
    let other: BestEntry?
    var id: String { def.key }

    var headline: String { place == 1 ? "New best · \(def.title)" : "Your 2nd best \(def.tile.lowercased())" }

    /// "38 s faster than 28:19 on 3 Nov"
    var line: String? {
        guard let o = other else { return nil }
        let gap: Double = abs(value - o.value)
        let by: String
        switch def.what {
        case .fastest: by = (gap >= 60 ? Bests.time(gap) : "\(Int(gap.rounded())) s") + (place == 1 ? " faster than " : " behind ")
        case .longest: by = String(format: "%.1f km", gap) + (place == 1 ? " further than " : " short of ")
        case .climbed: by = "\(Int(gap.rounded())) m" + (place == 1 ? " more than " : " short of ")
        }
        return by + def.text(o.value) + " on " + Bests.day(o.date)
    }
}

enum Bests {
    /// The fastest stretch of this many metres along a route, in seconds of its clock; nil when it's not that long.
    /// A stretch that ends within RouteMath.wholeWithin of whole counts, its time scaled up to the whole distance.
    static func fastest(_ p: [RoutePoint], meters want: Double) -> Double? {
        guard p.count > 1, want > 0 else { return nil }
        // distance along the route at each point (nothing across a pause)
        var dist: [Double] = [0]
        dist.reserveCapacity(p.count)
        for i in 1..<p.count { dist.append(dist[i - 1] + (p[i].gap ? 0 : p[i].location.distance(from: p[i - 1].location))) }
        let target: Double = max(1, want - RouteMath.wholeWithin)
        guard let total = dist.last, total >= target else { return nil }
        var best: Double?
        var i: Int = 0
        for j in 1..<p.count where dist[j] >= target {
            // the latest start point that's still at least `target` back
            while i + 1 < j && dist[j] - dist[i + 1] >= target { i += 1 }
            // where exactly `target` back falls, between point i and i+1
            let at: Double = dist[j] - target
            let span: Double = dist[i + 1] - dist[i]
            let f: Double = span > 0 ? min(1, max(0, (at - dist[i]) / span)) : 0
            let tStart: Double = p[i].t + (p[i + 1].t - p[i].t) * f
            let secs: Double = (p[j].t - tStart) * want / target
            if secs > 0, best == nil || secs < best! { best = secs }
        }
        return best
    }

    /// Weeks in a row the workouts goal was hit. `counts` is workouts a week, this week first, back to the first week
    /// they used the app. This week counts once it's hit, and never breaks it while it's going. One week short in any
    /// four doesn't end it (a sick week, a holiday), as a rest day doesn't end the logging streak; it isn't counted.
    static func weeksInARow(goal: Int, counts: [Int]) -> Int {
        guard goal > 0, !counts.isEmpty else { return 0 }
        var weeks: Int = counts[0] >= goal ? 1 : 0
        var lastShort: Int?   // index of the last week let off
        var i: Int = 1
        while i < counts.count {
            if counts[i] >= goal { weeks += 1 }
            else if weeks > 0 || i == 1, lastShort.map({ i - $0 >= 4 }) ?? true, i + 1 < counts.count, counts[i + 1] >= goal {
                lastShort = i   // let off: the week before it was hit, and none let off in the four before
            } else { break }
            i += 1
        }
        return weeks
    }

    /// "27:41", or "1:02:15" past the hour.
    static func time(_ s: Double) -> String {
        let r: Int = Int(s.rounded())
        return r >= 3600 ? String(format: "%d:%02d:%02d", r / 3600, r / 60 % 60, r % 60) : String(format: "%d:%02d", r / 60, r % 60)
    }

    private static let shortDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.dateFormat = "d MMM"; return f
    }()
    private static let key: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    /// "3 Nov", "Today"
    static func day(_ date: String) -> String {
        if date == key.string(from: Date()) { return "Today" }
        guard let d = key.date(from: date) else { return date }
        return shortDay.string(from: d)
    }

    /// Fastest times found in each workout's route, kept on the phone so a route is read once.
    private static var cache: [String: [String: Double]] = UserDefaults.standard.dictionary(forKey: "bests.efforts") as? [String: [String: Double]] ?? [:]
    private static func keep() { UserDefaults.standard.set(cache, forKey: "bests.efforts") }

    /// A route's fastest stretches for its kind.
    static func efforts(_ route: [RoutePoint], kind: MoveKind) -> [String: Double] {
        var out: [String: Double] = [:]
        for d in BestDef.all where d.kind == kind {
            if let m = d.fastest, let s = fastest(route, meters: m) { out[d.key] = (s * 10).rounded() / 10 }
        }
        return out
    }

    /// The kind of a run, ride, walk or hike; nil for anything else.
    static func kind(_ w: JSON) -> MoveKind? { MoveKind.allCases.first { $0.type == str(w["type"]) } }

    /// A workout's value for each best it can have.
    static func values(_ w: JSON) -> [String: Double] {
        guard let mk = Bests.kind(w) else { return [:] }
        var out: [String: Double] = [:]
        let id: String = str(w["id"])
        if let km = num(w["km"]), km > 0 { out[mk.rawValue + "Long"] = km }
        if let up = num(w["climb"]), up >= 1 { out[mk.rawValue + "Climb"] = up }
        if mk == .run || mk == .ride, !id.isEmpty {
            if let e = cache[id] { out.merge(e) { a, _ in a } }
            else {
                // (none without a route, as a watch's own: kept as none, so it isn't looked for again)
                let e: [String: Double] = RouteStore.load(id).map { Bests.efforts($0, kind: mk) } ?? [:]
                cache[id] = e; keep()
                out.merge(e) { a, _ in a }
            }
        }
        return out.filter { k, _ in BestDef.all.contains { $0.key == k } }
    }

    /// Workouts holding a best right now: their rows get a medal.
    static var holders: Set<String> = []
}

extension Store {
    /// Every run, ride, walk and hike, with its day: today's and all before.
    private var moves: [(date: String, workout: JSON)] {
        let now: String = today
        var out: [(date: String, workout: JSON)] = todayWorkouts.map { (w: JSON) -> (date: String, workout: JSON) in (now, w) }
        out += allPastWorkouts.map { (p: (date: String, index: Int, workout: JSON)) -> (date: String, workout: JSON) in (p.date, p.workout) }
        return out.filter { (m: (date: String, workout: JSON)) -> Bool in Bests.kind(m.workout) != nil }
    }

    /// The best for each one there's a value for; an earlier one keeps it on a tie. `leaving` leaves a workout out.
    func bests(leaving id: String? = nil) -> [String: BestEntry] {
        var out: [String: BestEntry] = [:]
        for m in moves.sorted(by: { $0.date < $1.date }) where id == nil || str(m.workout["id"]) != id {
            for (k, v) in Bests.values(m.workout) {
                guard let def = BestDef.all.first(where: { $0.key == k }) else { continue }
                if let have = out[k], !def.better(v, than: have.value) { continue }
                out[k] = BestEntry(def: def, value: v, date: m.date, workout: m.workout)
            }
        }
        if id == nil { Bests.holders = Set(out.values.map(\.workoutId)) }
        return out
    }

    /// What a workout just saved did: a new best, or the second best, for each it has a value for.
    func bestNews(for id: String) -> [BestNews] {
        guard let w = todayWorkouts.first(where: { str($0["id"]) == id }) else { return [] }
        let before: [String: BestEntry] = bests(leaving: id)
        var news: [BestNews] = []
        for (k, v) in Bests.values(w) {
            guard let def = BestDef.all.first(where: { $0.key == k }) else { continue }
            // (a first time is a best by default: not news, or a first run would be "first longest run" and the rest)
            guard let have = before[k] else { continue }
            if def.better(v, than: have.value) { news.append(BestNews(def: def, value: v, place: 1, other: have)); continue }
            // second: better than every other there's been for it
            let rest: [Double] = moves.filter { str($0.workout["id"]) != id && str($0.workout["id"]) != have.workoutId }
                .compactMap { Bests.values($0.workout)[k] }
            if def.fastest != nil, rest.allSatisfy({ def.better(v, than: $0) }) { news.append(BestNews(def: def, value: v, place: 2, other: have)) }
        }
        // new bests first, then by the list's order
        let order: [String] = BestDef.all.map(\.key)
        return news.sorted { ($0.place, order.firstIndex(of: $0.def.key) ?? 0) < ($1.place, order.firstIndex(of: $1.def.key) ?? 0) }
    }

    /// The workouts goal (Goals' weekly targets): 0 when it's off.
    var workoutsGoal: Int { weekGoals["workouts"] ?? 0 }

    /// Workouts a week, this week first, back to the first week there's anything saved.
    var workoutsByWeek: [Int] {
        var byDate: [String: Int] = [:]
        for h in list(doc["history"]) { byDate[str(h["date"]), default: 0] += list(h["workouts"]).count }
        if str(day["date"]) != today { byDate[str(day["date"]), default: 0] += list(day["workouts"]).count }
        byDate[today] = todayWorkouts.count
        guard let first = byDate.keys.filter({ !$0.isEmpty }).min() else { return [todayWorkouts.count] }
        var out: [Int] = []
        var mon: String = WorkoutPlan.monday(today)
        while out.count < 520 {
            out.append((0..<7).reduce(0) { $0 + (byDate[DayKey.shift(mon, days: $1)] ?? 0) })
            if mon <= first { break }
            mon = DayKey.shift(mon, days: -7)
        }
        return out
    }

    var weeksInARow: Int { Bests.weeksInARow(goal: workoutsGoal, counts: workoutsByWeek) }
}
