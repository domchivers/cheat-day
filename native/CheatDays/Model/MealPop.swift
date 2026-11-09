import Foundation

/// The pop-ups on Today, at most five a day: the morning one (yesterday, and a hand with breakfast), one before lunch
/// and dinner to plan it, and one after each to say how it went, good or bad. Each meal is judged with the rest of the
/// day: a small lunch packed with protein is good, and a light one doesn't matter when the day's protein is on track.
/// Worked out on the phone; all of them in Plan a meal's style, with the assistant's chat box.
struct MealPop: Identifiable {
    enum Kind: String { case morning, before, after }
    enum Tone { case plain, good, warn, accent }
    struct Stat { let value: String; let label: String; var tone: Tone = .plain }
    struct Part { let title: String; var tone: Tone = .accent; var lines: [(icon: String, text: String)] }

    let kind: Kind
    let meal: String
    var title: String
    var meta: String?
    var stats: [Stat] = []
    var parts: [Part] = []
    var ideas: [JSON] = []
    var placeholder = "What do you fancy, or what's in?"

    var id: String { key }
    /// What it's remembered by, so each one comes once a day: "morning", "before-Lunch", "after-Dinner".
    var key: String { kind == .morning ? "morning" : "\(kind.rawValue)-\(meal)" }
}

extension Store {
    static let mealShare = ["Breakfast": 0.25, "Lunch": 0.30, "Dinner": 0.35, "Snacks": 0.10]

    /// A meal's own size, from the whole day's budget and protein goal: what it's judged against once it's eaten
    /// (mealTarget moves with what's been eaten, so after the meal it'd be measuring the meal against itself).
    func mealSize(_ meal: String) -> (kcal: Double, protein: Double?) {
        let s = Self.mealShare[meal] ?? 0.3
        return ((baseBudget(today) * s / 10).rounded() * 10, proteinGoal.map { ($0 * s).rounded() })
    }

    /// The protein you'd have by the end of this meal to be on track for the day's goal.
    func proteinPace(through meal: String) -> Double? {
        guard let g = proteinGoal, let at = Meals.all.firstIndex(of: meal) else { return nil }
        return g * Meals.all.prefix(through: at).reduce(0) { $0 + (Self.mealShare[$1] ?? 0) }
    }

    // MARK: the morning

    func morningPop() -> MealPop? {
        guard !isCheatDay(today) else { return nil }
        let h = Calendar.current.component(.hour, from: Date())
        var p = MealPop(kind: .morning, meal: "Breakfast", title: h < 12 ? "Good morning" : "Good afternoon")
        let r = dailyReview
        var lines: [(icon: String, text: String)] = []
        if r?.afterCheat == true { lines.append(("🎉", "Hope you enjoyed your cheat day. Back to normal today, nothing to make up for.")) }
        if let g = r?.good { lines.append(("🏆", g)) }
        if let i = r?.improve { lines.append(("🎯", i)) }
        if let f = r?.focus { lines.append(("🥗", "This week: \(f)")) }
        if !lines.isEmpty { p.parts.append(.init(title: "Yesterday", lines: lines)) }
        // breakfast already in: nothing to plan, so it's only worth coming up for yesterday
        if todayItems.contains(where: { Meals.of($0) == "Breakfast" }) && lines.isEmpty { return nil }
        p.ideas = Array((r?.ideas ?? ideasForToday).filter { str($0["meal"]) == "Breakfast" }.prefix(1))
        return p
    }

    // MARK: before lunch and dinner

    func beforePop(_ meal: String) -> MealPop? {
        guard meal == "Lunch" || meal == "Dinner", !isCheatDay(today), !todayItems.contains(where: { Meals.of($0) == meal }) else { return nil }
        var p = MealPop(kind: .before, meal: meal, title: "\(meal) time")
        let left = max(0, budgetToday - eaten), prot = macros(todayItems).p
        let had = Meals.all.filter { m in todayItems.contains { Meals.of($0) == m } }.map { $0.lowercased() }
        if had.isEmpty {
            p.parts.append(.init(title: "Today so far", lines: [("🍽️", "Nothing logged yet: \(Fmt.int(left)) kcal to go.")]))
        } else {
            let names = had.count == 1 ? had[0] : had.dropLast().joined(separator: ", ") + " and " + had.last!
            let togo = proteinGoal.map { " and \(Int(max(0, $0 - prot))) g protein to go" } ?? ""
            p.parts.append(.init(title: "Today so far", lines: [("🍽️", "\(names.prefix(1).uppercased() + names.dropFirst()): \(Fmt.int(eaten)) kcal, \(Int(prot)) g protein. \(Fmt.int(left)) left\(togo).")]))
        }
        p.ideas = Array(ideasForToday.filter { str($0["meal"]) == meal }.prefix(1))
        return p
    }

    // MARK: after lunch and dinner

    /// How the meal went, every time it's logged: what went right first, then what to do better only when the day
    /// needs it. Protein short at lunch after a big-protein breakfast isn't a problem; over the meal's size with plenty
    /// left isn't either.
    func afterPop(_ meal: String) -> MealPop? {
        guard meal == "Lunch" || meal == "Dinner", !isCheatDay(today) else { return nil }
        let items = todayItems.filter { Meals.of($0) == meal }
        let kcal = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        guard kcal >= 80 else { return nil }   // a cup of tea isn't the meal
        let m = meal.lowercased(), size = mealSize(meal)
        let knownKcal = items.filter { FoodMath.macros($0, kcal: num($0["kcal"]) ?? 0) != nil }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let known = knownKcal >= kcal * 0.7   // a curry logged as calories alone: its protein is unknown, not low
        let p = macros(items).p, dayP = macros(todayItems).p
        let left = budgetToday - eaten
        let goal = proteinGoal
        let goalHit = goal.map { dayP >= $0 * 0.95 } ?? false
        let onTrack = proteinPace(through: meal).map { dayP >= $0 * 0.9 } ?? false
        let proper = known && p >= (size.protein.map { $0 * 0.8 } ?? Self.lightLimit(meal) * 2)
        let dense = known && p >= 15 && p / kcal * 100 >= 8   // small but packed: 35 g in 300 kcal
        // light on protein only matters when the day's behind too
        let short = isLight(items, meal: meal) && !goalHit && !onTrack
        let over = kcal - size.kcal
        // over the meal's size only matters when it eats into the rest of the day
        let overMatters = over > 150 && (left < 0 || (meal == "Lunch" && left < mealSize("Dinner").kcal))
        let veg = Self.has(items, Self.vegWords)

        var good: [(icon: String, text: String)] = []
        if proper { good.append(("🥚", "\(Int(p)) g protein: that's a proper main meal.")) }
        else if dense { good.append(("🥚", "Small but packed with protein: \(Int(p)) g in \(Fmt.int(kcal)) kcal.")) }
        if let g = goal {
            if goalHit { good.append(("🏆", "Protein goal hit for today: \(Int(dayP)) of \(Int(g)) g.")) }
            else if onTrack && !proper { good.append(("🎯", "On track for protein today: \(Int(dayP)) of \(Int(g)) g.")) }
        }
        if veg { good.append(("🥦", "Veg in it.")) }
        if !overMatters {
            if kcal < size.kcal * 0.75 { good.append(("🍽️", "A light \(m), so there's \(Fmt.int(max(0, left))) left for later.")) }
            else if over <= 60 { good.append(("🍽️", "Right on your \(m) size.")) }
        }
        if good.isEmpty { good.append(("🍽️", left >= 0 ? "Logged, with \(Fmt.int(left)) left today." : "Logged: that's the hardest part done.")) }

        var better: [(icon: String, text: String)] = []
        if short {
            let first = items.first.map { Self.shortName(str($0["name"])) } ?? "it"
            let fix = Self.breadHeavy(items) ? "Eggs, beans, tuna or cheese on it turn \(first) into a meal."
                    : meal == "Lunch" ? "Dinner needs a good amount: chicken, fish, eggs, tofu or beans."
                    : "A yoghurt or a shake would help close the gap."
            let day = goal.map { ", and \(Int(dayP)) of \(Int($0)) g so far today" } ?? ""
            better.append(("🥚", "Only \(Int(p)) g protein\(day). \(fix)"))
            let week = lightMainMeals(only: meal)
            if week.light >= 3 { better.append(("📅", "Light \(m)s \(week.light) times in the last \(week.of) \(meal == "Dinner" ? "nights" : "days").")) }
        }
        if overMatters {
            let top = items.max { (num($0["kcal"]) ?? 0) < (num($1["kcal"]) ?? 0) }.map { Self.shortName(str($0["name"])) }
            better.append(("🍽️", "\(Fmt.int(over)) over your \(m) size\(items.count > 1 && top != nil ? ", mostly the \(top!)" : ""). A smaller portion of it next time."))
        }
        if meal == "Dinner", left < 0 { better.append(("📅", "\(Fmt.int(-left)) over today. Nothing to make up: tomorrow starts fresh.")) }
        if !better.isEmpty, !Self.has(todayItems, Self.vegWords) {
            better.append(("🥦", "No veg today yet. Some salad, cherry tomatoes or frozen peas on the side is an easy start."))
        }

        let names = items.map { str($0["name"]) }.filter { !$0.isEmpty }
        var pop = MealPop(kind: .after, meal: meal, title: better.isEmpty ? "Nice \(m)" : "About your \(m)",
                          meta: names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " and more" : "") + " · \(Fmt.int(kcal)) kcal")
        pop.stats = [
            .init(value: known ? "\(Int(p)) g" : "–", label: "protein", tone: short ? .warn : (proper || dense ? .good : .plain)),
            .init(value: Fmt.int(kcal), label: "of \(Fmt.int(size.kcal)) kcal", tone: overMatters ? .warn : (over <= 60 ? .good : .plain)),
            .init(value: Fmt.int(left), label: "left today", tone: left < 0 ? .warn : .plain)
        ]
        pop.parts.append(.init(title: "What went right", tone: .good, lines: Array(good.prefix(3))))
        if !better.isEmpty { pop.parts.append(.init(title: "To do better", tone: .warn, lines: better)) }
        else if meal == "Lunch" {
            let t = mealTarget("Dinner")
            let prot = t.protein.map { " and \(Int((($0) / 5).rounded() * 5)) g protein" } ?? ""
            pop.parts.append(.init(title: "For dinner", lines: [("🎯", "About \(Fmt.int(t.kcal)) kcal\(prot) keeps today on track.")]))
        }
        // two meals to try next time, when it was short: your own food plan's first, the most protein
        if short {
            let own = habitIdeas.filter { str($0["meal"]) == meal }
            pop.ideas = Array((own.isEmpty ? Self.easyMeals.filter { str($0["meal"]) == meal } : own)
                .filter { (num($0["protein"]) ?? 0) >= Self.lightLimit(meal) }
                .sorted { (num($0["protein"]) ?? 0) > (num($1["protein"]) ?? 0) }.prefix(2))
        }
        pop.placeholder = meal == "Lunch" ? "Ask about it, or plan dinner" : "Ask about it, or something sweet that fits?"
        return pop
    }
}
