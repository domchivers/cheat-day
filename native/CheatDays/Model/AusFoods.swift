import Foundation

/// Official Australian numbers per 100 g (FSANZ's AFCD Release 3, then AUSNUT 2023), for finding an ingredient by its
/// everyday name. Same matching as tools/ai-test/jobs.js, which AusFoodsTests checks it against. Rebuilt with tools/native-data.sh.
enum AusFoods {
    struct Food { let name: String; let australian: Bool; let kcal, p, c, f: Double }
    private struct Row { let food: Food; let words: Set<String>; let raw: Bool; let kind: [String]; let lead: [String] }

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

    private static let rows: [Row] = ((load("aus-foods") as? [JSON]) ?? []).map { r in
        let name = str(r["name"]), parts = name.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let food = Food(name: name.trimmingCharacters(in: .whitespaces), australian: str(r["source"]) == "AFCD3", kcal: num(r["kcal"]) ?? 0, p: num(r["p"]) ?? 0, c: num(r["c"]) ?? 0, f: num(r["f"]) ?? 0)
        let raw = name.range(of: #"\braw\b|uncooked"#, options: [.regularExpression, .caseInsensitive]) != nil
        return Row(food: food, words: Set(words(name)), raw: raw, kind: words(parts[0]), lead: words(parts.prefix(2).joined(separator: " ")))
    }

    private static let aliases: [String: Food] = {
        var out: [String: Food] = [:]
        for pair in (load("aus-aliases") as? [[String]]) ?? [] where pair.count == 2 {
            guard let row = rows.first(where: { $0.food.name == pair[1].trimmingCharacters(in: .whitespaces) }) else { continue }
            for n in pair[0].split(separator: "|") { out[words(String(n)).joined(separator: " ")] = row.food }
        }
        return out
    }()

    /// The food an ingredient's name means: its everyday name first, otherwise the food's own kind must match
    /// ("vegetable oil" never finds puff pastry made with it). Raw unless the name says cooked, measured Australian data first.
    static func find(_ name: String) -> Food? {
        let first = name.split(whereSeparator: { $0 == "," || $0 == "(" }).first.map(String.init) ?? ""
        let want = words(first)
        guard let head = want.last else { return nil }
        if let named = aliases[want.joined(separator: " ")] { return named }
        let cooked = name.range(of: "cooked|boiled|grilled|roast|fried|baked|steamed", options: [.regularExpression, .caseInsensitive]) != nil
        var best: (rank: Int, food: Food)?
        for r in rows where want.allSatisfy({ r.words.contains($0) }) {
            guard r.kind.contains(head) || r.kind.contains(want[0]) || want.allSatisfy({ r.lead.contains($0) }) else { continue }
            let rank = (r.raw == !cooked ? 0 : 100) + (r.food.australian ? 0 : 20) + r.words.count * 2
            if rank < (best?.rank ?? .max) { best = (rank, r.food) }
        }
        return best?.food
    }
}
