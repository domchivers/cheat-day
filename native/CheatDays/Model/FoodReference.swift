import Foundation

/// Checked numbers per 100 g, raw, for the foods the AI and the US database get wrong: species and cuts, by the names
/// used here (kingfish is yellowtail, not the king mackerel USDA calls kingfish). Used before any database, and on
/// recipes, which otherwise never see one. Your own labels and scans never come through here.
enum FoodReference {
    struct Entry { let name: String; let all: [String]; let any: [String]; let not: [String]; let ok: [String]; let kcal, p, c, f: Double }

    static let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "reference", withExtension: "json"), let d = try? Data(contentsOf: url),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] else { return [] }
        return rows.compactMap { r in
            guard let v = r["v"] as? [Double], v.count == 4 else { return nil }
            func words(_ k: String) -> [String] { r[k] as? [String] ?? [] }
            return Entry(name: str(r["n"]), all: words("all"), any: words("any"), not: words("not"), ok: words("ok"), kcal: v[0], p: v[1], c: v[2], f: v[3])
        }
    }()

    /// Words that make it a different food from the raw one in the table: cooked, processed, or only flavoured with it.
    private static let otherFood = ["cooked", "grilled", "roast", "fried", "baked", "braised", "steamed", "poached", "smoked", "pulled", "shredded", "bbq", "rotisserie",
                                    "canned", "tinned", "crumbed", "battered", "dried", "stock", "broth", "sauce", "gravy ", "paste", "powder", "marinade", "seasoning", "flavour",
                                    "burger", "nugget", "schnitzel", "sausage", " pie", "soup", "salad", "dressing", " oil", "cake", "curry", "dumpling", "wrap", "sandwich"]

    /// The most specific entry for a name, or nil when it isn't a plain raw food in the table.
    static func match(_ name: String) -> Entry? {
        let n = name.lowercased()
        func has(_ w: String) -> Bool { n.contains(w) }
        var best: (Entry, Int)?
        for e in entries {
            guard e.all.allSatisfy(has), !e.not.contains(where: has), e.any.isEmpty || e.any.contains(where: has) else { continue }
            guard !otherFood.contains(where: { has($0) && !e.ok.contains($0) }) else { continue }
            let score = e.all.count + (e.any.isEmpty ? 0 : 1)
            if score > (best?.1 ?? 0) { best = (e, score) }
        }
        return best?.0
    }

    /// How far from the table's calories it can be before the table's numbers replace it.
    static let tolerance = 0.15

    /// An ingredient (kcal, protein_g, carbs_g, fat_g, grams) with the table's numbers if it was out, and whether it changed.
    static func corrected(_ g: JSON) -> (item: JSON, changed: Bool) {
        guard let grams = pos(g["grams"]), let e = match(str(g["name"])) else { return (g, false) }
        let k100 = (num(g["kcal"]) ?? 0) / grams * 100
        guard abs(k100 - e.kcal) / e.kcal > tolerance else { return (g, false) }
        var x = g
        x["kcal"] = (e.kcal * grams / 100).rounded(); x["protein_g"] = e.p * grams / 100; x["carbs_g"] = e.c * grams / 100; x["fat_g"] = e.f * grams / 100
        return (x, true)
    }

    /// Oil to fry in mostly stays in the pan: only what's absorbed counts (about an eighth).
    static func absorbed(_ g: JSON) -> (item: JSON, changed: Bool) {
        let n = (str(g["name"]) + " " + str(g["amount"])).lowercased()
        guard n.contains("oil"), n.range(of: #"fry|frying"#, options: .regularExpression) != nil, n.range(of: #"stir|pan.?fry"#, options: .regularExpression) == nil,
              let grams = pos(g["grams"]), grams > 60 else { return (g, false) }
        let kept = (grams / 8).rounded()
        var x = g
        for k in ["kcal", "protein_g", "carbs_g", "fat_g"] { if let v = num(g[k]) { x[k] = v * kept / grams } }
        x["grams"] = kept
        x["amount"] = "\(Fmt.int(grams)) g, about \(Fmt.int(kept)) g absorbed"
        return (x, true)
    }

    /// Whether a database row is really the food asked for: raw isn't canned, oats aren't puffed, peanut butter isn't reduced fat.
    static func sameFood(asked: String, got: String) -> Bool {
        let a = asked.lowercased(), g = got.lowercased()
        return !["canned", "cooked", "puffed", "reduced fat", "low fat", "fat free", "dried", "frozen", "breaded", "fried"].contains { g.contains($0) && !a.contains($0) }
    }

    /// A whole recipe version's ingredients checked: the numbers put right, what's still odd flagged, and a note of how many changed.
    static func checked(_ ingredients: [JSON]) -> (items: [JSON], flags: [String]) {
        var flags: [String] = [], changed = 0
        let items = ingredients.map { g0 -> JSON in
            let fry = absorbed(g0), table = corrected(fry.item)
            var x = table.item
            if fry.changed || table.changed { changed += 1 }
            let p = num(x["protein_g"]).map { Sanity.protein(name: str(x["name"]), grams: num(x["grams"]), p: $0) }
            if let p { x["protein_g"] = p }
            let r = Sanity.check(name: str(x["name"]), grams: num(x["grams"]), kcal: num(x["kcal"]) ?? 0, p: p, c: num(x["carbs_g"]), f: num(x["fat_g"]))
            x["kcal"] = r.kcal
            flags += r.flags
            return x
        }
        if changed > 0 { flags.insert("\(changed) ingredient\(changed == 1 ? "'s numbers" : "s' numbers") corrected from checked reference values.", at: 0) }
        return (items, flags)
    }
}
