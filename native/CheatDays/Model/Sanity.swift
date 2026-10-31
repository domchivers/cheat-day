import Foundation

/// Checks on numbers before they're logged, so an AI slip or a mismatched database row doesn't land in the diary:
/// calories that don't fit the protein, carbs and fat ("2 kcal with 5 g carbs"), values outside what that kind of
/// food can be ("shredded chicken at 35 g protein per 100 g"), and a database match far off the AI's figure.
enum Sanity {
    /// What a kind of food runs to per 100 g: its usual calories and the most protein it can have.
    struct Range { let label: String; let lo: Double; let hi: Double; let proteinMax: Double }

    /// The range for a food by its name, most specific first; nil when there's nothing to go on.
    static func range(_ name: String) -> Range? {
        let n = name.lowercased()
        func has(_ w: [String]) -> Bool { w.contains { n.contains($0) } }
        let raw = has(["raw", "uncooked"])
        let cooked = has(["cooked", "grilled", "roast", "bbq", "shredded", "fried", "baked", "braised", "rotisserie", "pulled"])
        if has(["protein powder", "whey", "protein shake powder", "daily shake", "isolate"]) { return Range(label: "protein powder", lo: 340, hi: 420, proteinMax: 92) }
        if has(["water", "black coffee", "diet ", "zero sugar", "sweetener", "stevia", "monk fruit"]) { return nil }
        if has(["rice", "pasta", "spaghetti", "noodle", "penne", "couscous"]) && (cooked || !raw && !has(["dry", "uncooked"])) {
            return Range(label: "cooked rice or pasta", lo: 95, hi: 190, proteinMax: 7)
        }
        if has(["cabbage", "lettuce", "spinach", "cucumber", "celery", "kale", "broccoli", "zucchini", "courgette", "tomato",
                "capsicum", "bell pepper", "red pepper", "green pepper", "mushroom", "bok choy", "cauliflower", "salad leaves", "rocket", "asparagus", "green beans"])
            && !has(["chips", "crisps", "soup", "sauce", "dressing", "cheese", "pesto"]) {
            return Range(label: "leafy or non-starchy veg", lo: 10, hi: 60, proteinMax: 4.5)
        }
        if has(["chicken", "turkey"]) && !has(["nugget", "schnitzel", "kiev", "burger", "wrap", "sandwich", "curry", "soup", "pie", "skin"]) {
            if raw { return Range(label: "raw chicken", lo: 105, hi: 220, proteinMax: 24.5) }
            return Range(label: "cooked chicken", lo: 140, hi: 270, proteinMax: 32)
        }
        if has(["mince", "ground beef"]) {
            return raw || !cooked ? Range(label: "raw beef mince", lo: 120, hi: 270, proteinMax: 22.5)
                                  : Range(label: "cooked beef mince", lo: 170, hi: 320, proteinMax: 30)
        }
        if has(["chuck", "brisket", "blade", "beef shin", "gravy beef"]) {
            return raw || !cooked ? Range(label: "raw beef chuck", lo: 140, hi: 240, proteinMax: 22.5)
                                  : Range(label: "cooked beef chuck", lo: 190, hi: 320, proteinMax: 33)
        }
        func fishWord(_ p: String) -> Bool { n.range(of: p, options: .regularExpression) != nil }
        if fishWord(#"\b(\w*fish|salmon|tuna|cod|snapper|barramundi|trout|basa|yellowtail|mackerel|hiramasa)\b"#)
            && !has(["sauce", "oil", "cake", "finger", "battered", "crumbed", "stock", "pie", "curry", "burger"]) {
            return raw || !cooked ? Range(label: "raw fish", lo: 70, hi: 260, proteinMax: 27)
                                  : Range(label: "cooked fish", lo: 90, hi: 300, proteinMax: 33)
        }
        if has(["cocoa powder", "cacao powder"]) { return Range(label: "cocoa powder", lo: 200, hi: 450, proteinMax: 30) }
        // mayo before eggs: "whole-egg mayonnaise" is mayo
        if has(["mayo", "aioli"]) { return has(["light", "lite", "low fat", "reduced"]) ? Range(label: "light mayonnaise", lo: 200, hi: 420, proteinMax: 2)
                                                                                       : Range(label: "mayonnaise", lo: 560, hi: 740, proteinMax: 2) }
        func word(_ p: String) -> Bool { n.range(of: p, options: .regularExpression) != nil }
        if word(#"\beggs?\b"#) && !has(["noodle", "nog", "egg white", "pasta", "fried rice", "scotch"]) {
            return Range(label: "eggs", lo: 125, hi: 210, proteinMax: 14)
        }
        if word(#"\b(bread|toast|buns?|rolls?|bagels?|baguette|sourdough|pitta|pita|crumpets?)\b"#)
            && !has(["protein", "breadcrumb", "garlic bread", "pudding", "rolled", "spring roll", "sausage roll", "sushi", "cinnamon", "french toast"])
            && (!has(["sandwich"]) || has(["sandwich bread", "sandwich loaf"])) {   // a whole sandwich isn't just bread; sandwich bread is
            return Range(label: "bread", lo: 200, hi: 300, proteinMax: 13)
        }
        return nil
    }

    /// Protein no more than that kind of food can have (an AI reaching for a protein aim wrote 45 g into an egg
    /// sandwich); unchanged when there's no range or no weight to go on.
    static func protein(name: String, grams: Double?, p: Double) -> Double {
        guard let g = grams, g > 0, let r = range(name), p / g * 100 > r.proteinMax * 1.05 else { return p }
        return (r.proteinMax * g / 100 * 10).rounded() / 10
    }

    static func energy(p: Double, c: Double, f: Double) -> Double { 4 * p + 4 * c + 9 * f }

    struct Result { var kcal: Double; var flags: [String] }

    /// One food's numbers checked. Calories well under what its macros make are replaced by the macros' energy
    /// (protein and carbs 4 kcal a gram, fat 9); everything else that looks wrong is flagged, not changed.
    static func check(name: String, grams: Double?, kcal: Double, p: Double?, c: Double?, f: Double?) -> Result {
        var out = Result(kcal: kcal, flags: [])
        if p != nil || c != nil || f != nil {
            let pp = p ?? 0, cc = c ?? 0, ff = f ?? 0, e = energy(p: pp, c: cc, f: ff)
            let n = name.lowercased()
            // alcohol has energy the macros don't show; fibre-heavy foods have carbs that give little
            let alcohol = n.range(of: #"\b(wine|beer|spirits?|vodka|gin|rum|whisky|sake|mirin|cider|liqueur|cocktail)\b"#, options: .regularExpression) != nil
            let fibre = n.range(of: #"\b(cocoa|cacao|bran|chia|flax|linseed|psyllium|fibre)\b"#, options: .regularExpression) != nil
            if e > 8 && kcal < e * 0.8 - 5 && !fibre {
                out.kcal = e.rounded()
                out.flags.append("\(name): \(Fmt.int(kcal)) kcal didn't fit its \(Fmt.int(pp)) g protein, \(Fmt.int(cc)) g carbs and \(Fmt.int(ff)) g fat, so it's \(Fmt.int(e)) kcal from those.")
            } else if e > 0 && kcal > e * 1.2 + 15 && pp + cc + ff > 2 && !alcohol {
                out.flags.append("\(name): \(Fmt.int(kcal)) kcal is a lot more than its protein, carbs and fat make (\(Fmt.int(e))). Check it.")
            }
        }
        if let g = grams, g > 0 {
            let k100 = out.kcal / g * 100, p100 = (p ?? 0) / g * 100
            if (p ?? 0) + (c ?? 0) + (f ?? 0) > g * 1.05 { out.flags.append("\(name): more protein, carbs and fat than its \(Fmt.int(g)) g weighs. Check the numbers.") }
            if let r = range(name) {
                if k100 < r.lo * 0.85 || k100 > r.hi * 1.15 {
                    out.flags.append("\(name): \(Fmt.int(k100)) kcal per 100 g looks off for \(r.label) (usually \(Fmt.int(r.lo))–\(Fmt.int(r.hi))).")
                }
                if p100 > r.proteinMax * 1.05 {
                    out.flags.append("\(name): \(Fmt.int(p100)) g protein per 100 g is more than \(r.label) has (at most about \(Fmt.int(r.proteinMax)) g).")
                }
            }
        }
        return out
    }

    /// A database number in place of the AI's: kept when the two are in the same ballpark; when they're far apart (a
    /// per-gram value read as per 100 g, a wrong match), the one that fits the kind of food wins, and a near-zero
    /// database value never replaces a real food.
    static func prefersDatabase(_ db: Double?, aiKcal: Double, grams: Double, name: String) -> Bool {
        guard let db, db > 0 else { return false }
        let ai = grams > 0 ? aiKcal / grams * 100 : 0
        let r = range(name)
        func fits(_ v: Double) -> Bool { r.map { v >= $0.lo * 0.85 && v <= $0.hi * 1.15 } ?? true }
        if db < 5 && r != nil { return false }   // "2 kcal per 100 g" for cabbage: a unit mix-up, not a better number
        if ai > 0 && db >= ai * 0.55 && db <= ai * 1.8 { return fits(db) || !fits(ai) }
        if ai < 10 { return db >= 5 && fits(db) }   // the AI said next to nothing: a sensible database value wins
        return fits(db) && !fits(ai)
    }

    /// Everyday amounts in grams, for the AI to use ("half the juice of a lemon" is 20 g, not 1 g).
    static let amounts = "Everyday amounts in grams: juice of 1 lemon 40 g, juice of half a lemon 20 g, juice of 1 lime 30 g, a squeeze 5 g, a splash of sauce or liquid 5 to 10 g, a pinch 0.5 g, 1 tbsp of liquid 15 g, 1 tsp 5 g."
}

/// Roughly what kind of food something is, so a swap offers like for like (beef for beef, not mayonnaise).
enum FoodKind: String {
    case meat, poultry, fish, dairy, grain, veg, fruit, sauce, sweet, other

    static func of(_ name: String) -> FoodKind {
        let n = name.lowercased()
        func has(_ w: [String]) -> Bool { w.contains { n.contains($0) } }
        if has(["sauce", "mayo", "ketchup", "dressing", "paste", "roux", "curry mix", "stock", "gravy", "oil", "butter", "vinegar", "soy"]) { return .sauce }
        if has(["chicken", "turkey", "duck"]) { return .poultry }
        if has(["beef", "steak", "chuck", "mince", "lamb", "pork", "bacon", "ham", "sausage", "brisket", "venison", "chorizo", "salami", "pepperoni"]) { return .meat }
        if has(["salmon", "tuna", "cod", "fish", "prawn", "shrimp", "haddock", "barramundi", "basa", "snapper", "trout", "flathead", "yellowtail", "squid", "calamari"]) { return .fish }
        if has(["milk", "yoghurt", "yogurt", "cheese", "cream", "skyr", "quark", "feta", "mozzarella"]) { return .dairy }
        if has(["rice", "pasta", "noodle", "bread", "oats", "wrap", "tortilla", "couscous", "quinoa", "potato", "flour", "spaghetti", "penne"]) { return .grain }
        if has(["chocolate", "biscuit", "cookie", "cake", "ice cream", "lolly", "candy", "sugar", "honey", "syrup"]) { return .sweet }
        if has(["apple", "banana", "berry", "berries", "orange", "mango", "grape", "pear", "melon", "kiwi", "pineapple"]) { return .fruit }
        if has(["carrot", "onion", "pepper", "capsicum", "broccoli", "spinach", "cabbage", "lettuce", "tomato", "corn", "pea", "bean",
                "mushroom", "zucchini", "courgette", "celery", "cucumber", "kale", "cauliflower", "pumpkin", "squash"]) { return .veg }
        return .other
    }

    /// Whether b is a sensible swap for a (anything goes when either is unknown; meat and poultry swap with each other).
    static func swaps(_ a: String, _ b: String) -> Bool {
        let x = of(a), y = of(b)
        if x == .other || y == .other || x == y { return true }
        let protein: Set<FoodKind> = [.meat, .poultry, .fish]
        return protein.contains(x) && protein.contains(y)
    }
}
