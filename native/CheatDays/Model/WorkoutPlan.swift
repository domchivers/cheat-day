import Foundation

/// One exercise in a plan: how many sets, and the rep range to work in.
struct PlanMove: Identifiable, Equatable {
    var id = UUID()
    var exercise: String
    var sets: Int
    var low: Int
    var high: Int

    init(exercise: String, sets: Int, low: Int, high: Int) {
        self.exercise = exercise; self.sets = sets; self.low = low; self.high = max(low, high)
    }
    init(_ j: JSON) {
        exercise = str(j["exercise"])
        sets = Int(num(j["sets"]) ?? 3)
        low = Int(num(j["low"]) ?? 8)
        high = max(low, Int(num(j["high"]) ?? Double(low + 2)))
    }
    var json: JSON { ["exercise": exercise, "sets": sets, "low": low, "high": high] }
}

/// One training day in the week.
struct PlanSession: Identifiable, Equatable {
    var id: String
    var weekday: Int          // 0 Sunday … 6 Saturday
    var name: String
    var moves: [PlanMove]

    init(id: String = uid(), weekday: Int, name: String, moves: [PlanMove]) {
        self.id = id; self.weekday = weekday; self.name = name; self.moves = moves
    }
    init(_ j: JSON) {
        id = str(j["id"]).isEmpty ? uid() : str(j["id"])
        weekday = Int(num(j["weekday"]) ?? 1)
        name = str(j["name"])
        moves = list(j["moves"]).map(PlanMove.init)
    }
    var json: JSON { ["id": id, "weekday": weekday, "name": name, "moves": moves.map(\.json)] }
    var minutes: Int { max(15, Int((Double(moves.reduce(0) { $0 + $1.sets }) * 2.6).rounded() / 5) * 5) }
}

/// A training week that repeats in blocks; the last week of each block is an easier one.
struct WorkoutPlan: Equatable {
    var goal = "muscle"        // muscle, strength, fitness
    var experience = "some"
    var kit = "gym"
    var minutes = 60
    var focus: [String] = []
    var start: String          // the Monday of week 1
    var weeks = 6
    var sessions: [PlanSession]

    init(goal: String, experience: String, kit: String, minutes: Int, focus: [String], start: String, weeks: Int = 6, sessions: [PlanSession]) {
        self.goal = goal; self.experience = experience; self.kit = kit; self.minutes = minutes; self.focus = focus
        self.start = start; self.weeks = weeks; self.sessions = sessions
        sort()
    }

    init?(_ any: Any?) {
        guard let j = any as? JSON, !list(j["sessions"]).isEmpty else { return nil }
        goal = str(j["goal"]).isEmpty ? "muscle" : str(j["goal"])
        experience = str(j["experience"]).isEmpty ? "some" : str(j["experience"])
        kit = str(j["kit"]).isEmpty ? "gym" : str(j["kit"])
        minutes = Int(num(j["minutes"]) ?? 60)
        focus = j["focus"] as? [String] ?? []
        start = str(j["start"])
        weeks = max(2, Int(num(j["weeks"]) ?? 6))
        sessions = list(j["sessions"]).map(PlanSession.init)
        sort()
    }

    var json: JSON {
        ["goal": goal, "experience": experience, "kit": kit, "minutes": minutes, "focus": focus, "start": start, "weeks": weeks,
         "sessions": sessions.map(\.json), "updatedAt": ISO.now()]
    }

    /// Monday first, Sunday last.
    mutating func sort() { sessions.sort { ($0.weekday + 6) % 7 < ($1.weekday + 6) % 7 } }

    static func monday(_ date: String) -> String { DayKey.shift(date, days: -((DayKey.weekday(date) + 6) % 7)) }

    func week(on date: String) -> Int {
        let days = Calendar.current.dateComponents([.day], from: DayKey.date(start), to: DayKey.date(Self.monday(date))).day ?? 0
        return days < 0 ? 1 : (days / 7) % weeks + 1
    }
    func isDeload(on date: String) -> Bool { weeks >= 4 && week(on: date) == weeks }
    func session(on date: String) -> PlanSession? { sessions.first { $0.weekday == DayKey.weekday(date) } }
    func next(after date: String) -> (date: String, session: PlanSession)? {
        for i in 1...7 { let d = DayKey.shift(date, days: i); if let s = session(on: d) { return (d, s) } }
        return nil
    }

    var title: String {
        var seen = Set<String>(), names: [String] = []
        for s in sessions {
            let n = s.name.replacingOccurrences(of: " A", with: "").replacingOccurrences(of: " B", with: "")
            if seen.insert(n).inserted { names.append(n) }
        }
        return names.prefix(3).joined(separator: " / ") + ", \(sessions.count) day\(sessions.count == 1 ? "" : "s")"
    }

    /// Planned hard sets a week for each muscle.
    var volume: [String: Int] { WorkoutPlanner.volume(sessions) }
}

/// Which muscle an exercise trains, and how many hard sets a week to aim for.
enum Muscles {
    static let shown = ["Chest", "Back", "Shoulders", "Arms", "Legs", "Core"]
    static func group(_ name: String) -> String? {
        let n = name.lowercased()
        return ExerciseLibrary.groups.first { $0.1.contains { $0.lowercased() == n } }?.0
    }
    /// About 10 a week to start, 14 with some experience, 18 for the experienced; arms and core get a lot from the big lifts.
    static func target(_ group: String, experience: String) -> Int {
        let base = experience == "new" ? 10 : experience == "lots" ? 18 : 14
        return group == "Arms" || group == "Core" ? Int(Double(base) * 0.6) : base
    }
}

/// Builds a plan: a split for the days they have, rep ranges for the goal, trimmed to the time they've got,
/// extra work for the muscles they want more of, and their own routines kept in with the gaps filled.
enum WorkoutPlanner {
    static let maxMoves = [30: 4, 45: 5, 60: 6, 75: 8]
    static let focusOptions = ["Glutes", "Legs", "Chest", "Back", "Shoulders", "Arms", "Core"]
    private static let lowerDays = ["Lower", "Legs", "Full body A", "Full body B"]
    private static let upperDays = ["Upper", "Push", "Pull", "Full body A", "Full body B"]
    private static let focusMoves: [String: (String, [String])] = [
        "Glutes": ("Hip thrust", lowerDays), "Legs": ("Leg extension", lowerDays), "Core": ("Hanging leg raise", lowerDays),
        "Chest": ("Incline dumbbell press", ["Upper", "Push", "Full body A", "Full body B"]),
        "Back": ("Seated cable row", ["Upper", "Pull", "Full body A", "Full body B"]),
        "Shoulders": ("Lateral raise", ["Upper", "Push", "Full body A", "Full body B"]),
        "Arms": ("Dumbbell curl", upperDays)
    ]

    static func ranges(goal: String, compound: Bool) -> (Int, Int) {
        switch goal {
        case "strength": return compound ? (3, 6) : (8, 12)
        case "fitness": return compound ? (8, 12) : (12, 15)
        default: return compound ? (6, 10) : (10, 15)
        }
    }

    static func session(_ template: String, goal: String, experience: String, kit: String, minutes: Int, focus: [String]) -> PlanSession {
        var moves = Training.moves(template, experience: experience, kit: kit).enumerated().map { pair -> PlanMove in
            let r = ranges(goal: goal, compound: pair.offset < 2)
            let sets = goal == "strength" && pair.offset < 2 ? pair.element.sets + 1 : goal == "fitness" ? min(3, pair.element.sets) : pair.element.sets
            return PlanMove(exercise: pair.element.name, sets: sets, low: r.0, high: r.1)
        }
        let cap = maxMoves[minutes] ?? 6
        if moves.count > cap { moves = Array(moves.prefix(cap)) }
        for f in focus {
            guard let fm = focusMoves[f], fm.1.contains(template) else { continue }
            let n = Training.swap(fm.0, kit: kit)
            if !moves.contains(where: { $0.exercise == n }) { let r = ranges(goal: goal, compound: false); moves.append(PlanMove(exercise: n, sets: 3, low: r.0, high: r.1)) }
        }
        return PlanSession(weekday: 1, name: template, moves: moves)
    }

    static func build(goal: String, days: Int, experience: String, kit: String, minutes: Int, focus: [String], keep: [JSON], start: String) -> WorkoutPlan {
        let n = max(1, min(6, days))
        var sessions: [PlanSession] = keep.prefix(n).map { r in
            PlanSession(weekday: 1, name: str(r["name"]), moves: list(r["exercises"]).map { e in
                let reps = Int(num(e["reps"]) ?? 8)
                return PlanMove(exercise: str(e["exercise"]), sets: Int(num(e["sets"]) ?? 3), low: reps, high: reps + 2)
            })
        }
        if sessions.isEmpty {
            sessions = Training.split(n).map { session($0, goal: goal, experience: experience, kit: kit, minutes: minutes, focus: focus) }
        } else {
            // fill the gaps: each extra day is the one that does most for the muscles still short of their sets
            let pool = ["Lower", "Upper", "Legs", "Push", "Pull", "Full body A", "Full body B"].map { session($0, goal: goal, experience: experience, kit: kit, minutes: minutes, focus: focus) }
            while sessions.count < n {
                let now = volume(sessions)
                guard let best = pool.max(by: { score($0, now, experience) < score($1, now, experience) }) else { break }
                sessions.append(PlanSession(weekday: 1, name: best.name, moves: best.moves))
            }
        }
        let wds = Training.weekdays(n)
        for i in sessions.indices { sessions[i].weekday = wds[i % wds.count] }
        return WorkoutPlan(goal: goal, experience: experience, kit: kit, minutes: minutes, focus: focus, start: WorkoutPlan.monday(start), sessions: sessions)
    }

    static func volume(_ sessions: [PlanSession]) -> [String: Int] {
        var v: [String: Int] = [:]
        for s in sessions { for m in s.moves { if let g = Muscles.group(m.exercise) { v[g, default: 0] += m.sets } } }
        return v
    }

    static func score(_ s: PlanSession, _ current: [String: Int], _ experience: String) -> Int {
        var c = current, total = 0
        for m in s.moves {
            guard let g = Muscles.group(m.exercise) else { continue }
            // a muscle with nothing yet counts double, so a missing leg day beats more upper body
            total += min(m.sets, max(0, Muscles.target(g, experience: experience) - c[g, default: 0])) * (current[g, default: 0] == 0 ? 2 : 1)
            c[g, default: 0] += m.sets
        }
        return total
    }
}

/// Double progression: work up the rep range at one weight; when every set reaches the top, the weight goes up.
struct Target { let reps: Int; let kg: Double; let sets: Int; let hint: String; let up: Bool }

enum Progression {
    static func step(_ name: String, kg: Double) -> Double {
        let n = name.lowercased()
        if ["dumbbell", "goblet", "curl", "raise", "fly", "extension", "arnold", "kettlebell"].contains(where: { n.contains($0) }) { return 2 }
        if ["squat", "deadlift", "leg press", "hip thrust"].contains(where: { n.contains($0) }) { return kg >= 40 ? 5 : 2.5 }
        return 2.5
    }

    static func snap(_ kg: Double, _ step: Double) -> Double { max(step, (kg / step).rounded() * step) }

    static func target(_ m: PlanMove, last: [(reps: Double, kg: Double)]?, deload: Bool) -> Target {
        let sets = deload ? max(1, (m.sets + 1) / 2) : m.sets
        let range = "\(m.low)–\(m.high)"
        guard let last, !last.isEmpty else {
            return Target(reps: m.low, kg: 0, sets: sets, hint: "New: pick a weight you could lift about \(m.high) times, then aim for \(range) reps.", up: false)
        }
        let kg = last.map { $0.kg }.max() ?? 0
        let said = last.map { Fmt.one($0.reps) }.joined(separator: ", ")
        let lowest = Int(last.map { $0.reps }.min() ?? 0)
        let top = last.allSatisfy { $0.reps >= Double(m.high) }
        if deload {
            let k = kg > 0 ? snap(kg * 0.9, step(m.exercise, kg: kg)) : 0
            return Target(reps: m.low, kg: k, sets: sets, hint: "Easier week: fewer sets\(k > 0 ? " at \(Fmt.one(k)) kg" : ""). Leave plenty in the tank so you come back stronger.", up: false)
        }
        if kg <= 0 {
            return top ? Target(reps: m.high, kg: 0, sets: sets, hint: "You hit \(said) last time. Add a set, or slow each rep down to make it harder.", up: true)
                       : Target(reps: max(m.low, min(m.high, lowest + 1)), kg: 0, sets: sets, hint: "Last time \(said). Aim for one more rep on each set.", up: false)
        }
        if top {
            let k = kg + step(m.exercise, kg: kg)
            return Target(reps: m.low, kg: k, sets: sets, hint: "Go up to \(Fmt.one(k)) kg. You hit \(said) at \(Fmt.one(kg)) kg last time, the top of \(range).", up: true)
        }
        return Target(reps: max(m.low, min(m.high, lowest + 1)), kg: kg, sets: sets,
                      hint: "Stay at \(Fmt.one(kg)) kg and beat last time (\(said)). When every set hits \(m.high), the weight goes up.", up: false)
    }
}

extension Store {
    var workoutPlan: WorkoutPlan? { WorkoutPlan(dict(doc["prefs"])["workoutPlan"]) }

    func saveWorkoutPlan(_ plan: WorkoutPlan?) {
        perform(["type": "workoutPlan", "plan": plan?.json ?? NSNull()], syncAfter: 2)
    }

    /// A planned day as a live session, with this week's targets filled in.
    func startPlanSession(_ ps: PlanSession, plan: WorkoutPlan) {
        let deload = plan.isDeload(on: today)
        let exercises = ps.moves.map { m -> LiveExercise in
            let t = Progression.target(m, last: lastSets(m.exercise), deload: deload)
            return LiveExercise(name: m.exercise, sets: (0..<max(1, t.sets)).map { _ in LiveSet(reps: Double(t.reps), kg: t.kg) })
        }
        saveSession(LiveSession(startedAt: Double(nowMs()), name: ps.name, routineId: "plan:\(ps.id)", exercises: exercises))
    }

    func liftedOn(_ date: String) -> Bool { workouts(on: date).contains { !list($0["lifts"]).isEmpty } }

    /// Hard sets done since Monday, for each muscle.
    var setsThisWeek: [String: Int] {
        cached("setsWeek-" + today) {
            var v: [String: Int] = [:]
            let mon = WorkoutPlan.monday(today)
            for i in 0..<7 {
                let d = DayKey.shift(mon, days: i)
                if d > today { break }
                for w in workouts(on: d) {
                    for l in list(w["lifts"]) {
                        guard let g = Muscles.group(str(l["exercise"])) else { continue }
                        v[g, default: 0] += max(list(l["detail"]).count, Int(num(l["sets"]) ?? 0))
                    }
                }
            }
            return v
        }
    }
}
