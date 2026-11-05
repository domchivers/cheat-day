import Foundation

/// The card under Today's numbers: how the last 7 days went against the goals, what's working, and the one thing to
/// fix when something isn't. It replaced "swap your protein brownie": a food was flagged for coming up often, even
/// when it was helping and every goal was being hit.
struct WeekReview: Equatable {
    struct Row: Equatable { let label: String; let value: String; let ok: Bool }
    let icon: String
    let title: String
    let rows: [Row]
    let tip: String
    var plan: String? = nil   // a meal to get ideas for

    /// One logged day: its foods, budget and calories.
    struct Day { let items: [JSON]; let budget: Double; let kcal: Double }

    /// Most of the days, so one cheat or party day doesn't turn a good week amber: 5 of 7, 4 of 5, 3 of 4, 3 of 3.
    static func mostly(_ n: Int, of total: Int) -> Bool { total > 0 && Double(n) >= Double(total) * 0.7 }

    static func protein(_ it: JSON) -> Double { FoodMath.macros(it, kcal: num(it["kcal"]) ?? 0)?.p ?? 0 }

    /// High in protein for its calories (a quarter or more of them from protein): never a swap, and worth a mention.
    static func proteinRich(_ it: JSON) -> Bool {
        let k = num(it["kcal"]) ?? 0
        return k > 0 && protein(it) * 4 / k >= 0.25
    }

    /// Needs 3 logged days. Swap is the lighter pick for something they keep having, offered only when it's over budget.
    static func make(days: [Day], proteinGoal: Double?, pace: Double?, want: Double?,
                     swap: (food: String, saves: Double, pick: String, days: Int)? = nil) -> WeekReview? {
        let days = days.filter { !$0.items.isEmpty }
        guard days.count >= 3 else { return nil }
        let n = days.count

        let under = days.filter { $0.kcal <= $0.budget + 50 }.count
        let budgetOK = mostly(under, of: n)
        var rows = [Row(label: "Within budget", value: "\(under) of \(n) days", ok: budgetOK)]

        var proteinOK = true, short: [Day] = []
        if let goal = proteinGoal, goal > 0 {
            short = days.filter { d in d.items.reduce(0) { $0 + protein($1) } < goal * 0.9 }
            proteinOK = mostly(n - short.count, of: n)
            rows.append(Row(label: "Protein goal hit", value: "\(n - short.count) of \(n) days", ok: proteinOK))
        }

        var weightOK = true
        if let pace {
            let w = want ?? 0
            weightOK = w < 0 ? pace <= w / 3 : w > 0 ? pace >= w / 3 : abs(pace) < 0.25
            rows.append(Row(label: "Weight", value: "\(pace > 0.05 ? "+" : pace < -0.05 ? "−" : "")\(Fmt.one(abs(pace))) kg a week", ok: weightOK))
        }

        // all good: say so, and name something that's helping
        if budgetOK && proteinOK && weightOK {
            var tip = "Keep doing what you're doing."
            if let star = favourite(days, where: proteinRich) {
                tip += " Your \(star.name.lowercased())'s earning its place: \(Int(star.p.rounded())) g protein for \(Int(star.kcal.rounded())) kcal."
            }
            return WeekReview(icon: "🎯", title: "On track this week", rows: rows, tip: tip)
        }
        let misses = [budgetOK, proteinOK, weightOK].filter { !$0 }.count
        func titled(_ s: String) -> String { misses == 1 ? "Nearly there: \(s)" : s.prefix(1).uppercased() + s.dropFirst() }

        if !budgetOK {
            let over = days.filter { $0.kcal > $0.budget + 50 }
            let by = over.isEmpty ? 0 : over.reduce(0) { $0 + $1.kcal - $1.budget } / Double(over.count)
            let snacks = days.flatMap(\.items).filter { Meals.of($0) == "Snacks" }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
            let all = days.reduce(0) { $0 + $1.kcal }
            let tip: String
            if let s = swap { tip = "Your \(s.food.lowercased()) came up \(s.days) days. \(s.pick) instead saves \(Fmt.int(s.saves)) kcal each time." }
            else if all > 0, snacks / all > 0.22 { tip = "Snacks are \(Int(snacks / all * 100))% of your food: the easiest place to trim." }
            else { tip = "The over days ran about \(Fmt.int(by)) kcal past budget: one lighter meal on those days would do it." }
            return WeekReview(icon: "⚖️", title: titled("a few days over budget"), rows: rows, tip: tip)
        }
        if !proteinOK {
            // the main meal with the least protein on the short days
            let meals = ["Breakfast", "Lunch", "Dinner"].map { m -> (meal: String, avg: Double) in
                let per = short.map { d in d.items.filter { Meals.of($0) == m }.reduce(0) { $0 + protein($1) } }
                return (m, per.isEmpty ? 0 : per.reduce(0, +) / Double(per.count))
            }
            let low = meals.min { $0.avg < $1.avg } ?? ("Dinner", 0)
            let name = low.meal == "Lunch" ? "Lunches" : low.meal + "s"
            let idea = low.meal == "Breakfast" ? "Eggs or Greek yoghurt" : "A chicken, fish or lean beef \(low.meal.lowercased())"
            return WeekReview(icon: "🥚", title: titled("protein's short"), rows: rows,
                              tip: "\(name) are where it drops: about \(Int(low.avg.rounded())) g on the short days. \(idea) would close the gap.", plan: low.meal)
        }
        return WeekReview(icon: "📉", title: titled("weight's not moving"), rows: rows,
                          tip: "Your days look good on paper, so the gap is usually what doesn't get logged: drinks, bites and oil. Log everything for a week.")
    }

    /// The food that came up on the most days (3 or more) among those that pass the test, with its usual numbers.
    static func favourite(_ days: [Day], where pass: (JSON) -> Bool) -> (name: String, p: Double, kcal: Double)? {
        var seen: [String: (days: Int, p: Double, kcal: Double)] = [:]
        for d in days {
            var today = Set<String>()
            for it in d.items where pass(it) {
                let n = str(it["name"]); guard !n.isEmpty, !today.contains(n) else { continue }
                today.insert(n)
                let e = seen[n, default: (0, 0, 0)]
                seen[n] = (e.days + 1, protein(it), num(it["kcal"]) ?? 0)
            }
        }
        // most days first; a tie goes to the name first in the alphabet, so it's the same one every time
        guard let best = seen.filter({ $0.value.days >= 3 })
            .max(by: { ($0.value.days, $1.key) < ($1.value.days, $0.key) }) else { return nil }
        return (best.key, best.value.p, best.value.kcal)
    }
}

extension Store {
    /// The last 7 days before today, as the review sees them.
    var weekReview: WeekReview? {
        let days = (1...7).compactMap { i -> WeekReview.Day? in
            guard let p = pastDay(DayKey.shift(today, days: -i)) else { return nil }
            return WeekReview.Day(items: p.items, budget: p.budget, kcal: p.kcal)
        }
        let c = checkIn
        let s = weekSwap.map { (food: $0.food, saves: $0.pick.saves, pick: $0.pick.name, days: $0.days) }
        return WeekReview.make(days: days, proteinGoal: proteinGoal, pace: c.pace, want: c.want, swap: s)
    }
}
