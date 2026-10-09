import Foundation

/// Workouts, in the web app's own shapes: a live session (`session`), finished workouts (`day.workouts`,
/// filed with each day in History), exercise records (`exercises`), routines and recent workouts.
enum Activities {
    /// Name, MET value, and whether it's a gym session with sets.
    static let all: [(name: String, met: Double, lifting: Bool)] = [
        ("Walk", 3.5, false), ("Run", 9.8, false), ("Cycle", 7.5, false), ("Swim", 7, false), ("Gym weights", 5, true), ("HIIT", 8, false),
        ("Yoga / stretch", 2.8, false), ("Football", 8, false), ("Tennis / padel", 7.3, false), ("Hike", 6, false), ("Rowing", 7, false),
        ("Elliptical", 5, false), ("Dance", 5.5, false), ("Boxing", 9, false), ("Climbing", 7, false), ("Other", 5, false)
    ]
    static let effort: [String: Double] = ["easy": 0.8, "moderate": 1, "hard": 1.25]
    static func symbol(_ type: String) -> String {
        switch type {
        case "Walk", "Hike": return "figure.walk"
        case "Run": return "figure.run"
        case "Cycle": return "figure.outdoor.cycle"
        case "Swim": return "figure.pool.swim"
        case "Gym weights": return "dumbbell.fill"
        case "HIIT", "Boxing": return "figure.boxing"
        case "Yoga / stretch": return "figure.yoga"
        case "Football": return "figure.soccer"
        case "Tennis / padel": return "figure.tennis"
        case "Rowing": return "figure.rower"
        case "Elliptical": return "figure.elliptical"
        case "Dance": return "figure.dance"
        case "Climbing": return "figure.climbing"
        default: return "figure.mixed.cardio"
        }
    }
}

/// A library to pick exercises from (the web app's EX_LIBRARY).
enum ExerciseLibrary {
    static let groups: [(String, [String])] = [
        ("Chest", ["Bench press", "Incline bench press", "Dumbbell bench press", "Incline dumbbell press", "Machine chest press", "Chest fly", "Cable crossover", "Push-up", "Chest dip"]),
        ("Back", ["Deadlift", "Lat pulldown", "Pull-up", "Chin-up", "Barbell row", "Dumbbell row", "Seated cable row", "T-bar row", "Face pull", "Back extension"]),
        ("Shoulders", ["Overhead press", "Dumbbell shoulder press", "Arnold press", "Lateral raise", "Front raise", "Rear delt fly", "Upright row", "Shrug"]),
        ("Arms", ["Barbell curl", "Dumbbell curl", "Hammer curl", "Preacher curl", "Cable curl", "Tricep pushdown", "Skull crusher", "Overhead tricep extension", "Close-grip bench press", "Tricep dip"]),
        ("Legs", ["Squat", "Front squat", "Goblet squat", "Hack squat", "Leg press", "Romanian deadlift", "Lunge", "Bulgarian split squat", "Step-up", "Leg extension", "Leg curl", "Hip thrust", "Glute bridge", "Calf raise"]),
        ("Core", ["Plank", "Side plank", "Crunch", "Cable crunch", "Hanging leg raise", "Russian twist", "Ab wheel rollout", "Dead bug"]),
        ("Full body", ["Kettlebell swing", "Farmer's carry", "Burpee", "Box jump", "Battle ropes", "Sled push", "Rowing machine"])
    ]
}

/// One set in a live session.
struct LiveSet: Identifiable, Equatable {
    var id = UUID()
    var reps: Double
    var kg: Double
    var done = false
    var pb = false
}

/// One exercise in a live session.
struct LiveExercise: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sets: [LiveSet]
    var complete: Bool { !sets.isEmpty && sets.allSatisfy(\.done) }
}

/// The session as the web app stores it: `{ startedAt, name, routineId, restUntil, exercises: [{ exercise, sets: [{ reps, kg, done, pb }] }] }`.
struct LiveSession: Equatable {
    var startedAt: Double
    var name: String
    var routineId: String?
    var restUntil: Double?
    var exercises: [LiveExercise]

    init(startedAt: Double, name: String, routineId: String?, restUntil: Double? = nil, exercises: [LiveExercise]) {
        self.startedAt = startedAt; self.name = name; self.routineId = routineId; self.restUntil = restUntil; self.exercises = exercises
    }

    init?(_ j: Any?) {
        guard let j = j as? JSON, let started = num(j["startedAt"]) else { return nil }
        startedAt = started
        name = str(j["name"])
        routineId = (j["routineId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        restUntil = num(j["restUntil"])
        exercises = list(j["exercises"]).map { e in
            LiveExercise(name: str(e["exercise"]), sets: list(e["sets"]).map { s in
                LiveSet(reps: num(s["reps"]) ?? 0, kg: num(s["kg"]) ?? 0, done: (s["done"] as? Bool) ?? false, pb: (s["pb"] as? Bool) ?? false)
            })
        }
    }

    var json: JSON {
        var j: JSON = ["startedAt": Int(startedAt), "name": name]
        j["routineId"] = routineId.map { $0 as Any } ?? NSNull()
        j["restUntil"] = restUntil.map { Int($0) as Any } ?? NSNull()
        j["exercises"] = exercises.map { e -> JSON in
            ["exercise": e.name, "sets": e.sets.map { s -> JSON in ["reps": s.reps, "kg": s.kg, "done": s.done, "pb": s.pb] }]
        }
        return j
    }

    /// The first set not ticked yet, top to bottom.
    var next: (ex: Int, set: Int)? {
        for (i, e) in exercises.enumerated() { if let j = e.sets.firstIndex(where: { !$0.done }) { return (i, j) } }
        return nil
    }
    var setsDone: Int { exercises.reduce(0) { $0 + $1.sets.filter(\.done).count } }
    var volume: Double { exercises.reduce(0) { $0 + $1.sets.filter(\.done).reduce(0) { $0 + $1.reps * $1.kg } } }
}

extension Store {
    // MARK: reading

    var session: LiveSession? { LiveSession(doc["session"]) }
    var restSeconds: Int { max(15, min(600, Int(num(doc["restSeconds"]) ?? 90))) }
    var weightKg: Double { pos(doc["weightKg"]) ?? 75 }
    var routines: [JSON] { list(doc["routines"]) }

    func burn(_ type: String, minutes: Double, effort: String) -> Double {
        let met = Activities.all.first { $0.name == type }?.met ?? 5
        return (met * (Activities.effort[effort] ?? 1) * weightKg * minutes / 60).rounded()
    }

    func exercise(_ name: String) -> JSON? { dict(doc["exercises"])[name.trimmingCharacters(in: .whitespaces).lowercased()] as? JSON }

    /// Workouts on each of the last seven days, oldest first.
    var week: [(date: String, kcal: Double, count: Int)] {
        (0..<7).reversed().map { back in
            let date = DayKey.shift(today, days: -back)
            let ws = workouts(on: date)
            return (date, ws.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, ws.count)
        }
    }

    func workouts(on date: String) -> [JSON] {
        if date == today { return todayWorkouts }
        if str(day["date"]) == date { return list(day["workouts"]) }
        return list(list(doc["history"]).first { str($0["date"]) == date }?["workouts"])
    }

    /// Finished workouts from earlier days, newest first.
    var pastWorkouts: [(date: String, index: Int, workout: JSON)] {
        var out: [(String, Int, JSON)] = []
        if str(day["date"]) != today { for (k, w) in list(day["workouts"]).enumerated() { out.append((str(day["date"]), k, w)) } }
        for h in list(doc["history"]).prefix(90) { for (k, w) in list(h["workouts"]).enumerated() { out.append((str(h["date"]), k, w)) } }
        return out.map { (date: $0.0, index: $0.1, workout: $0.2) }
    }

    /// Every time an exercise was done, newest first, with an estimated one-rep max.
    func sessions(of name: String) -> [(date: String, workout: String, lift: JSON, est: Double)] {
        let key = name.lowercased()
        var out: [(String, String, JSON, Double)] = []
        var days: [(String, [JSON])] = [(today, todayWorkouts)]
        if str(day["date"]) != today { days.append((str(day["date"]), list(day["workouts"]))) }
        days += list(doc["history"]).map { (str($0["date"]), list($0["workouts"])) }
        for (date, ws) in days {
            for w in ws {
                for l in list(w["lifts"]) where str(l["exercise"]).lowercased() == key {
                    let detail = list(l["detail"])
                    let best = detail.isEmpty ? Self.est(kg: num(l["kg"]) ?? 0, reps: num(l["reps"]) ?? 0)
                                              : detail.map { Self.est(kg: num($0["kg"]) ?? 0, reps: num($0["reps"]) ?? 0) }.max() ?? 0
                    out.append((date, str(w["name"]), l, best))
                }
            }
        }
        return out.map { (date: $0.0, workout: $0.1, lift: $0.2, est: $0.3) }
    }

    static func est(kg: Double, reps: Double) -> Double { kg > 0 ? (kg * (1 + reps / 30)).rounded() : 0 }

    /// The sets of an exercise last time: from its record, else from the latest workout that kept them.
    func lastSets(_ name: String) -> [(reps: Double, kg: Double)]? {
        if let rec = exercise(name) {
            let d = list(rec["detail"])
            if !d.isEmpty { return d.map { (num($0["reps"]) ?? 0, num($0["kg"]) ?? 0) } }
        }
        for s in sessions(of: name) {
            let d = list(s.lift["detail"])
            if !d.isEmpty { return d.map { (num($0["reps"]) ?? 0, num($0["kg"]) ?? 0) } }
        }
        return nil
    }

    func lastLine(_ name: String) -> String {
        let rec = exercise(name), sets = lastSets(name)
        guard rec != nil || sets != nil else { return "New exercise" }
        let best = (rec.flatMap { pos($0["best1rm"]) }).map { " · best est. 1RM \(Fmt.int($0)) kg" } ?? ""
        if let sets, sets.contains(where: { $0.reps != sets[0].reps || $0.kg != sets[0].kg }) {
            let sameKg = sets.allSatisfy { $0.kg == sets[0].kg }
            let body = sameKg ? sets.map { Fmt.one($0.reps) }.joined(separator: ", ") + (sets[0].kg > 0 ? " @ \(Fmt.one(sets[0].kg)) kg" : "")
                              : sets.map { ($0.kg > 0 ? "\(Fmt.one($0.kg))×" : "") + Fmt.one($0.reps) }.joined(separator: ", ") + " kg"
            return "Last time \(body)\(best)"
        }
        let n = sets.map { Double($0.count) } ?? num(rec?["sets"]) ?? 0
        let reps = sets?.first?.reps ?? num(rec?["reps"]) ?? 0
        let kg = sets?.first?.kg ?? num(rec?["kg"]) ?? 0
        return "Last time \(Fmt.one(n))×\(Fmt.one(reps))\(kg > 0 ? " @ \(Fmt.one(kg)) kg" : "")\(best)"
    }

    /// A new exercise for a session: last time's sets, or the routine's, or 3 × 8.
    func liveExercise(_ name: String, sets: Double? = nil, reps: Double? = nil, kg: Double? = nil, detail: [JSON]? = nil) -> LiveExercise {
        if let detail, !detail.isEmpty { return LiveExercise(name: name, sets: detail.prefix(8).map { LiveSet(reps: num($0["reps"]) ?? 8, kg: num($0["kg"]) ?? 0) }) }
        if let last = lastSets(name) { return LiveExercise(name: name, sets: last.prefix(8).map { LiveSet(reps: $0.reps > 0 ? $0.reps : 8, kg: $0.kg) }) }
        let rec = exercise(name)
        let n = Int(max(1, min(8, sets ?? num(rec?["sets"]) ?? 3)))
        return LiveExercise(name: name, sets: (0..<n).map { _ in LiveSet(reps: reps ?? num(rec?["reps"]) ?? 8, kg: kg ?? num(rec?["kg"]) ?? 0) })
    }

    // MARK: changing

    func startSession(_ routine: JSON?) {
        let s = LiveSession(startedAt: Double(nowMs()), name: str(routine?["name"]), routineId: (routine?["id"] as? String),
                            exercises: list(routine?["exercises"]).map { liveExercise(str($0["exercise"]), sets: num($0["sets"]), reps: num($0["reps"]), kg: num($0["kg"])) })
        saveSession(s)
    }

    func saveSession(_ s: LiveSession?) {
        perform(["type": "session", "session": s?.json ?? NSNull()], syncAfter: 1.5)
        WorkoutLive.update(s, store: self)
    }

    /// Finish: the ticked sets (or all, if none were ticked) become a logged workout.
    func finish(_ s: LiveSession, minutes: Int, name: String) -> JSON {
        var lifts: [JSON] = []
        for e in s.exercises where !e.name.trimmingCharacters(in: .whitespaces).isEmpty {
            var sets = e.sets.filter(\.done)
            if sets.isEmpty { sets = e.sets }
            guard !sets.isEmpty else { continue }
            let kg = sets.map(\.kg).max() ?? 0
            let reps = max(1, (sets.reduce(0) { $0 + $1.reps } / Double(sets.count)).rounded())
            lifts.append(["exercise": e.name.trimmingCharacters(in: .whitespaces), "sets": sets.count, "reps": reps, "kg": kg,
                          "detail": sets.map { ["reps": $0.reps, "kg": $0.kg] as JSON }])
        }
        let w = logged(type: "Gym weights", name: name, minutes: Double(minutes), effort: "moderate", lifts: lifts)
        perform(["type": "logWorkout", "workout": w, "clearSession": true])
        WorkoutLive.update(nil, store: self)
        return w
    }

    func logActivity(type: String, name: String, minutes: Double, effort: String) {
        perform(["type": "logWorkout", "workout": logged(type: type, name: name.isEmpty ? type : name, minutes: minutes, effort: effort, lifts: [])])
    }

    private func logged(type: String, name: String, minutes: Double, effort: String, lifts: [JSON]) -> JSON {
        ["id": uid(), "type": type, "name": name, "minutes": Int(minutes.rounded()), "effort": effort,
         "kcal": burn(type, minutes: minutes, effort: effort), "lifts": lifts, "at": ISO.now()]
    }

    func deleteWorkout(_ id: String) { perform(["type": "deleteWorkout", "id": id, "at": nowMs()]) }

    func saveRoutine(name: String, exercises: [JSON]) {
        perform(["type": "routine", "routine": ["id": uid(), "name": name, "exercises": exercises] as JSON])
    }
    func deleteRoutine(_ id: String) { perform(["type": "deleteRoutine", "id": id, "at": nowMs()]) }
    func setRest(_ seconds: Int) { perform(["type": "set", "key": "restSeconds", "value": max(15, min(600, seconds))], syncAfter: 2) }

    // MARK: the workout operations

    static func applyWorkoutOp(_ op: JSON, to d: inout JSON, today: String) {
        switch str(op["type"]) {
        case "session":
            d["session"] = op["session"] ?? NSNull()
        case "set":
            let key = str(op["key"])
            if ["restSeconds"].contains(key) { d[key] = op["value"] ?? NSNull() }
        case "logWorkout":
            let w = dict(op["workout"]), id = str(w["id"])
            if op["clearSession"] as? Bool == true { d["session"] = NSNull() }
            var day = dict(d["day"]), ws = list(day["workouts"])
            guard !id.isEmpty, dict(d["tombs"])["wo:\(id)"] == nil, !ws.contains(where: { str($0["id"]) == id }) else { return }
            ws.append(w); day["workouts"] = ws; d["day"] = day
            // exercise records: last sets, best estimated one-rep max, best set (the web app's logWorkout)
            var records = dict(d["exercises"]); var pbs = 0
            for l in list(w["lifts"]) {
                let name = str(l["exercise"]), key = name.lowercased(), prev = records[key] as? JSON
                let kg = num(l["kg"]) ?? 0, reps = num(l["reps"]) ?? 0, e1 = est(kg: kg, reps: reps)
                let prevBest = num(prev?["best1rm"]) ?? 0
                if prev != nil && e1 > prevBest && kg > 0 { pbs += 1 }
                let pb = prev?["bestSet"] as? JSON
                let better = kg > 0 && (pb == nil || kg > (num(pb?["kg"]) ?? 0) || (kg == (num(pb?["kg"]) ?? 0) && reps > (num(pb?["reps"]) ?? 0)))
                let bestSet: Any
                if better { bestSet = ["kg": kg, "reps": reps] as JSON } else if let pb { bestSet = pb } else { bestSet = NSNull() }
                records[key] = ["name": name, "sets": l["sets"] ?? 0, "reps": reps, "kg": kg, "detail": l["detail"] ?? NSNull(),
                                "best1rm": max(e1, prevBest), "bestSet": bestSet, "lastUsed": ISO.now()] as JSON
            }
            d["exercises"] = records
            if pbs > 0 { d["pbCount"] = Int(num(d["pbCount"]) ?? 0) + pbs }
            let rkey = (str(w["type"]) + "|" + str(w["name"])).lowercased()
            var recent = list(d["recentWorkouts"]).filter { str($0["key"]) != rkey }
            recent.insert(["key": rkey, "type": w["type"] ?? "", "name": w["name"] ?? "", "minutes": w["minutes"] ?? 0, "effort": w["effort"] ?? "moderate", "lifts": w["lifts"] ?? [Any]()] as JSON, at: 0)
            d["recentWorkouts"] = Array(recent.prefix(10))
        case "deleteWorkout":
            let id = str(op["id"])
            var day = dict(d["day"])
            day["workouts"] = list(day["workouts"]).filter { str($0["id"]) != id }
            d["day"] = day
            var tombs = dict(d["tombs"]); tombs["wo:\(id)"] = op["at"] ?? nowMs(); d["tombs"] = tombs
        case "routine":
            let r = dict(op["routine"]), name = str(r["name"]).lowercased()
            var rs = list(d["routines"]).filter { str($0["name"]).lowercased() != name }
            rs.insert(r, at: 0)
            d["routines"] = Array(rs.prefix(12))
        case "deleteRoutine":
            let id = str(op["id"])
            d["routines"] = list(d["routines"]).filter { str($0["id"]) != id }
            var tombs = dict(d["tombs"]); tombs["routine:\(id)"] = op["at"] ?? nowMs(); d["tombs"] = tombs
        default: break
        }
    }
}

/// The session on the lock screen and in the Dynamic Island.
enum WorkoutLive {
    static func update(_ s: LiveSession?, store: Store) {
        guard let s else { WorkoutTimer.shared.end(); return }
        var next = ""
        if let n = s.next {
            let e = s.exercises[n.ex], set = e.sets[n.set]
            next = "\(e.name.isEmpty ? "Exercise" : e.name) · set \(n.set + 1)" + (set.kg > 0 ? " · \(Fmt.one(set.reps))×\(Fmt.one(set.kg)) kg" : " · \(Fmt.one(set.reps)) reps")
        }
        var body: [String: Any] = ["name": s.name, "startedAt": s.startedAt, "next": next, "setsDone": s.setsDone]
        if let r = s.restUntil, r > Double(nowMs()) { body["restEnds"] = r }
        WorkoutTimer.shared.update(from: body)
    }
}
