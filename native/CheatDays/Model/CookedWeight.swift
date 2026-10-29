import Foundation

/// What a dish weighs once cooked. Cooking moves water, not calories: meat and veg lose it, rice, pasta and lentils
/// soak it up, stock and wine boil down. So the finished pot's weight is what portions are weighed against.
enum CookedWeight {
    /// How much of each ingredient's raw weight is left once cooked, by its name. Already-cooked things stay as they are.
    static func factor(_ name: String) -> Double {
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["cooked", "tinned", "canned", "roast potatoes", "leftover"]) { return 1 }
        if has(["oil", "butter", "sauce", "paste", "roux", "curry block", "sugar", "honey", "salt", "spice", "powder", "seasoning"]) { return 1 }
        if has(["stock", "broth", "water", "wine", "beer", "cider"]) { return 0.5 }
        if has(["rice", "quinoa", "couscous", "bulgur", "lentil", "split pea"]) { return 2.6 }
        if has(["pasta", "spaghetti", "penne", "fusilli", "macaroni", "noodle", "orzo"]) { return 2.2 }
        if has(["oats", "porridge"]) { return 3 }
        if has(["dried bean", "chickpea"]) && !has(["tin", "can"]) { return 2.2 }
        if has(["bacon", "pancetta", "chorizo"]) { return 0.45 }
        if has(["mince", "ground beef", "burger"]) { return 0.7 }
        if has(["chuck", "brisket", "shin", "shoulder", "cheek", "short rib", "oxtail", "stewing", "braising", "pulled", "roast", "joint", "lamb", "pork belly"]) { return 0.62 }
        if has(["beef", "steak", "pork", "venison"]) { return 0.7 }
        if has(["chicken", "turkey", "duck", "thigh", "breast"]) { return 0.75 }
        if has(["salmon", "cod", "fish", "prawn", "shrimp", "tuna steak", "haddock"]) { return 0.8 }
        if has(["spinach", "kale", "greens", "cabbage"]) { return 0.35 }
        if has(["mushroom"]) { return 0.55 }
        if has(["onion", "pepper", "courgette", "aubergine", "tomato", "celery", "leek"]) { return 0.8 }
        if has(["potato", "carrot", "parsnip", "squash", "pumpkin", "sweet potato", "broccoli", "cauliflower", "bean", "pea"]) { return 0.9 }
        return 0.9
    }

    /// A weighed pot this far from what the ingredients make usually means something listed isn't in it (rice served
    /// on the side), and then every gram would count wrong.
    static func looksOff(weighed: Double, estimate: Double) -> Bool { weighed < estimate * 0.6 || weighed > estimate * 1.6 }

    /// The finished dish's weight from its ingredients (name and raw grams); nil when no grams are known.
    static func estimate(_ ingredients: [(name: String, grams: Double)]) -> Double? {
        let known = ingredients.filter { $0.grams > 0 }
        guard !known.isEmpty else { return nil }
        return (known.reduce(0) { $0 + $1.grams * factor($1.name) } / 10).rounded() * 10
    }
}
