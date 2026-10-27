import Foundation

/// Healthier picks for the foods people log most, from the built-in food list: no AI, so they show instantly and cost
/// nothing. Shown when you add one of these, and on Today when one keeps coming up in your week.
enum Swaps {
    private static let table: [(pattern: String, to: String, why: String)] = [
        (#"\b(crisps|doritos|pringles|kettle chips|quavers|wotsits|walkers)\b"#, "Popcorn, salted", "Same crunch, far fewer calories"),
        (#"\b(coca.?cola|coke|pepsi|fanta|sprite|lemonade|irn.?bru|dr pepper)\b(?!.*(zero|diet|max))"#, "Coke Zero / Diet Coke", "Same fizz, no sugar"),
        (#"\b(milk chocolate|chocolate bar|dairy milk|snickers|mars|twix|kit ?kat|galaxy|wispa|twirl|maltesers)\b"#, "Protein bar", "Still sweet, with 20 g protein"),
        (#"\b(biscuits?|cookies?|digestives?|hobnobs?|shortbread|bourbons?|custard creams?)\b"#, "Protein bar", "Fills you up for longer"),
        (#"\b(cake|muffin|brownie|doughnut|donut|cupcake|flapjack)\b"#, "Protein bar", "A sweet fix with protein"),
        (#"\bice cream\b"#, "Greek yogurt, 0% fat", "Cold and creamy, with protein"),
        (#"^(chips|fries|chunky chips|french fries)\b|\bchippy chips\b"#, "Oven chips", "Half the oil"),
        (#"\bmayo(nnaise)?\b(?!.*light)"#, "Light mayonnaise", "Tastes the same, a third of the calories"),
        (#"\b(whole milk|milk, whole|full.?fat milk)\b"#, "Milk, semi-skimmed", "Barely tastes different"),
        (#"greek yogh?urt, full fat|\bfull.?fat (greek )?yogh?urt\b"#, "Greek yogurt, 0% fat", "Same thickness, more protein"),
        (#"\b(double|single|whipping) cream\b"#, "Greek yogurt, 0% fat", "Creamy, a fraction of the calories"),
        (#"\b(beer|lager|pint|ale|ipa|stout|cider)\b(?!.*light)"#, "Light beer", "Still a pint, fewer calories"),
        (#"\b(croissant|pain au chocolat|pain au raisin|danish)\b"#, "Crumpet", "Warm and buttery, much lighter")
    ]

    struct Pick { let name: String; let why: String; let basis: JSON; let kcal: Double; let saves: Double }

    /// A lighter pick for a food, if there's one that saves at least 40 kcal at its usual portion.
    static func pick(for name: String, kcal: Double) -> Pick? {
        let n = name.lowercased()
        guard kcal > 60, let row = table.first(where: { n.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }),
              n != row.to.lowercased(), let food = FoodsDB.rows.first(where: { str($0.first) == row.to }) else { return nil }
        let basis = FoodMath.foodItem(food)
        let k = (pos(basis["kcalPerServing"]) ?? (pos(basis["kcalPer100"]) ?? 0) * (pos(basis["servingSize"]) ?? 100) / 100).rounded()
        guard k > 0, kcal - k >= 40 else { return nil }
        return Pick(name: row.to, why: row.why, basis: basis, kcal: k, saves: kcal - k)
    }
}

extension Store {
    /// The food you have most often this week that has a lighter pick, with what swapping it would save.
    var weekSwap: (food: String, pick: Swaps.Pick, days: Int)? {
        var seen: [String: (days: Set<String>, kcal: Double)] = [:]
        for h in list(doc["history"]).prefix(7) {
            for it in list(h["items"]) {
                let n = str(it["name"]); guard let k = num(it["kcal"]), k > 60 else { continue }
                seen[n, default: ([], 0)].days.insert(str(h["date"]))
                seen[n]?.kcal = max(seen[n]?.kcal ?? 0, k)
            }
        }
        return seen.filter { $0.value.days.count >= 3 }
            .sorted { $0.value.days.count > $1.value.days.count }
            .compactMap { e -> (food: String, pick: Swaps.Pick, days: Int)? in
                guard let p = Swaps.pick(for: e.key, kcal: e.value.kcal) else { return nil }
                return (e.key, p, e.value.days.count)
            }
            .first
    }
}
