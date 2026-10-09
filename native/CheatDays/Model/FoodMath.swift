import Foundation

/// Ports of the web app's food maths, so both apps show the same numbers for the same item.
enum FoodMath {
    static let basisKeys = ["name", "brand", "source", "unit", "unitLabel", "kcalPer100", "servingSize", "kcalPerServing",
                            "packSize", "piecesPerPack", "image", "photo", "mealId", "p100", "c100", "f100", "pServ", "cServ", "fServ"]

    /// The parts of an item that describe the food itself (the web app's basisOf). Photos taken on the phone stay out.
    static func basisOf(_ item: JSON) -> JSON {
        var b: JSON = [:]
        for k in basisKeys {
            guard let v = item[k], !(v is NSNull) else { continue }
            if let s = v as? String, s.isEmpty { continue }
            b[k] = v
        }
        if let img = b["image"] as? String, img.hasPrefix("data:") { b["image"] = nil }
        return b
    }

    static func kcalPer100(_ b: JSON) -> Double? {
        if let k = pos(b["kcalPer100"]) { return k }
        if let s = pos(b["kcalPerServing"]), let size = pos(b["servingSize"]) { return s / size * 100 }
        return nil
    }

    struct Amounts { var grams: Double?; var servings: Double?; var pieces: Double?; var packFraction: Double?; var unit: String }

    static func amounts(_ b: JSON, kcal: Double) -> Amounts {
        var a = Amounts(unit: str(b["unit"]).isEmpty ? "g" : str(b["unit"]))
        if let k100 = kcalPer100(b) { a.grams = kcal / k100 * 100 }
        if let serv = pos(b["kcalPerServing"]) { a.servings = kcal / serv }
        else if let size = pos(b["servingSize"]), let g = a.grams { a.servings = g / size }
        if let pack = pos(b["packSize"]), let g = a.grams {
            a.packFraction = g / pack
            if let pieces = pos(b["piecesPerPack"]) { a.pieces = g / pack * pieces }
        }
        return a
    }

    /// Protein, carbs and fat for this amount, or nil when the item doesn't carry them.
    static func macros(_ b: JSON, kcal: Double) -> (p: Double, c: Double, f: Double)? {
        let a = amounts(b, kcal: kcal)
        if let g = a.grams, let p = num(b["p100"]) { return (g * p / 100, g * (num(b["c100"]) ?? 0) / 100, g * (num(b["f100"]) ?? 0) / 100) }
        if let s = a.servings, let p = num(b["pServ"]) { return (s * p, s * (num(b["cServ"]) ?? 0), s * (num(b["fServ"]) ?? 0)) }
        return nil
    }

    /// What can be counted: kcal per 100 and kcal per piece or serving (the web app's conv).
    struct Conv { var kcalPer100: Double?; var countKcal: Double?; var countLabel: String? }
    static func conv(_ b: JSON) -> Conv {
        let k100 = kcalPer100(b)
        let label = str(b["unitLabel"])
        if let pieces = pos(b["piecesPerPack"]), let pack = pos(b["packSize"]), let k100 {
            return Conv(kcalPer100: k100, countKcal: pack / pieces * k100 / 100, countLabel: label.isEmpty ? "piece" : label)
        }
        if let serv = pos(b["kcalPerServing"]) { return Conv(kcalPer100: k100, countKcal: serv, countLabel: label.isEmpty ? "serving" : label) }
        if let size = pos(b["servingSize"]), let k100 { return Conv(kcalPer100: k100, countKcal: size * k100 / 100, countLabel: "serving") }
        return Conv(kcalPer100: k100, countKcal: nil, countLabel: nil)
    }

    static func plural(_ n: Double, _ word: String) -> String { n >= 1.95 ? word + "s" : word }

    /// "2 slices", "150 g", "½ portion" for a line in the day.
    static func amountText(_ b: JSON, kcal: Double) -> String {
        let a = amounts(b, kcal: kcal)
        let label = str(b["unitLabel"])
        if !label.isEmpty, let s = a.servings { return "\(Fmt.one(s)) \(plural(s, label))" }
        var parts: [String] = []
        if let g = a.grams { parts.append("\(Fmt.one(g)) \(a.unit)") }
        if let p = a.pieces { parts.append("\(Fmt.one(p)) pcs") } else if let s = a.servings { parts.append("\(Fmt.one(s)) serv") }
        return parts.joined(separator: " · ")
    }

    /// A row of the bundled food list: [name, kcal/100, serving, serving label, unit, search words, p, c, f].
    static func foodItem(_ row: [Any]) -> JSON {
        func at(_ i: Int) -> Any? { i < row.count ? row[i] : nil }
        var item: JSON = ["source": "search", "name": str(at(0)), "unit": str(at(4)).isEmpty ? "g" : str(at(4))]
        if let k = num(at(1)) { item["kcalPer100"] = k }
        if let p = num(at(6)) { item["p100"] = p; item["c100"] = num(at(7)) ?? 0; item["f100"] = num(at(8)) ?? 0 }
        if let serving = pos(at(2)), let k = num(at(1)) {
            item["servingSize"] = serving
            item["kcalPerServing"] = (k * serving / 10).rounded() / 10
        }
        let label = str(at(3)); if !label.isEmpty { item["unitLabel"] = label }
        return item
    }
}

/// Breakfast, lunch, dinner or snacks: the clock decides at meal times, the food in between (the web app's guessMeal).
enum Meals {
    static let all = ["Breakfast", "Lunch", "Dinner", "Snacks"]
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let words: [String: NSRegularExpression] = [
        "Breakfast": rx(#"\b(oats?|porridge|granola|muesli|cereal|cornflakes|weetabix|shreddies|bran flakes|toast|bagel|croissant|pain au|pancakes?|waffles?|crumpets?|eggs?|omelette|scrambled|bacon|full english|yogh?urt|smoothie|overnight oats)\b"#),
        "Lunch": rx(#"\b(sandwich|sarnie|wrap|panini|baguette|sub|salad|soup|toastie|meal deal|sushi|poke|burrito bowl)\b"#),
        "Dinner": rx(#"\b(curry|pasta|spaghetti|lasagne|bolognese|chilli|steak|roast|stir.?fry|risotto|pizza|burger|fajitas?|tacos?|casserole|stew|pie|salmon|noodles|kebab|shepherd'?s|cottage pie|fish and chips|dinner)\b"#),
        "Snacks": rx(#"\b(crisps|chocolate|biscuits?|cookies?|cake|brownie|sweets|nuts|popcorn|protein bar|flapjack|ice cream|donut|doughnut|muffin|beer|wine|cider|gin|vodka|whisky|rum|cocktail|jack daniel)\b"#)
    ]

    static func byTime(_ h: Int?) -> String {
        guard let h else { return "Snacks" }
        if h >= 4 && h < 11 { return "Breakfast" }
        if h >= 11 && h < 15 { return "Lunch" }
        if h >= 17 && h < 22 { return "Dinner" }
        return "Snacks"
    }

    static func guess(_ name: String, hour h: Int?) -> String {
        let t = byTime(h)
        guard let h else { return t }
        let range = NSRange(name.startIndex..., in: name)
        let hits = all.filter { words[$0]?.firstMatch(in: name, range: range) != nil }
        if hits.isEmpty { return t }
        if hits.contains("Breakfast") && h >= 11 && h < 12 { return "Breakfast" }
        if t != "Snacks" { return t }
        if hits.contains("Lunch") && h >= 15 && h < 17 { return "Lunch" }
        if hits.contains("Dinner") && (h >= 15 || h < 2) { return "Dinner" }
        return "Snacks"
    }

    static func of(_ item: JSON) -> String {
        let m = str(item["meal"])
        if all.contains(m) { return m }
        let hour = ISO.date(item["addedAt"] as? String).map { Calendar.current.component(.hour, from: $0) }
        return guess(str(item["name"]), hour: hour)
    }

    static var now: String { byTime(Calendar.current.component(.hour, from: Date())) }
}
