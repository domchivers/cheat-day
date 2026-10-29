import Foundation

/// A word after lunch or dinner, when there's something to help with: too little protein, no veg, mostly bread, or the
/// same bread meal day after day. Plain advice, a fix for next time and two meals to try. Worked out on the phone.
struct MealCheck: Identifiable {
    var id: String { meal }
    let meal: String
    let foods: String
    let kcal: Double
    var lines: [(icon: String, text: String)] = []
    var ideas: [JSON] = []
}

extension Store {
    static let breadWords = #"\b(bread|toast|sandwich|bagel|wrap|baguette|roll|sourdough|crumpet|pitta|pita|muffin|scone|crackers?|crispbread|ryvita)s?\b"#
    static let vegWords = #"\b(veg|veggies|vegetables?|salad|tomato(es)?|broccoli|peppers?|carrots?|peas|beans|spinach|lettuce|cucumber|onions?|mushrooms?|courgette|zucchini|cabbage|sweetcorn|corn|kale|cauliflower|avocado|leeks?|celery|asparagus|green beans|sprouts|stir ?fry|soup|coleslaw|beetroot|rocket|squash|aubergine|eggplant)\b"#

    private static func has(_ items: [JSON], _ pattern: String) -> Bool {
        items.contains { str($0["name"]).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    }
    /// Mostly bread: bread foods are most of the meal's calories.
    static func breadHeavy(_ items: [JSON]) -> Bool {
        let all = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let bread = items.filter { str($0["name"]).range(of: breadWords, options: [.regularExpression, .caseInsensitive]) != nil }
            .reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return all > 0 && bread / all >= 0.55
    }

    /// The check for a meal just logged today, or nil when it's fine (or not lunch or dinner, or a cheat day).
    func mealCheck(_ meal: String) -> MealCheck? {
        guard meal == "Lunch" || meal == "Dinner", !isCheatDay(today) else { return nil }
        let items = todayItems.filter { Meals.of($0) == meal }
        let kcal = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        guard kcal >= 80 else { return nil }
        let p = macros(items).p
        let target = proteinGoal.map { $0 * (meal == "Dinner" ? 0.35 : 0.3) } ?? 20
        let lowProtein = p < target * 0.6
        let noVeg = !Self.has(items, Self.vegWords)
        let bready = Self.breadHeavy(items)

        // the last week's lunches and dinners (today's included): how many were mostly bread
        var meals: [[JSON]] = []
        let since = DayKey.shift(today, days: -6)
        for h in list(doc["history"]) where str(h["date"]) >= since && str(h["date"]) < today {
            for m in ["Lunch", "Dinner"] { let its = list(h["items"]).filter { Meals.of($0) == m }; if !its.isEmpty { meals.append(its) } }
        }
        for m in ["Lunch", "Dinner"] { let its = todayItems.filter { Meals.of($0) == m }; if !its.isEmpty { meals.append(its) } }
        let breadMeals = meals.filter(Self.breadHeavy).count
        let sameMealDays = 1 + list(doc["history"]).filter { h in
            str(h["date"]) >= since && str(h["date"]) < today && Self.breadHeavy(list(h["items"]).filter { Meals.of($0) == meal })
        }.count

        guard lowProtein || (noVeg && bready) || (bready && breadMeals >= 5) else { return nil }
        let names = items.map { str($0["name"]) }.filter { !$0.isEmpty }
        var c = MealCheck(meal: meal, foods: names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " and more" : ""), kcal: kcal)
        let m = meal.lowercased()

        if bready && sameMealDays >= 3 { c.lines.append(("📅", "Bread for \(m) \(sameMealDays) \(meal == "Dinner" ? "nights" : "days") this week.")) }
        if lowProtein {
            if meal == "Dinner", let goal = proteinGoal {
                c.lines.append(("🥚", "You've had \(Int(macros(todayItems).p)) of \(Int(goal)) g protein today. Dinner is the best meal to catch up."))
            } else {
                c.lines.append(("🥚", "Only \(Int(p.rounded())) g protein. Protein is what keeps you full until \(meal == "Lunch" ? "dinner" : "the morning")."))
            }
        }
        if noVeg { c.lines.append(("🥦", "No veg in it. A few cherry tomatoes, some salad or a handful of frozen peas on the side is an easy start.")) }
        if bready && breadMeals >= 5 {
            c.lines.append(("🍞", "Bread's in \(breadMeals) of your last \(meals.count) lunches and dinners. Try something other than bread for one meal a day: a jacket potato, rice, soup with beans, or eggs."))
        } else if bready && lowProtein {
            c.lines.append(("🎯", "Next time, add an egg, beans, tuna or cheese to your \(names.first.map { $0.lowercased() } ?? "bread")."))
        } else if lowProtein {
            c.lines.append(("🎯", "Next time, add some protein: chicken, fish, eggs, beans, cheese or Greek yoghurt."))
        }

        // two meals to try: your own food plan's ideas first, the most protein, not bread when bread's the problem
        let own = habitIdeas.filter { str($0["meal"]) == meal }
        let pool = (own.isEmpty ? Self.easyMeals.filter { str($0["meal"]) == meal } : own)
            .filter { !(bready && Self.breadHeavy([$0])) }
            .sorted { (num($0["protein"]) ?? 0) > (num($1["protein"]) ?? 0) }
        c.ideas = Array(pool.prefix(2))
        return c
    }

    /// Simple, familiar meals for when there's no food plan to pick from.
    static let easyMeals: [JSON] = [
        ["meal": "Lunch", "name": "Beans on toast with cheese", "kcal": 380, "protein": 22, "carbs": 48, "fat": 11],
        ["meal": "Lunch", "name": "Tuna jacket potato with salad", "kcal": 420, "protein": 30, "carbs": 55, "fat": 7],
        ["meal": "Lunch", "name": "Cheese omelette with salad", "kcal": 360, "protein": 24, "carbs": 4, "fat": 27],
        ["meal": "Lunch", "name": "Lentil and vegetable soup", "kcal": 300, "protein": 16, "carbs": 45, "fat": 5],
        ["meal": "Dinner", "name": "Chicken, potatoes and peas", "kcal": 450, "protein": 35, "carbs": 45, "fat": 12],
        ["meal": "Dinner", "name": "Salmon, rice and broccoli", "kcal": 520, "protein": 34, "carbs": 50, "fat": 18],
        ["meal": "Dinner", "name": "Fish fingers, mash and beans", "kcal": 480, "protein": 24, "carbs": 60, "fat": 15],
        ["meal": "Dinner", "name": "Chilli con carne with rice", "kcal": 550, "protein": 32, "carbs": 62, "fat": 16]
    ]
}
