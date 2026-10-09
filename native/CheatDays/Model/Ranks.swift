import SwiftUI

/// A rank: six food tiers with three steps each (Legend has none), built on the website's XP and levels so both always agree.
struct Rank: Equatable {
    static let tiers = ["Crumb", "Toast", "Dumpling", "Burger", "Feast", "Legend"]
    let level: Int
    var tier: Int { min(5, (level - 1) / 3) }
    var step: Int? { tier == 5 ? nil : (level - 1) % 3 + 1 }
    var key: String { Self.tiers[tier].lowercased() }
    var tierName: String { Self.tiers[tier] }
    var name: String { step.map { "\(tierName) \(["I", "II", "III"][$0 - 1])" } ?? tierName }

    var color: Color { Self.colors[tier].0 }
    var dark: Color { Self.colors[tier].1 }
    var light: Color { Self.colors[tier].2 }
    private static let colors: [(Color, Color, Color)] = [
        (Color(red: 0.79, green: 0.59, blue: 0.36), Color(red: 0.36, green: 0.24, blue: 0.13), Color(red: 0.93, green: 0.78, blue: 0.58)),
        (Color(red: 0.62, green: 0.72, blue: 0.82), Color(red: 0.30, green: 0.36, blue: 0.43), Color(red: 0.88, green: 0.92, blue: 0.96)),
        (Color(red: 0.36, green: 0.79, blue: 0.65), Color(red: 0.06, green: 0.33, blue: 0.29), Color(red: 0.70, green: 0.95, blue: 0.85)),
        (Color(red: 0.94, green: 0.47, blue: 0.29), Color(red: 0.45, green: 0.17, blue: 0.08), Color(red: 1.0, green: 0.76, blue: 0.58)),
        (Color(red: 0.62, green: 0.55, blue: 0.94), Color(red: 0.24, green: 0.20, blue: 0.52), Color(red: 0.85, green: 0.81, blue: 1.0)),
        (Color(red: 0.98, green: 0.78, blue: 0.46), Color(red: 0.48, green: 0.33, blue: 0.05), Color(red: 1.0, green: 0.93, blue: 0.70))
    ]

    /// The first level of each tier, for the ladder.
    static func first(ofTier t: Int) -> Rank { Rank(level: t * 3 + 1) }

    // the website's levelFor: level n needs (n - 1)² × 100 XP
    static func level(for xp: Int) -> Int { Int((Double(xp) / 100).squareRoot()) + 1 }
    static func xp(forLevel n: Int) -> Int { (n - 1) * (n - 1) * 100 }
}

enum XPRules {
    // the website's XP table
    static let item = 2, itemCap = 10, log = 10, under = 25, protein = 15, workout = 20, pb = 30, post = 5, goal = 50
    /// XP each website badge adds once earned (read from app.js's BADGES: tiers 25/50/100/200/400/800, one-offs 50).
    static let badges: [String: Int] = [
        "first": 25, "days10": 50, "days50": 100, "days100": 200, "days250": 400, "streak3": 25, "streak7": 50, "streak14": 100, "streak30": 200, "streak100": 400, "streak365": 800,
        "rest1": 25, "under3": 25, "under7": 50, "under14": 100, "under30": 200, "ud10": 25, "ud50": 50, "ud100": 100, "cheat1": 25, "protein5": 25, "protein20": 50, "protein50": 100,
        "foods25": 25, "foods100": 50, "scan1": 25, "scan25": 50, "photo1": 25, "photo25": 50, "meal1": 25, "meal10": 50, "recipe1": 25, "ask1": 25, "wo1": 25, "wo10": 50, "wo25": 100,
        "wo50": 200, "wo100": 400, "min600": 25, "min3000": 50, "burn10k": 25, "pb": 25, "pb10": 50, "pb25": 100, "routine1": 25, "weigh1": 25, "weigh10": 50, "weigh50": 100,
        "lost1": 25, "lost5": 50, "lost10": 100, "friend1": 25, "friend5": 50, "post1": 25, "post10": 50, "post50": 100, "react10": 25, "comment10": 25, "send1": 25, "lvl5": 25,
        "lvl10": 50, "lvl20": 100, "goal": 25, "goal10": 50, "goal50": 100, "perfect1": 25, "perfect5": 50, "early": 50, "owl": 50, "comeback": 50, "weekend": 50, "goalset": 50, "goalhit": 50
    ]
    static let ways: [(String, String)] = [
        ("Log any food in a day", "+\(log)"), ("Each food you log (up to \(itemCap) a day)", "+\(item)"), ("Finish a day under budget", "+\(under)"),
        ("Hit your protein goal", "+\(protein)"), ("Log a workout", "+\(workout)"), ("Beat a lifting best", "+\(pb)"),
        ("Finish a weekly goal", "+\(goal)"), ("Post to the feed", "+\(post)"), ("Earn a badge", "+25 to +800")
    ]
}

extension Store {
    /// Total XP, worked out from what's recorded like the website's totalXp, so it can't be double counted or lost.
    /// Past days count logging, budget, protein, workouts and foods; today counts only logging, workouts and foods until it's over.
    var totalXP: Int {
        cached("xp") {
            let goalP = proteinGoal ?? 0
            var xp = 0
            func food(_ items: [JSON]) -> Int { min(items.count, XPRules.itemCap) * XPRules.item }
            func past(items: [JSON], kcal: Double, budget: Double, p: Double, workouts: Int) {
                let logged = !items.isEmpty || kcal > 0
                if logged { xp += XPRules.log }
                if logged && budget > 0 && kcal <= budget { xp += XPRules.under }
                if logged && goalP > 0 && p >= goalP { xp += XPRules.protein }
                xp += workouts * XPRules.workout + food(items)
            }
            for h in list(doc["history"]) {
                past(items: list(h["items"]), kcal: num(h["kcal"]) ?? 0, budget: num(h["budget"]) ?? 0, p: num(h["p"]) ?? 0, workouts: list(h["workouts"]).count)
            }
            let d = day
            if str(d["date"]) != today, let pd = pastDay(str(d["date"])), !list(d["items"]).isEmpty || !list(d["workouts"]).isEmpty {
                past(items: pd.items, kcal: pd.kcal, budget: pd.budget, p: macros(pd.items).p, workouts: list(d["workouts"]).count)   // yesterday, not filed yet
            }
            if !todayItems.isEmpty { xp += XPRules.log }
            xp += todayWorkouts.count * XPRules.workout + food(todayItems)
            xp += Int(num(doc["pbCount"]) ?? 0) * XPRules.pb + Int(num(doc["postCount"]) ?? 0) * XPRules.post
            xp += ((doc["goalWins"] as? [Any])?.count ?? 0) * XPRules.goal
            xp += (doc["seenBadges"] as? [String] ?? []).reduce(0) { $0 + (XPRules.badges[$1] ?? 0) }
            return xp
        }
    }

    var rank: Rank { Rank(level: Rank.level(for: totalXP)) }
}
