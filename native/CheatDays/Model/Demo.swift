import Foundation

/// A made-up person's last four weeks, for marketing screenshots (launch with -demo): weekdays at 2,350 with a
/// Saturday treat day at 3,250, protein hit, Saturday weigh-ins coming down about 0.45 kg a week. Never synced.
enum Demo {
    /// name, kcal per 100, protein, carbs, fat per 100, grams, meal
    private static let foods: [String: (k: Double, p: Double, c: Double, f: Double)] = [
        "Greek yoghurt bowl": (145, 10, 14, 4), "Chicken burrito bowl": (150, 11, 15, 5), "Chilli lemon chicken": (190, 24, 2, 10),
        "Rice, cooked": (130, 2.7, 28, 0.3), "Broccoli, steamed": (35, 2.8, 7, 0.4), "Protein brownie": (316, 33, 30, 10),
        "Banana": (89, 1.1, 23, 0.3), "Flat white": (60, 3.5, 5, 3.2), "Margherita pizza": (260, 11, 30, 10),
        "Pale ale": (45, 0.5, 3.6, 0), "Gelato": (200, 3.5, 28, 8), "Roast potatoes": (150, 2.5, 22, 6)
    ]

    private static func item(_ name: String, _ grams: Double, _ meal: String, _ date: String) -> JSON {
        let f = foods[name] ?? (100, 0, 0, 0)
        return ["id": uid(), "name": name, "kcal": Int((f.k * grams / 100).rounded()), "kcalPer100": f.k, "p100": f.p, "c100": f.c, "f100": f.f,
                "unit": name == "Pale ale" || name == "Flat white" ? "ml" : "g", "source": "search", "meal": meal,
                "addedAt": ISO8601DateFormatter().string(from: DayKey.date(date))]
    }

    private static func day(_ date: String) -> [JSON] {
        let wd = DayKey.weekday(date)
        if wd == 6 {   // Saturday, the treat day
            return [item("Greek yoghurt bowl", 295, "Breakfast", date), item("Chicken burrito bowl", 450, "Lunch", date),
                    item("Margherita pizza", 450, "Dinner", date), item("Pale ale", 660, "Dinner", date), item("Gelato", 150, "Snacks", date)]
        }
        var d = [item("Greek yoghurt bowl", 295, "Breakfast", date), item("Flat white", 300, "Breakfast", date),
                 item("Chicken burrito bowl", 450, "Lunch", date), item("Chilli lemon chicken", 200, "Dinner", date),
                 item("Rice, cooked", 200, "Dinner", date), item("Broccoli, steamed", 150, "Dinner", date),
                 item("Protein brownie", 60, "Snacks", date), item("Banana", 120, "Snacks", date)]
        if wd == 0 { d.append(item("Roast potatoes", 150, "Dinner", date)) }
        return d
    }

    /// Legs on Monday, push on Wednesday, pull on Friday, as Finish logs them.
    private static let plan: [Int: (name: String, lifts: [(String, Int, Double, Double)])] = [
        1: ("Legs", [("Squat", 3, 8, 100), ("Leg press", 3, 10, 180), ("Calf raises", 3, 15, 60)]),
        3: ("Push", [("Bench press", 3, 8, 80), ("Overhead press", 3, 8, 50), ("Tricep pushdown", 3, 12, 30)]),
        5: ("Pull", [("Deadlift", 3, 5, 140), ("Lat pulldown", 3, 10, 65), ("Barbell row", 3, 8, 70)])
    ]

    private static func workouts(_ date: String) -> [JSON] {
        guard let w = plan[DayKey.weekday(date)] else { return [] }
        let lifts = w.lifts.map { l -> JSON in
            ["exercise": l.0, "sets": l.1, "reps": l.2, "kg": l.3, "detail": (0..<l.1).map { _ in ["reps": l.2, "kg": l.3] as JSON }]
        }
        return [["id": uid(), "type": "Gym weights", "name": w.name, "minutes": 55, "effort": "moderate", "kcal": 310, "lifts": lifts,
                 "at": ISO8601DateFormatter().string(from: DayKey.date(date))]]
    }

    /// A legs session half done, resting between squat sets.
    private static var liveSession: JSON {
        let now = Date().timeIntervalSince1970 * 1000
        let sets = { (n: Int, reps: Double, kg: Double, done: Int) in (0..<n).map { i in ["reps": reps, "kg": kg, "done": i < done, "pb": false] as JSON } }
        return ["startedAt": Int(now - 32 * 60_000), "name": "Legs", "routineId": NSNull(), "restUntil": Int(now + 72_000), "lastAt": Int(now - 18_000),
                "exercises": [["exercise": "Squat", "sets": sets(3, 8, 100, 2)], ["exercise": "Leg press", "sets": sets(3, 10, 180, 0)],
                              ["exercise": "Calf raises", "sets": sets(3, 15, 60, 0)]]]
    }

    static func doc(today: String = DayKey.string(Date()), session: Bool = false) -> JSON {
        let budgets: [Int: Int] = [6: 3250, 0: 2500]
        let history: [JSON] = (1...28).map { i in
            let date = DayKey.shift(today, days: -i), items = day(date)
            // the day's macros, as filing a day stores them (Me's week reads these, not the items)
            let m = items.reduce((p: 0.0, c: 0.0, f: 0.0)) { t, it in
                let g = (num(it["kcal"]) ?? 0) / (num(it["kcalPer100"]) ?? 1) * 100
                return (t.p + (num(it["p100"]) ?? 0) * g / 100, t.c + (num(it["c100"]) ?? 0) * g / 100, t.f + (num(it["f100"]) ?? 0) * g / 100)
            }
            return ["date": date, "items": items, "budget": budgets[DayKey.weekday(date)] ?? 2350,
                    "kcal": items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, "workouts": workouts(date),
                    "p": Int(m.p.rounded()), "c": Int(m.c.rounded()), "f": Int(m.f.rounded())]
        }
        // today so far: breakfast, lunch and a coffee
        let now = [item("Greek yoghurt bowl", 295, "Breakfast", today), item("Flat white", 300, "Breakfast", today),
                   item("Chicken burrito bowl", 450, "Lunch", today)]
        // Saturday weigh-ins, about 0.45 kg a week down with a little noise, and a couple of midweek ones
        var body: [JSON] = []
        let noise = [0.1, -0.15, 0.05, 0.2, -0.1, 0.0, 0.1]
        for w in 0..<7 {
            let back = (DayKey.weekday(today) + 1) % 7 + 7 * (6 - w)   // the Saturday w weeks into the last seven
            let date = DayKey.shift(today, days: -back)
            body.append(["day": date, "weight": ((84.2 - 0.45 * Double(w) + noise[w]) * 100).rounded() / 100, "usual": true,
                         "takenAt": ISO8601DateFormatter().string(from: DayKey.date(date)), "updatedAt": ISO.now()])
            if w == 3 || w == 5 {
                let mid = DayKey.shift(date, days: 4)
                body.append(["day": mid, "weight": ((84.2 - 0.45 * Double(w) - 0.6) * 100).rounded() / 100, "updatedAt": ISO.now()])
            }
        }
        var d: JSON = [
            "onboarded": true, "goalWeight": 78, "goalStart": ["weight": num(body.first?["weight"]) ?? 84.3, "day": str(body.first?["day"])] as JSON, "budget": 2350, "dayBudgets": ["6": 3250, "0": 2500] as JSON,
            "goals": ["p": 160, "c": 250, "f": 80] as JSON, "profile": ["sex": "m", "name": "Sam"] as JSON,
            "plan": ["goal": "lose", "pace": -0.45, "rate": -0.45, "tdee": 2950, "bmr": 1850, "kcal": 2500, "cheatDay": 6, "spread": "cheat",
                     "macros": ["p": 160, "c": 250, "f": 80] as JSON, "createdAt": ISO.now()] as JSON,
            "prefs": ["weighDay": 6] as JSON, "weightKg": 81.5,
            "day": ["date": today, "items": now, "workouts": [] as [JSON]] as JSON,
            "history": history, "body": body.sorted { str($0["day"]) < str($1["day"]) }
        ]
        if session { d["session"] = liveSession }
        return d
    }
}
