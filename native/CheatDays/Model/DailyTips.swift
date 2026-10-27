import Foundation

/// The morning card: how yesterday went (one thing that went well, one to improve) and a few meals to try today from
/// your food plan. Never on a cheat day, and the day after one it doesn't pick at what you ate. Worked out on the phone.
struct DailyReview {
    var good: String?
    var improve: String?
    var afterCheat = false
    var ideas: [JSON] = []
    var focus: String?
}

extension Store {
    func isCheatDay(_ date: String) -> Bool { cheatWeekday.map { DayKey.weekday(date) == $0 } ?? false }

    var dailyReview: DailyReview? {
        guard !isCheatDay(today) else { return nil }
        let y = DayKey.shift(today, days: -1)
        var r = DailyReview(afterCheat: isCheatDay(y), ideas: ideasForToday, focus: habitFocus)
        if !r.afterCheat, let d = pastDay(y), !d.items.isEmpty {
            let m = macros(d.items), goals = dict(doc["goals"])
            let snack = d.items.filter { Meals.of($0) == "Snacks" }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
            let top = d.items.max { (num($0["kcal"]) ?? 0) < (num($1["kcal"]) ?? 0) }.map { str($0["name"]) }
            // what went well
            if let p = proteinGoal, m.p >= p * 0.9 { r.good = "You hit your protein: \(Int(m.p)) g." }
            else if abs(d.kcal - d.budget) <= d.budget * 0.08 { r.good = "Bang on budget: \(Fmt.int(d.kcal)) of \(Fmt.int(d.budget))." }
            else if d.kcal < d.budget { r.good = "Under budget by \(Fmt.int(d.budget - d.kcal))." }
            // one thing to do better
            if d.kcal > d.budget + 150 { r.improve = "Over by \(Fmt.int(d.kcal - d.budget))\(top.map { ", mostly \($0)" } ?? ""). Plan that one in, or have a smaller portion." }
            else if let p = proteinGoal, m.p < p * 0.7 { r.improve = "Protein was \(Int(m.p)) of \(Int(p)) g. Start today with some: eggs, yoghurt or a shake." }
            else if d.kcal > 0, snack / d.kcal > 0.3 { r.improve = "Snacks were \(Int(snack / d.kcal * 100))% of yesterday. A proper meal first keeps them down." }
            else if let cg = pos(goals["c"]), m.c > cg * 1.2 { r.improve = "Carbs were high (\(Int(m.c)) g). Swap one bread, rice or pasta for protein and veg." }
            else if let w = weekSwap { r.improve = "\(w.food) came up \(w.days) days this week. Try \(w.pick.name) instead: saves \(Fmt.int(w.pick.saves)) kcal each time." }
        }
        guard r.good != nil || r.improve != nil || r.afterCheat || !r.ideas.isEmpty else { return nil }
        return r
    }

    /// One idea for each meal still to come today, a different one each day; the ones you'd try come round first.
    var ideasForToday: [JSON] {
        let hour = Calendar.current.component(.hour, from: Date())
        let day = Int(DayKey.date(today).timeIntervalSince1970 / 86_400)
        let start = Meals.all.firstIndex(of: Meals.byTime(hour)) ?? 0
        return Meals.all.dropFirst(start).filter { $0 != "Snacks" }.compactMap { meal -> JSON? in
            let here = habitIdeas.filter { str($0["meal"]) == meal }
            let picked = here.filter { $0["picked"] as? Bool == true }
            let pool = picked.isEmpty ? here : picked
            return pool.isEmpty ? nil : pool[day % pool.count]
        }
    }

    /// Keeps a recipe the AI wrote with its idea, so opening it again is instant and free.
    func keepRecipe(_ recipe: JSON, for name: String) {
        var h = habits
        h["ideas"] = list(h["ideas"]).map { i -> JSON in
            guard str(i["name"]) == name else { return i }
            var c = i; c["recipe"] = recipe; return c
        }
        saveHabits(h)
    }
}
