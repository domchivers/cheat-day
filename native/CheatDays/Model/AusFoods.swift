import Foundation

/// A country's official food table, per 100 g, for finding a food by its everyday name: Australia's FSANZ AFCD Release 3
/// (then AUSNUT 2023), the UK's CoFID 2021 (McCance and Widdowson's) and the US's USDA SR Legacy. Same matching as
/// tools/ai-test/tables.js (and jobs.js for Australia, which AusFoodsTests checks it against). Rebuilt with tools/native-data.sh.
final class FoodTable {
    struct Food { let name: String; let main: Bool; let kcal, p, c, f: Double }
    private struct Row { let food: Food; let words: Set<String>; let raw: Bool; let kind: [String]; let lead: [String] }

    static let au = FoodTable(foods: "aus-foods", aliases: "aus-aliases", main: "AFCD3", src: "afcd")
    static let uk = FoodTable(foods: "uk-foods", aliases: "uk-aliases", main: "CoFID2021", src: "cofid")
    static let us = FoodTable(foods: "us-foods", aliases: "us-aliases", main: "SRLegacy", src: "usda")
    /// Dishes as eaten (USDA FNDDS 2021-2023, public domain: "Pad Thai with chicken", "Cheesecake, chocolate"), for any
    /// country when its own table has no such dish, before the part is left as the AI's guess.
    static let dishes = FoodTable(foods: "dishes-foods", aliases: "dishes-aliases", main: "FNDDS2021", src: "fndds")

    /// The table for where they live (the Settings country).
    static var current: FoodTable { testing ?? table(for: Region.current) }
    /// Tests pin a country here so they don't depend on the simulator's time zone (Australia unless a test says otherwise).
    static var testing: FoodTable? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? nil : .au
    static func table(for region: Region) -> FoodTable {
        switch region { case .au: return au; case .uk: return uk; case .us: return us }
    }

    /// What a checked part's `src` says for this table.
    let src: String
    private let rows: [Row]
    private let aliases: [String: Food]

    private init(foods: String, aliases file: String, main: String, src: String) {
        self.src = src
        rows = ((Self.load(foods) as? [JSON]) ?? []).map { r in
            let name = str(r["name"]), parts = name.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let food = Food(name: name.trimmingCharacters(in: .whitespaces), main: str(r["source"]) == main, kcal: num(r["kcal"]) ?? 0, p: num(r["p"]) ?? 0, c: num(r["c"]) ?? 0, f: num(r["f"]) ?? 0)
            let raw = name.range(of: #"\braw\b|uncooked"#, options: [.regularExpression, .caseInsensitive]) != nil
            return Row(food: food, words: Set(Self.words(name)), raw: raw, kind: Self.words(parts[0]), lead: Self.words(parts.prefix(2).joined(separator: " ")))
        }
        var named: [String: Food] = [:]
        for pair in (Self.load(file) as? [[String]]) ?? [] where pair.count == 2 {
            guard let row = rows.first(where: { $0.food.name == pair[1].trimmingCharacters(in: .whitespaces) }) else { continue }
            for n in pair[0].split(separator: "|") { named[Self.words(String(n)).joined(separator: " ")] = row.food }
        }
        self.aliases = named
    }

    private static let filler: Set<String> = ["fresh", "chopped", "sliced", "diced", "large", "small", "medium", "finely", "peeled", "boneless", "skinless", "lean", "of", "and", "for", "to", "taste", "grated", "minced", "crushed", "dried", "ground", "whole", "extra", "virgin", "cubed", "thinly", "roughly", "optional", "brushed", "washed"]

    static func words(_ s: String) -> [String] {
        let plain = String(s.lowercased().map { $0.isASCII && $0.isLetter ? $0 : " " })
        return plain.split(separator: " ").map(String.init).filter { !filler.contains($0) }.map { w in
            if w.hasSuffix("oes") { return String(w.dropLast(3)) + "o" }
            if w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
            return w.hasSuffix("s") ? String(w.dropLast()) : w
        }
    }

    private static func load(_ name: String) -> Any? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// The food an ingredient's name means: its everyday name first, otherwise the food's own kind must match
    /// ("vegetable oil" never finds puff pastry made with it). Raw unless the name says cooked, the table's own measured data first.
    func find(_ name: String) -> Food? {
        let first = name.split(whereSeparator: { $0 == "," || $0 == "(" }).first.map(String.init) ?? ""
        let want = Self.words(first)
        guard let head = want.last else { return nil }
        let cooked = name.range(of: "cooked|boil|grill|roast|fried|fry|bake|steam|brais|stew|simmer|poach|casserol", options: [.regularExpression, .caseInsensitive]) != nil
        // "potato, boiled" isn't the raw potato its everyday name means, and dried noodles aren't boiled ones
        let dry = name.range(of: #"\b(dry|dried|uncooked)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        if let named = aliases[want.joined(separator: " ")], !(cooked && named.name.range(of: #"\braw\b|uncooked"#, options: [.regularExpression, .caseInsensitive]) != nil),
           !(dry && named.name.range(of: #"\b(boiled|cooked|drained)\b"#, options: [.regularExpression, .caseInsensitive]) != nil) { return named }
        let hits = Self.narrow(name, rows.filter { r in
            want.allSatisfy { r.words.contains($0) } && (r.kind.contains(head) || r.kind.contains(want[0]) || want.allSatisfy { r.lead.contains($0) })
        }, want: want)
        var best: (rank: Int, food: Food)?
        for r in hits {
            let rank = (r.raw == !cooked ? 0 : 100) + (r.food.main ? 0 : 20) + r.words.count * 2
            if rank < (best?.rank ?? .max) { best = (rank, r.food) }
        }
        return best?.food
    }

    /// The tags the AI puts on a part, and the words in a table name that agree or disagree with each.
    static let tagWords: [String: (yes: [String], no: [String])] = {
        let cookedWords = ["cooked", "baked", "grilled", "fried", "roasted", "roast", "boiled", "steamed", "casseroled", "bbq", "microwaved"]
        return [
            // bought only rules out homemade: most bought food isn't called "commercial" in the tables
            "homemade": (["homemade"], ["commercial", "purchased"]), "bought": ([], ["homemade"]),
            "natural": (["natural"], ["processed"]), "processed": (["processed"], ["natural"]),
            "raw": (["raw", "uncooked"], cookedWords), "cooked": (cookedWords, ["raw", "uncooked"]),
            "skin on": (["skin"], []), "skin off": ([], ["skin"]),
            "fried": (["fried"], []), "baked": (["baked", "roasted", "roast"], []), "grilled": (["grilled", "bbq"], []),
            "boiled": (["boiled"], []), "steamed": (["steamed"], []),
            "plain": (["plain", "unfilled"], ["filled", "filling"]), "filled": (["filled", "filling"], ["unfilled"]),
            "coated": (["coated", "crumbed", "breadcrumb", "battered"], []), "reduced fat": (["reduced", "light", "lite"], []),
        ]
    }()
    /// Words that make a row a special version of its food: chosen only when the name or a tag asks for it.
    private static let special: Set<String> = ["processed", "reduced", "light", "lite", "flavoured", "coated", "crumbed", "breadcrumb", "battered",
                                               "canned", "smoked", "marinated", "frozen", "vitamin", "free", "skin", "homemade"]

    /// The food for a part the AI tagged (bought, natural, cooked, skin on, filled…): the everyday entry find gives, unless a
    /// relative of it fits the name and tags clearly better (a "skin on" chicken is a with-skin entry, a bakery's cheese the
    /// natural one, a "matcha cream cake" a cream-filled sponge). Untagged, it's find, unchanged.
    func best(_ name: String, tags: [String]) -> Food? {
        // an everyday name for the whole thing ("Beef, rare" is pho's lean slices, not the plain beef find gives: mince),
        // and a "rare" one even when the name says it's cooked in the broth
        let first = name.split(whereSeparator: { $0 == "," || $0 == "(" }).first.map(String.init) ?? ""
        let rare = name.range(of: #"\brare\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        // only when there's more than the first part: a plain "Cheese" goes through find and its tags as before (processed is processed)
        let whole = Self.words(name).joined(separator: " "), lead = Self.words(first).joined(separator: " ")
        if let named = (whole != lead ? aliases[whole] : nil) ?? (rare && whole != lead ? aliases[lead] : nil) { return named }
        let base = find(name)
        // how it's cooked says nothing about which cheese or cake it is (a "cooked" melted cheese found fried mozzarella)
        let cooking: Set<String> = ["raw", "cooked", "fried", "baked", "grilled", "boiled", "steamed"]
        let plain = [FoodKind.dairy, .sweet].contains(FoodKind.of(name))
        let tags = tags.filter { Self.tagWords[$0] != nil && !(plain && cooking.contains($0)) }
        guard !tags.isEmpty else { return base }
        let want = Self.words(first), all = Set(Self.words(name)), main = Set(want)
        guard !want.isEmpty else { return base }
        let asked = all.union(tags.flatMap { Self.tagWords[$0]!.yes })
        let baseRow = base.flatMap { b in rows.first { $0.food.name == b.name } }
        // relatives: the base's own kind (cheddar's other cheeses), or with no base, a kind the name names
        let kinds = Set(baseRow?.kind ?? want)
        /// How many tags a row agrees with, less the ones it goes against.
        func fit(_ r: Row) -> Int {
            tags.reduce(0) { n, t in let w = Self.tagWords[t]!; return n + (w.yes.contains(where: r.words.contains) ? 1 : 0) - (w.no.contains(where: r.words.contains) ? 1 : 0) }
        }
        func unasked(_ r: Row) -> Bool { r.words.contains { Self.special.contains($0) && !asked.contains($0) } }
        func score(_ r: Row) -> Double {
            // the food's own words count most; a descriptor ("skin" in "skin on") a little, and a row that's about it
            // ("Chicken, skin") isn't the food
            var s = 3 * Double(r.words.intersection(main).count) + Double(r.words.intersection(all.subtracting(main)).count)
            if r.lead.contains(where: { all.contains($0) && !main.contains($0) }) { s -= 5 }
            for t in tags { let w = Self.tagWords[t]!; if w.yes.contains(where: r.words.contains) { s += 4 }; if w.no.contains(where: r.words.contains) { s -= 6 } }
            s -= 3 * Double(r.words.filter { Self.special.contains($0) && !asked.contains($0) }.count)
            s -= 0.5 * Double(r.words.subtracting(all).subtracting(asked).count)
            return s + (r.food.main ? 1 : 0) + (r.food.name == base?.name ? 2 : 0)
        }
        let pool = rows.filter { !Set($0.kind).isDisjoint(with: kinds) && (baseRow != nil || $0.words.intersection(all).count >= min(2, want.count)) }
        guard let baseRow else { return pool.max(by: { score($0) < score($1) })?.food }
        // a relative only when it's still the food they named (the pho's rice noodles went to egg noodles for matching
        // "plain" too: 166 kcal and 7.5 g protein a 100 g, not 119 and 2.5), fits more of the tags and isn't a special
        // version nobody asked for. How it's cooked isn't the food: "cooked chicken" can be a baked one
        let described = Set(Self.tagWords.values.flatMap { $0.yes + $0.no })
        let named = main.intersection(baseRow.words).subtracting(described)
        let fitted = pool.filter { !unasked($0) && named.isSubset(of: $0.words) }.max { (fit($0), score($0)) < (fit($1), score($1)) }
        guard let fitted, fit(fitted) > fit(baseRow) else { return base }
        return fitted.food
    }

    /// For the card's Change: the entry a part was matched to first, then the closest others of the same kind by name
    /// and tags (a cream sponge, a cream-filled cake, homemade tiramisu…).
    func alternatives(_ name: String, tags: [String], matched: String, limit: Int = 4) -> [Food] {
        let first = name.split(whereSeparator: { $0 == "," || $0 == "(" }).first.map(String.init) ?? ""
        let want = Self.words(first), all = Set(Self.words(name)), main = Set(want)
        let asked = all.union(tags.compactMap { Self.tagWords[$0]?.yes }.flatMap { $0 })
        let chosen = rows.first { $0.food.name == matched }
        let kinds = Set((chosen?.kind ?? []) + want)   // a "tiramisu cream cake" offers tiramisu as well as cakes
        func score(_ r: Row) -> Double {
            var s = 3 * Double(r.words.intersection(main).count) + Double(r.words.intersection(all).count)
            s -= 2 * Double(r.words.filter { Self.special.contains($0) && !asked.contains($0) }.count)
            return s - 0.3 * Double(r.words.subtracting(all).subtracting(asked).count) + (r.food.main ? 0.5 : 0)
        }
        let others = rows.filter { !Set($0.kind).isDisjoint(with: kinds) && $0.food.name != matched && !$0.words.isDisjoint(with: all) }
            .sorted { score($0) > score($1) }.map(\.food)
        var seen = Set<String>()
        return Array(((chosen.map { [$0.food] } ?? []) + others).filter { seen.insert($0.name).inserted }.prefix(limit))
    }

    /// How it's cooked counts ("pan fried, no oil" is the no-added-fat fried potato, not boiled), and a variety only when
    /// they named it (the table lists potatoes as coliban, desiree, sebago…; a plain potato is the plain one). Each step
    /// only when something's left. Same as narrow in tools/ai-test/jobs.js.
    private static func narrow(_ name: String, _ hits: [Row], want: [String]) -> [Row] {
        var n = name.lowercased()
        for (said, row) in [("fry", "fried"), ("boil", "boiled"), ("bake", "baked"), ("grill", "grilled"), ("steam", "steamed")] {
            n = n.replacingOccurrences(of: "\\b\(said)(ing)?\\b", with: row, options: .regularExpression)   // "will pan fry" is fried
        }
        var h = hits
        func keep(_ test: (String) -> Bool) { let k = h.filter { test($0.food.name.lowercased()) }; if !k.isEmpty { h = k } }
        func has(_ s: String, _ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
        keep { words(String($0.split(separator: ",").first ?? "")) == want }   // a potato is a potato, not a sweet potato
        for m in ["boiled", "fried", "baked", "roast", "grilled", "steamed", "microwaved"] where n.contains(m) { keep { $0.contains(m) } }
        if has(n, #"\b(no|without)\s+(added\s+)?(oil|fat|butter)\b"#) { keep { $0.contains("no added fat") } }
        else if has(n, #"\b(with|in)\s+(\w+\s+)?(oil|fat|butter)\b"#) { keep { $0.contains("added fat") && !$0.contains("no added fat") } }
        keep { f in
            guard let r = f.range(of: #"\b(coliban|desiree|sebago|pontiac|kipfler|nicola|new|pale skin|red skin)\b"#, options: .regularExpression) else { return true }
            return n.contains(f[r])
        }
        return h
    }

    /// Words that split a message into the foods it names ("2 eggs on toast with butter": eggs | toast | butter).
    private static let breaks: Set<String> = Set("a an the and or with on in of for to my me i m s t had have has having ate eat eating some much many how what can is was it its this that these those last left calories calorie cals kcal grams gram g ml kg tsp tbsp cup cups slice slices piece pieces bowl plate good when cutting bulking remove add instead about just only plus also then dinner lunch breakfast snack today yesterday".split(separator: " ").map(String.init))

    /// The foods a typed message names, each with its data (longest names first, so "sesame oil" beats "oil").
    func named(in text: String) -> [(said: String, food: Food)] {
        var chunks: [[String]] = [[]]
        for w in text.lowercased().split(whereSeparator: { !($0.isASCII && $0.isLetter) }).map(String.init) {
            if Self.breaks.contains(w) { chunks.append([]) } else { chunks[chunks.count - 1].append(w) }
        }
        var out: [(said: String, food: Food)] = []
        for c in chunks where !c.isEmpty {
            var taken = Set<Int>()
            for n in stride(from: min(3, c.count), through: 1, by: -1) {
                for i in 0...(c.count - n) where !(i..<i + n).contains(where: taken.contains) {
                    let said = c[i..<i + n].joined(separator: " ")
                    guard let f = find(said) else { continue }
                    taken.formUnion(i..<i + n)
                    if !out.contains(where: { $0.food.name == f.name }) { out.append((said, f)) }
                }
            }
        }
        return out
    }
}

/// The Australian table by its old name (the tests and the golden file are Australian).
enum AusFoods {
    typealias Food = FoodTable.Food
    static func words(_ s: String) -> [String] { FoodTable.words(s) }
    static func find(_ name: String) -> Food? { FoodTable.au.find(name) }
    static func named(in text: String) -> [(said: String, food: Food)] { FoodTable.au.named(in: text) }
}
