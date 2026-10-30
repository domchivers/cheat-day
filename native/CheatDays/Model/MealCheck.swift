import Foundation

/// A word after lunch or dinner, when it was light: hardly any protein (toast, crumpets, a biscuit) isn't really a main
/// meal. How often that's happened this week, a fix for next time and two meals to try. Bread with something proper on
/// it (eggs on toast, a ham sandwich) is fine. Worked out on the phone.
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

    /// Below this much protein a lunch or dinner is light: not really a main meal.
    static func lightLimit(_ meal: String) -> Double { meal == "Dinner" ? 20 : 15 }
    /// A real lunch or dinner (not a cup of tea) with hardly any protein. Only judged when most of it has its macros:
    /// a curry logged as calories alone isn't light, it's unknown.
    func isLight(_ items: [JSON], meal: String) -> Bool {
        let kcal = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let known = items.filter { FoodMath.macros($0, kcal: num($0["kcal"]) ?? 0) != nil }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return kcal >= 80 && known >= kcal * 0.7 && macros(items).p < Self.lightLimit(meal)
    }

    /// The last week's lunches and dinners, today's included: how many were light, out of how many, and a couple of
    /// the foods in them ("toast", "crumpets").
    func lightMainMeals(only meal: String? = nil) -> (light: Int, of: Int, examples: [String]) {
        let since = DayKey.shift(today, days: -6)
        var days: [[JSON]] = list(doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < today }.map { list($0["items"]) }
        days.append(todayItems)
        var light = 0, of = 0, names: [String: Int] = [:]
        for items in days {
            for m in ["Lunch", "Dinner"] where meal == nil || meal == m {
                let its = items.filter { Meals.of($0) == m }
                guard its.reduce(0, { $0 + (num($1["kcal"]) ?? 0) }) >= 80 else { continue }
                of += 1
                if isLight(its, meal: m) {
                    light += 1
                    for it in its { names[Self.shortName(str(it["name"])), default: 0] += 1 }
                }
            }
        }
        let examples = names.filter { !$0.key.isEmpty }.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        return (light, of, examples)
    }

    /// "Toast with butter, 2 slices" → "toast with butter": short enough to name in a sentence.
    private static func shortName(_ s: String) -> String {
        s.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// The check for a meal just logged today, or nil when it's a proper meal (or not lunch or dinner, or a cheat day).
    func mealCheck(_ meal: String) -> MealCheck? {
        guard meal == "Lunch" || meal == "Dinner", !isCheatDay(today) else { return nil }
        let items = todayItems.filter { Meals.of($0) == meal }
        guard isLight(items, meal: meal) else { return nil }
        let kcal = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let p = Int(macros(items).p.rounded())
        let names = items.map { str($0["name"]) }.filter { !$0.isEmpty }
        let first = names.first.map { Self.shortName($0) } ?? "it"
        let m = meal.lowercased()
        var c = MealCheck(meal: meal, foods: names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " and more" : ""), kcal: kcal)

        c.lines.append(("🍽️", "\(first.prefix(1).uppercased() + first.dropFirst()) isn't really a \(m): only \(p) g protein. A main meal needs some to keep you full."))
        let week = lightMainMeals(only: meal)
        if week.light >= 3 { c.lines.append(("📅", "Light \(m)s \(week.light) times in the last \(week.of) \(meal == "Dinner" ? "nights" : "days").")) }
        if meal == "Dinner", let goal = proteinGoal {
            c.lines.append(("🥚", "You've had \(Int(macros(todayItems).p)) of \(Int(goal)) g protein today. Dinner is the best meal to catch up."))
        }
        if !Self.has(items, Self.vegWords) {
            c.lines.append(("🥦", "No veg in it. A few cherry tomatoes, some salad or a handful of frozen peas on the side is an easy start."))
        }
        c.lines.append(("🎯", Self.breadHeavy(items)
            ? "Next time, put something on it: eggs, beans, tuna or cheese turn \(first) into a meal."
            : "Next time, add some protein: chicken, fish, eggs, beans, cheese or Greek yoghurt."))

        // two meals to try: your own food plan's ideas first, the most protein, never another light one
        let own = habitIdeas.filter { str($0["meal"]) == meal }
        let pool = (own.isEmpty ? Self.easyMeals.filter { str($0["meal"]) == meal } : own)
            .filter { (num($0["protein"]) ?? 0) >= Self.lightLimit(meal) }
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
