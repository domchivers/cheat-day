import Foundation

/// Something you usually have at a meal, and what you'd like to do about it: keep it as it is, tweak it (the same
/// food, less of it or a lighter version) or swap it for something that does the same job.
struct Habit: Identifiable, Equatable {
    var id = UUID().uuidString
    var meal: String
    var name: String
    var perWeek: Double?
    var choice = "keep"
    var tweak = ""
    var swap = ""
    var tweakSave = 0.0   // kcal saved each time; negative when the tweak adds something (an egg for protein)
    var swapSave = 0.0
    var asked = false     // the AI has had a look at it

    init(meal: String, name: String, perWeek: Double? = nil) { self.meal = meal; self.name = name; self.perWeek = perWeek }

    init(_ j: JSON) {
        id = str(j["id"]).isEmpty ? UUID().uuidString : str(j["id"])
        meal = str(j["meal"]); name = str(j["name"]); perWeek = pos(j["perWeek"])
        choice = str(j["choice"]).isEmpty ? "keep" : str(j["choice"])
        tweak = str(j["tweak"]); swap = str(j["swap"])
        tweakSave = num(j["tweakSave"]) ?? 0; swapSave = num(j["swapSave"]) ?? 0
        asked = !tweak.isEmpty || !swap.isEmpty
    }

    var json: JSON {
        ["id": id, "meal": meal, "name": name, "perWeek": perWeek.map { $0 as Any } ?? NSNull(), "choice": choice,
         "tweak": tweak, "swap": swap, "tweakSave": tweakSave, "swapSave": swapSave]
    }

    var often: String {
        guard let w = perWeek else { return "" }
        if w >= 5.5 { return "daily" }
        if w >= 3.5 { return "most days" }
        if w >= 1 { return "\(Int(w.rounded()))× a week" }
        return "now and then"
    }

    /// What the choice is, in a line ("2 pints, not 4"), or nil when it's kept.
    var plan: String? {
        switch choice {
        case "tweak": return tweak.isEmpty ? nil : tweak
        case "swap": return swap.isEmpty ? nil : swap
        default: return nil
        }
    }

    /// kcal a week the choice saves, at how often you have it (3 times a week when nobody knows).
    var weekSave: Double { (choice == "tweak" ? tweakSave : choice == "swap" ? swapSave : 0) * (perWeek ?? 3) }
}

enum Habits {
    static let goals = ["More protein", "More veg", "Fewer evening snacks", "Less takeaway", "Weekends", "Less sugar", "Drink less", "Smaller portions", "Eat out smarter", "More water"]
}

extension Store {
    var habits: JSON { dict(dict(doc["prefs"])["habits"]) }
    var habitItems: [Habit] { list(habits["items"]).map(Habit.init) }

    /// Everyone answers the food habits questions once, website users too; "Not now" counts as answered.
    var needsHabits: Bool { lastSynced != nil && !needsOnboarding && habits.isEmpty }

    func saveHabits(_ h: JSON) { perform(["type": "habits", "value": h]) }

    /// What you've had at each meal on at least two days in the last four weeks, most often first, up to five a meal.
    func loggedHabits() -> [Habit] {
        let since = DayKey.shift(today, days: -28)
        let days: [(String, [JSON])] = [(today, todayItems)] + list(doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < today }.map { (str($0["date"]), list($0["items"])) }
        var seen: [String: (meal: String, name: String, days: Set<String>)] = [:]
        for (date, items) in days {
            for it in items {
                let n = str(it["name"]).trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { continue }
                let m = Meals.of(it), k = m + "|" + n.lowercased()
                seen[k, default: (m, n, [])].days.insert(date)
            }
        }
        let weeks = min(4, max(1, Double(days.filter { !$0.1.isEmpty }.count) / 7))
        return Meals.all.flatMap { meal in
            seen.values.filter { $0.meal == meal && $0.days.count >= 2 }
                .sorted { ($0.days.count, $1.name) > ($1.days.count, $0.name) }
                .prefix(5)
                .map { Habit(meal: meal, name: $0.name, perWeek: Double($0.days.count) / weeks) }
        }
    }

    /// One thing to work on for the week a day is in: the tweaks, swaps and tips take turns, a new one each Monday.
    func habitFocus(on date: String) -> String? {
        var lines = habitItems.compactMap { h -> String? in
            guard let p = h.plan else { return nil }
            return h.choice == "swap" ? "\(h.name) → \(p)" : "\(h.name): \(p)"
        }
        lines += habits["tips"] as? [String] ?? []
        guard !lines.isEmpty else { return nil }
        let week = Int((DayKey.date(Self.weekOf(date)).timeIntervalSince1970 / 604_800).rounded())
        return lines[((week % lines.count) + lines.count) % lines.count]
    }
    var habitFocus: String? { habitFocus(on: today) }

    /// The food plan in a line or two for the assistant: what to leave alone, what they're cutting back on.
    var habitsContext: String {
        let items = habitItems
        guard !items.isEmpty || !(habits["goals"] as? [String] ?? []).isEmpty else { return "" }
        let keep = items.filter { $0.choice == "keep" }.map(\.name)
        let change = items.compactMap { h in h.plan.map { "\(h.name) (\(h.choice): \($0))" } }
        var c = "Their own food plan: "
        if let g = habits["goals"] as? [String], !g.isEmpty { c += "they want \(g.joined(separator: ", ").lowercased()). " }
        if !keep.isEmpty { c += "Keeping as they are, never nag about: \(keep.joined(separator: ", ")). " }
        if !change.isEmpty { c += "Changing: \(change.joined(separator: "; ")). Nudge gently towards these when they come up." }
        return c + "\n"
    }
}
