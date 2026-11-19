import Foundation

/// Chains' own published numbers, kept on the phone (19 Nov; design/reports/Chain restaurant menu logging.md). A meal
/// from a chain is a lookup, not an estimate: the AI names the shop and each thing as the shop sells it (`shop`,
/// `shop_items`), and if the shop is a chain in this table for the country you're in, every item is matched to the
/// chain's own row and its numbers are the ones counted. Anything not matched surely goes on to the web lookup
/// (Assistant.fromShop), as before. The numbers come only from the rows here, never from the AI.
///
/// The rows are files in the app named chain-<country>-<chain>.json, made from each chain's own nutrition PDF or pages
/// (design/chains/, with where and when each came from). Matching only ever looks inside the one chain, so a Big Mac
/// can't come out as something from another menu (the hotpot rolls matched to Swedish meat rolls were that mistake).
enum ChainMenu {
    struct Item {
        let name: String
        let words: Set<String>
        let serveG: Double?
        let kcal: Double
        let protein: Double?, carbs: Double?, fat: Double?
    }
    struct Chain {
        let name: String, country: String, source: String, date: String
        let items: [Item]
    }

    /// Every chain on the phone.
    static let all: [Chain] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("chain-") }.compactMap { url -> Chain? in
            guard let d = try? Data(contentsOf: url), let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { return nil }
            let items = list(j["items"]).compactMap { r -> Item? in
                // kcal as published, else from the kJ (most Australian menus give only kJ)
                guard let kcal = pos(r["kcal"]) ?? pos(r["kj"]).map({ $0 / 4.184 }), !str(r["name"]).isEmpty else { return nil }
                return Item(name: str(r["name"]), words: words(str(r["name"])), serveG: pos(r["serve_g"]), kcal: kcal,
                            protein: num(r["protein_g"]), carbs: num(r["carbs_g"]), fat: num(r["fat_g"]))
            }
            guard !items.isEmpty else { return nil }
            return Chain(name: str(j["chain"]), country: str(j["country"]).uppercased(), source: str(j["source"]), date: str(j["source_date"]), items: items)
        }
    }()

    /// What people call each chain, besides its own name.
    private static let nicknames: [String: [String]] = [
        "McDonald's": ["maccas", "macca's", "mcdonalds", "mcdonald's", "mcd", "mickey d's"],
        "Hungry Jack's": ["hungry jacks", "hj's", "hjs"],
        "Guzman y Gomez": ["gyg", "guzman"],
        "Kentucky Fried Chicken": ["kfc"], "KFC": ["kentucky fried chicken"],
        "Domino's": ["dominos"], "Nando's": ["nandos"], "Grill'd": ["grilld"],
        "Burger King": ["bk"], "Pret A Manger": ["pret"], "Gloria Jean's": ["gloria jeans"],
        "Boost Juice": ["boost"], "Red Rooster": ["rooster"],
    ]

    /// The chain a shop's name is, for this country (`code` as Region.code: AU, GB, US).
    static func chain(_ shop: String, code: String) -> Chain? {
        let s = plain(shop)
        guard !s.isEmpty else { return nil }
        let here = all.filter { $0.country == code || ($0.country == "UK" && code == "GB") }
        return here.first { c in
            let names = [c.name] + (nicknames[c.name] ?? [])
            return names.contains { plain($0) == s || s.hasPrefix(plain($0) + " ") }
        }
    }

    /// One thing as the shop sells it, matched to the chain's row: the best match, and only when it's clearly the
    /// best (well ahead of the next) and close enough to be the same thing.
    static func item(_ asked: String, in c: Chain) -> Item? {
        var q = words(asked)
        for n in [c.name] + (nicknames[c.name] ?? []) { q.subtract(words(n)) }   // "McDonald's Big Mac" is the Big Mac
        guard !q.isEmpty else { return nil }
        let qSize = q.intersection(sizes)
        var scored: [(Item, Double)] = c.items.map { it in
            let shared = Double(q.intersection(it.words).count)
            var s = 2 * shared / Double(q.count + it.words.count)
            if !q.isSubset(of: it.words) { s = 0 }   // every word they said is in its name: "vegan sausage roll" isn't the Sausage Roll
            let iSize = it.words.intersection(sizes)
            // a size asked for must be the size matched; with none asked, the usual size of it
            if !qSize.isEmpty, !iSize.isEmpty, qSize != iSize { s -= 0.5 }
            if qSize.isEmpty, !iSize.isEmpty, iSize.isDisjoint(with: ["medium", "regular"]) { s -= 0.15 }
            return (it, s)
        }
        scored.sort { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 0.6 else { return nil }
        if scored.count > 1, best.1 - scored[1].1 < 0.12, best.0.words != q { return nil }
        return best.0
    }

    /// The whole order from the chain's own numbers, when the shop's a chain here and every item is surely one of its
    /// rows; nil otherwise (then the web lookup tries, as before). A total far from what the AI made of it (under half
    /// or over double) is taken as a wrong match, and nothing changes.
    static func order(_ e: JSON, code: String) -> JSON? {
        guard let c = chain(str(e["shop"]), code: code) else { return nil }
        let asked = Assistant.shopItems(str(e["shop_items"]))
        guard !asked.isEmpty else { return nil }
        var parts: [JSON] = []
        for a in asked {
            guard let it = item(a.name, in: c) else { return nil }
            let label: JSON = ["found": true, "serving_g": it.serveG ?? 0, "kcal": it.kcal, "protein_g": it.protein ?? 0,
                               "carbs_g": it.carbs ?? 0, "fat_g": it.fat ?? 0, "source": c.source]
            var x: JSON = a.grams.map { ["name": it.name, "grams": $0] as JSON } ?? ["name": it.name, "servings": a.count]
            if it.serveG == nil {
                // no serve weight published: counted by how many, its grams left as the AI saw them
                x["kcal"] = (it.kcal * a.count).rounded()
                for (k, v) in [("protein_g", it.protein), ("carbs_g", it.carbs), ("fat_g", it.fat)] { x[k] = (v ?? 0) * a.count }
                x["grams"] = 0; x["src"] = "web"; x["source"] = c.source
            } else {
                x = Assistant.fromLabel(x, label)
            }
            x["match"] = "\(c.name) \(it.name)"
            x["numbers_from"] = "brand"
            parts.append(x)
        }
        let total = parts.reduce(0.0) { $0 + (num($1["kcal"]) ?? 0) }, ai = num(e["kcal_total"]) ?? 0
        if ai > 0, total < ai * 0.5 || total > ai * 2 { return nil }
        var out = Assistant.totals(e, parts: parts)
        out["shopNote"] = "\(Assistant.possessive(c.name)) own published numbers" + (c.date.isEmpty ? "" : " (\(c.date))")
        out["chain"] = c.name
        return out
    }

    // MARK: names into words

    private static let sizes: Set<String> = ["small", "medium", "large", "regular", "kids", "junior", "mini", "short"]
    private static let stop: Set<String> = ["the", "a", "an", "and", "with", "of", "&", "in", "on", "meal", "x1"]
    private static let same: [String: String] = [
        "lrg": "large", "lg": "large", "med": "medium", "md": "medium", "reg": "regular", "sml": "small", "sm": "small",
        "chips": "fries", "coca": "coke", "cola": "coke", "zero": "nosugar", "nuggets": "mcnuggets", "burgers": "burger",
        "wraps": "wrap", "drinks": "drink", "pcs": "pieces", "pc": "pieces", "piece": "pieces",
        "tall": "small", "grande": "medium", "venti": "large",   // Starbucks' sizes
    ]

    static func plain(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: #"['’®™]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func words(_ s: String) -> Set<String> {
        let p = plain(s).replacingOccurrences(of: "no sugar", with: "nosugar")
        return Set(p.split(separator: " ").map { same[String($0)] ?? String($0) }.filter { !stop.contains($0) })
    }
}
