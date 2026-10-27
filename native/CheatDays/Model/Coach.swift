import Foundation

/// The card at the top of Today: ideas for the meal it's time for (from your food plan, sized to what's left), and one
/// piece of advice from what you've logged: weight not moving, low protein, lots of carbs, snacks or bread most days.
/// All worked out on the phone, so it costs nothing and is there the moment the app opens.
struct Nudge {
    let meal: String
    let ideas: [QuickEntry]
    let advice: String?
}

extension Store {
    var nudge: Nudge? {
        let hour = Calendar.current.component(.hour, from: Date())
        let meal = Meals.byTime(hour)
        let left = budgetToday - eaten
        let had = todayItems.contains { Meals.of($0) == meal }
        let ideas = had || left < 80 ? [] : Array(ideaEntries(for: meal).filter { $0.kcal <= left + 50 }.prefix(2))
        let advice = coachAdvice(meal: meal, hour: hour)
        guard !ideas.isEmpty || advice != nil else { return nil }
        return Nudge(meal: meal, ideas: ideas, advice: advice)
    }

    /// One line, the most useful first.
    func coachAdvice(meal: String, hour: Int) -> String? {
        let week = list(doc["history"]).prefix(7).map { list($0["items"]) }.filter { !$0.isEmpty }
        let weekItems = week.flatMap { $0 }
        let weekKcal = weekItems.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let snackKcal = weekItems.filter { Meals.of($0) == "Snacks" }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let snackShare = weekKcal > 0 ? snackKcal / weekKcal : 0
        let breadDays = week.filter { day in day.contains { str($0["name"]).range(of: #"\b(bread|toast|sandwich|bagel|wrap|baguette|roll|sourdough|crumpet)s?\b"#, options: [.regularExpression, .caseInsensitive]) != nil } }.count

        // weight not moving while trying to lose
        let c = checkIn
        if let want = c.want, want < 0, let pace = c.pace, pace > want / 3, week.count >= 4 {
            if snackShare > 0.22 { return "Your weight's not moving much. Snacks are \(Int(snackShare * 100))% of your food this week, the easiest place to trim." }
            if breadDays >= 5 { return "Your weight's not moving much. Bread's in \(breadDays) of your last \(week.count) days: swapping one a day for eggs or yoghurt helps." }
            return "Your weight's not moving much. Log everything for a week, drinks and bites too: the gap is usually hiding there."
        }

        // today: protein and carbs against the goals
        let m = macros(todayItems), goals = dict(doc["goals"])
        if let p = proteinGoal, hour >= 13, eaten > budgetToday * 0.4, m.p < p * 0.35 {
            return "Protein's low today: \(Int(m.p)) of \(Int(p)) g. Make \(meal.lowercased()) a protein one: chicken, eggs, fish, Greek yoghurt."
        }
        if let cg = pos(goals["c"]), hour < 18, m.c > cg * 0.8 {
            return "Lots of carbs today already (\(Int(m.c)) g). Go lighter on bread, rice and pasta later, more protein and veg."
        }

        // the week: the lighter pick for something you keep having
        if let w = weekSwap {
            return "\(w.food) came up \(w.days) days this week. \(w.pick.name) instead saves \(Fmt.int(w.pick.saves)) kcal each time: \(w.pick.why.lowercased())."
        }
        if snackShare > 0.28 && week.count >= 4 { return "Snacks are \(Int(snackShare * 100))% of your food this week. Fewer evening snacks would make the biggest difference." }
        if breadDays >= 6 { return "Bread's in nearly every day this week. Try eggs, yoghurt or a salad for one meal." }
        return nil
    }
}
