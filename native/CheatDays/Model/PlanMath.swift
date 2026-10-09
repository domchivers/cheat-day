import Foundation

/// The answers the plan is worked out from.
struct PlanInput {
    var sex = "m"
    var age = 30.0
    var height = 175.0
    var weight = 80.0
    var activity = 1.375
    var trainDays = 3            // sessions a week, gym and anything else
    var trainType = "weights"    // weights, cardio, mix, sport
    var trainMins = 45.0
    var goal = "lose"            // lose, recomp, maintain, leanbulk
    var pace = -0.5              // kg a week, one of Plan.paces
    var spread = "cheat"         // cheat or same
    var cheatDay = 6             // 0 Sunday … 6 Saturday, as the web app counts
    var cheatSize = 1.3          // the cheat day's share of an average day
    var protein = "std"          // std, high, lift
}

struct PlanResult {
    var bmr = 0, tdee = 0, kcal = 0
    var rate = 0.0
    var p = 0, c = 0, f = 0
    var days: [Int: Int] = [:]
    var everyday = 0
    var cheat: Int?
    var notes: [String] = []
    var date: Date?
}

/// The plan maths, the same as the web app's computePlan.
enum Plan {
    static let kcalPerKg = 7700.0
    static let trainMET: [String: Double] = ["weights": 5, "cardio": 7, "mix": 6, "sport": 7.5]
    static let paces: [String: [(String, Double)]] = [
        "lose": [("Gentle", -0.25), ("Steady", -0.5), ("Fast", -0.75)],
        "leanbulk": [("Slow", 0.15), ("Steady", 0.25)]
    ]
    struct Activity { let k: Double; let name: String; let sub: String; let symbol: String }
    static let activities = [
        Activity(k: 1.2, name: "Mostly sitting", sub: "Desk job, not much walking", symbol: "chair.lounge.fill"),
        Activity(k: 1.375, name: "Some walking", sub: "A bit on your feet, errands, a short walk", symbol: "figure.walk"),
        Activity(k: 1.55, name: "On my feet a lot", sub: "Retail, teaching, nursing, lots of walking", symbol: "figure.stand"),
        Activity(k: 1.725, name: "Physical job", sub: "Building, deliveries, farming", symbol: "hammer.fill")
    ]

    static func r10(_ v: Double) -> Int { Int((v / 10).rounded() * 10) }

    static func compute(_ q: PlanInput) -> PlanResult {
        var r = PlanResult()
        let w = q.weight, h = q.height, male = q.sex == "m"
        let bmr = 10 * w + 6.25 * h - 5 * q.age + (male ? 5 : -161)   // Mifflin-St Jeor
        // training on top of the resting burn (MET minus the 1 already counted), averaged over the week
        let train = Double(q.trainDays) * ((trainMET[q.trainType] ?? 6) - 1) * w * (q.trainMins / 60) / 7
        let tdee = bmr * q.activity + train
        var delta = (paces[q.goal] != nil ? q.pace : 0) * kcalPerKg / 7
        if q.goal == "recomp" { delta = -min(300, tdee * 0.1) }
        let floor = male ? 1500.0 : 1200.0
        if delta < 0 && -delta > tdee * 0.25 { delta = -tdee * 0.25; r.notes.append("That pace would need more than a quarter less than you burn, so it's been eased to a safer rate.") }
        var kcal = tdee + delta
        if kcal < floor { kcal = floor; r.notes.append("It won't go below \(Fmt.int(floor)) kcal a day, the usual safe minimum.") }
        kcal = Double(r10(kcal))
        let rate = ((kcal - tdee) * 7 / kcalPerKg * 100).rounded() / 100
        // protein from a healthier weight when BMI is very high
        let bmi = h > 0 ? w / pow(h / 100, 2) : 0
        let baseKg = bmi >= 30 ? 25 * pow(h / 100, 2) : w
        let perKg = ["std": 1.6, "high": 2.0, "lift": 2.2][q.protein] ?? 1.6
        let p = (baseKg * perKg).rounded()
        var f = max(0.8 * w, kcal * 0.25 / 9).rounded()
        var c = ((kcal - p * 4 - f * 9) / 4).rounded()
        if c < 50 { f = max(0.6 * w, (kcal - p * 4 - 200) / 9).rounded(); c = max(0, ((kcal - p * 4 - f * 9) / 4).rounded()) }
        // a cheat day: the same weekly total, more of it on one day
        var everyday = Int(kcal)
        if q.spread == "cheat" {
            let cheat = r10(kcal * q.cheatSize)
            everyday = r10((kcal * 7 - Double(cheat)) / 6)
            r.days[q.cheatDay] = cheat; r.cheat = cheat
        }
        if Double(everyday) < floor { r.notes.append("Your other days come out at \(Fmt.int(Double(everyday))) kcal, under the usual \(Fmt.int(floor)) minimum. A smaller cheat day fixes that.") }
        if q.age < 18 { r.notes.append("Under 18, it's best to check targets with a doctor or dietitian.") }
        if bmi > 0 && bmi < 18.5 && rate < 0 { r.notes.append("Your weight is already on the low side for your height, so losing more isn't recommended.") }
        if rate < 0 && -rate > w * 0.01 { r.notes.append("That's faster than 1% of body weight a week, which risks losing muscle.") }
        r.bmr = Int(bmr.rounded()); r.tdee = Int(tdee.rounded()); r.kcal = Int(kcal); r.rate = rate
        r.p = Int(p); r.c = Int(c); r.f = Int(f); r.everyday = everyday
        return r
    }

    /// When they'd reach their goal weight at this rate.
    static func reach(_ goal: Double?, from w: Double, rate: Double) -> Date? {
        guard let goal, rate != 0, (goal - w).sign == rate.sign else { return nil }
        return Calendar.current.date(byAdding: .day, value: Int(((goal - w) / rate * 7).rounded()), to: Date())
    }

    /// Where they are, for the AI's food suggestions.
    static var country: String {
        switch Locale.current.region?.identifier { case "GB": return "the UK"; case "AU": return "Australia"; default: return "the UK or Australia" }
    }
}

/// A training week built from how often they can train, what they've got, and how long they've been at it.
/// Hard sets per muscle a week sit in the usual evidence-based range: about 8–10 for beginners, 10–16 with some experience, 16–20 for the experienced.
enum Training {
    struct Move { let name: String; let sets: Int; let reps: Int }
    struct Day { let weekday: Int; let name: String; let moves: [Move] }

    static func split(_ days: Int) -> [String] {
        switch days {
        case ..<1: return []
        case 1: return ["Full body A"]
        case 2: return ["Full body A", "Full body B"]
        case 3: return ["Full body A", "Full body B", "Full body A"]
        case 4: return ["Upper", "Lower", "Upper", "Lower"]
        case 5: return ["Upper", "Lower", "Push", "Pull", "Legs"]
        default: return ["Push", "Pull", "Legs", "Push", "Pull", "Legs"]
        }
    }

    static func weekdays(_ days: Int) -> [Int] {
        switch days {
        case 1: return [3]
        case 2: return [1, 4]
        case 3: return [1, 3, 5]
        case 4: return [1, 2, 4, 5]
        case 5: return [1, 2, 3, 5, 6]
        default: return [1, 2, 3, 4, 5, 6]
        }
    }

    private static let templates: [String: [(String, Int, Int)]] = [
        "Full body A": [("Squat", 3, 8), ("Bench press", 3, 8), ("Barbell row", 3, 10), ("Romanian deadlift", 2, 10), ("Lateral raise", 2, 12), ("Dead bug", 2, 10)],
        "Full body B": [("Deadlift", 3, 5), ("Overhead press", 3, 8), ("Lat pulldown", 3, 10), ("Lunge", 2, 10), ("Dumbbell curl", 2, 12), ("Hanging leg raise", 2, 10)],
        "Upper": [("Bench press", 3, 8), ("Barbell row", 3, 8), ("Overhead press", 3, 10), ("Lat pulldown", 3, 10), ("Lateral raise", 3, 12), ("Dumbbell curl", 2, 12), ("Tricep pushdown", 2, 12)],
        "Lower": [("Squat", 3, 8), ("Romanian deadlift", 3, 10), ("Leg press", 3, 12), ("Leg curl", 3, 12), ("Calf raise", 3, 15), ("Hanging leg raise", 2, 10)],
        "Push": [("Bench press", 4, 8), ("Overhead press", 3, 8), ("Incline dumbbell press", 3, 10), ("Lateral raise", 3, 12), ("Tricep pushdown", 3, 12)],
        "Pull": [("Deadlift", 3, 5), ("Pull-up", 3, 8), ("Seated cable row", 3, 10), ("Face pull", 3, 15), ("Hammer curl", 3, 12)],
        "Legs": [("Squat", 4, 8), ("Romanian deadlift", 3, 10), ("Bulgarian split squat", 3, 10), ("Leg curl", 3, 12), ("Calf raise", 3, 15)]
    ]
    private static let dumbbells = ["Squat": "Goblet squat", "Bench press": "Dumbbell bench press", "Barbell row": "Dumbbell row", "Overhead press": "Dumbbell shoulder press",
                                    "Deadlift": "Romanian deadlift", "Lat pulldown": "Dumbbell row", "Leg press": "Bulgarian split squat", "Leg curl": "Hip thrust",
                                    "Tricep pushdown": "Overhead tricep extension", "Seated cable row": "Dumbbell row", "Face pull": "Rear delt fly", "Pull-up": "Dumbbell row",
                                    "Hanging leg raise": "Dead bug"]
    private static let bodyweight = ["Squat": "Bulgarian split squat", "Bench press": "Push-up", "Barbell row": "Back extension", "Overhead press": "Push-up",
                                     "Deadlift": "Glute bridge", "Romanian deadlift": "Glute bridge", "Lat pulldown": "Back extension", "Leg press": "Lunge", "Leg curl": "Glute bridge",
                                     "Lateral raise": "Plank", "Dumbbell curl": "Side plank", "Tricep pushdown": "Tricep dip", "Incline dumbbell press": "Push-up",
                                     "Seated cable row": "Back extension", "Face pull": "Dead bug", "Pull-up": "Back extension", "Hammer curl": "Side plank",
                                     "Hanging leg raise": "Dead bug", "Goblet squat": "Lunge", "Calf raise": "Calf raise", "Bulgarian split squat": "Bulgarian split squat"]

    /// The move to do instead with the kit they have.
    static func swap(_ name: String, kit: String) -> String {
        kit == "none" ? (bodyweight[name] ?? name) : kit == "dumbbells" ? (dumbbells[name] ?? name) : name
    }

    static func moves(_ name: String, experience: String, kit: String) -> [Move] {
        var seen = Set<String>(), out: [Move] = []
        for (i, t) in (templates[name] ?? []).enumerated() {
            let n = swap(t.0, kit: kit)
            guard seen.insert(n).inserted else { continue }
            let sets = experience == "new" ? max(2, t.1 - 1) : experience == "lots" && i < 2 ? t.1 + 1 : t.1
            out.append(Move(name: n, sets: sets, reps: t.2))
        }
        return out
    }

    static func week(days: Int, experience: String, kit: String) -> [Day] {
        zip(weekdays(days), split(days)).map { Day(weekday: $0.0, name: $0.1, moves: moves($0.1, experience: experience, kit: kit)) }
    }

    static func note(_ experience: String) -> String {
        switch experience {
        case "new": return "About 8–10 hard sets per muscle a week to start. Learn the moves, then add a rep or a little weight each week."
        case "lots": return "About 16–20 hard sets per muscle a week. Keep a rep or two in the tank and add weight when you hit the top of the range."
        default: return "About 10–16 hard sets per muscle a week. Add reps first, then weight, and stop a rep or two short of failure."
        }
    }
}

extension Store {
    /// The day of the week with the cheat-day budget, if there is one.
    var cheatWeekday: Int? {
        let base = pos(doc["budget"]) ?? 0
        let best = dict(doc["dayBudgets"]).compactMap { pair -> (Int, Double)? in
            guard let d = Int(pair.key), let n = num(pair.value), n > base + 50 else { return nil }
            return (d, n)
        }.max { $0.1 < $1.1 }
        return best?.0
    }

    /// The next cheat day (today counts) and how much more it has than a normal day.
    var nextCheat: (date: String, kcal: Double, extra: Double)? {
        guard let wd = cheatWeekday else { return nil }
        for i in 0..<7 {
            let date = DayKey.shift(today, days: i)
            if DayKey.weekday(date) == wd { let k = baseBudget(date); return (date, k, k - (pos(doc["budget"]) ?? k)) }
        }
        return nil
    }

    func cheatPlan(_ date: String) -> JSON? { dict(dict(doc["prefs"])["cheatPlans"])[date] as? JSON }

    /// New users (nothing logged, no plan, not onboarded on the website either) get the sign-up questions.
    var needsOnboarding: Bool {
        lastSynced != nil && doc["onboarded"] as? Bool != true && doc["plan"] as? JSON == nil
            && list(doc["history"]).isEmpty && todayItems.isEmpty
    }

    static func applyPlanOp(_ op: JSON, to d: inout JSON) {
        switch str(op["type"]) {
        case "plan":
            for k in ["profile", "budget", "dayBudgets", "goals", "plan", "weightKg"] { if let v = op[k], !(v is NSNull) { d[k] = v } }
            var prefs = dict(op["prefs"])
            if let kept = dict(d["prefs"])["cheatPlans"] { prefs["cheatPlans"] = kept }
            if prefs["workoutPlan"] == nil, let kept = dict(d["prefs"])["workoutPlan"] { prefs["workoutPlan"] = kept }
            d["prefs"] = prefs
            d["eatBack"] = false
            d["onboarded"] = true
            if let g = pos(op["goalWeight"]) { d["goalWeight"] = g; d["goalStart"] = ["weight": op["weightKg"] ?? 0, "day": op["day"] ?? ""] as JSON }
        case "cheatPlan":
            var prefs = dict(d["prefs"]), plans = dict(prefs["cheatPlans"])
            plans[str(op["date"])] = op["plan"] ?? NSNull()
            for k in plans.keys.sorted().dropLast(8) { plans.removeValue(forKey: k) }   // only the recent ones
            prefs["cheatPlans"] = plans; d["prefs"] = prefs
        case "saveMeal":
            let m = dict(op["meal"]), id = str(m["id"])
            guard !id.isEmpty, dict(d["tombs"])["meal:\(id)"] == nil else { return }
            var meals = list(d["meals"])
            if let i = meals.firstIndex(where: { str($0["id"]) == id }) { meals[i] = m } else { meals.insert(m, at: 0) }
            d["meals"] = meals
        case "deleteMeal":
            let id = str(op["id"])
            d["meals"] = list(d["meals"]).filter { str($0["id"]) != id }
            var tombs = dict(d["tombs"]); tombs["meal:\(id)"] = op["at"] ?? nowMs(); d["tombs"] = tombs
        case "budget":
            if let b = pos(op["budget"]) { d["budget"] = Int(b) }
            d["dayBudgets"] = op["dayBudgets"] as? JSON ?? JSON()
            if let e = op["eatBack"] as? Bool { d["eatBack"] = e }
        case "workoutPlan":
            var prefs = dict(d["prefs"])
            prefs["workoutPlan"] = op["plan"] ?? NSNull()
            d["prefs"] = prefs
        case "cheatSpread":
            let day = Int(num(op["day"]) ?? 6), cheat = Int(num(op["cheat"]) ?? 0), everyday = Int(num(op["everyday"]) ?? 0)
            guard cheat > 0, everyday > 0 else { return }
            d["budget"] = everyday
            d["dayBudgets"] = [String(day): cheat] as JSON
            if var plan = d["plan"] as? JSON { plan["spread"] = "cheat"; plan["cheatDay"] = day; d["plan"] = plan }
        default: break
        }
    }
}
