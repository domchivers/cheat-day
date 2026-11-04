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

    private static let filler: Set<String> = ["fresh", "chopped", "sliced", "diced", "large", "small", "medium", "finely", "peeled", "boneless", "skinless", "lean", "of", "and", "for", "to", "taste", "grated", "minced", "crushed", "dried", "ground", "whole", "extra", "virgin", "cubed", "thinly", "roughly", "optional"]

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
        if let named = aliases[want.joined(separator: " ")] { return named }
        let cooked = name.range(of: "cooked|boiled|grilled|roast|fried|baked|steamed", options: [.regularExpression, .caseInsensitive]) != nil
        var best: (rank: Int, food: Food)?
        for r in rows where want.allSatisfy({ r.words.contains($0) }) {
            guard r.kind.contains(head) || r.kind.contains(want[0]) || want.allSatisfy({ r.lead.contains($0) }) else { continue }
            let rank = (r.raw == !cooked ? 0 : 100) + (r.food.main ? 0 : 20) + r.words.count * 2
            if rank < (best?.rank ?? .max) { best = (rank, r.food) }
        }
        return best?.food
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
