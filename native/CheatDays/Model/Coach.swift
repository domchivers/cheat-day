import Foundation

/// The card at the top of Today: ideas for the meal it's time for (from your food plan, sized to what's left), and one
/// piece of advice from what you've logged: weight not moving, light lunches and dinners, low protein, lots of carbs,
/// a lighter swap, or snacks. All worked out on the phone, so it costs nothing and is there the moment the app opens.
struct Nudge {
    let meal: String
    let ideas: [QuickEntry]
    let advice: Advice?
}

/// One piece of advice: a short headline, a line under it, and the meal to plan when there's something to do.
struct Advice: Equatable {
    let icon: String
    let title: String
    let detail: String
    var plan: String? = nil
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

    /// One piece, the most useful first.
    func coachAdvice(meal: String, hour: Int) -> Advice? {
        let week = list(doc["history"]).prefix(7).map { list($0["items"]) }.filter { !$0.isEmpty }
        let weekItems = week.flatMap { $0 }
        let weekKcal = weekItems.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let snackKcal = weekItems.filter { Meals.of($0) == "Snacks" }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let snackShare = weekKcal > 0 ? snackKcal / weekKcal : 0
        let next = hour < 15 ? "Lunch" : "Dinner"   // the main meal still to come, for the ideas link

        // weight not moving while trying to lose
        let c = checkIn
        if let want = c.want, want < 0, let pace = c.pace, pace > want / 3, week.count >= 4 {
            if snackShare > 0.22 { return Advice(icon: "⚖️", title: "Your weight's not moving much", detail: "Snacks are \(Int(snackShare * 100))% of your food this week, the easiest place to trim.") }
            return Advice(icon: "⚖️", title: "Your weight's not moving much", detail: "Log everything for a week, drinks and bites too: the gap is usually hiding there.")
        }

        // lunches and dinners with hardly any protein (toast, crumpets): not really a meal
        let light = lightMainMeals()
        if light.light >= 4, Double(light.light) >= Double(light.of) * 0.5 {
            let eg = light.examples.isEmpty ? "" : " (\(light.examples.joined(separator: ", ")))"
            return Advice(icon: "🍽️", title: "Light meals: \(light.light) of your last \(light.of)",
                          detail: "Lunches and dinners with little protein\(eg). A main meal needs some: eggs, chicken, fish, beans or cheese.", plan: next)
        }

        // today: protein and carbs against the goals
        let m = macros(todayItems), goals = dict(doc["goals"])
        if let p = proteinGoal, hour >= 13, eaten > budgetToday * 0.4, m.p < p * 0.35 {
            return Advice(icon: "🥚", title: "Protein's low: \(Int(m.p)) of \(Int(p)) g",
                          detail: "Make \(next.lowercased()) a protein one: chicken, eggs, fish or Greek yoghurt.", plan: next)
        }
        if let cg = pos(goals["c"]), hour < 18, m.c > cg * 0.8 {
            return Advice(icon: "🍝", title: "Lots of carbs today: \(Int(m.c)) g", detail: "Go lighter on bread, rice and pasta later, with more protein and veg.")
        }

        // the week: the lighter pick for something you keep having
        if let w = weekSwap {
            return Advice(icon: "🔄", title: "Swap your \(w.food.lowercased())",
                          detail: "It came up \(w.days) days this week. \(w.pick.name) instead saves \(Fmt.int(w.pick.saves)) kcal each time: \(w.pick.why.lowercased()).")
        }
        if snackShare > 0.28 && week.count >= 4 {
            return Advice(icon: "🍪", title: "Snacks are \(Int(snackShare * 100))% of your week", detail: "Fewer evening snacks would make the biggest difference.")
        }
        return nil
    }
}
