import Foundation

/// Each food's icon, picked once per name by the AI from the app's own icons (it knows what a food is: matcha chips are
/// crisps, not tea, and the next one nobody has thought of yet), kept on the phone. Until it has answered, and with no
/// connection, the word rules in FoodEmoji show. Names are asked for in batches, a fraction of a cent each.
@Observable @MainActor
final class FoodIcons {
    static let shared = FoodIcons()
    private static let key = "food.icons"

    /// Name (lowercased) to the emoji picked for it.
    private(set) var picked: [String: String]
    @ObservationIgnored private var waiting: [String: (name: String, hint: String)] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var running = false

    private init() { picked = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    /// The icon for a food: the AI's pick for this name once there is one, else the rules (the database entry it was
    /// matched to first, when there is one: its kind leads its name, "Snack, corn chips").
    func icon(_ name: String, hint: String = "") -> String? {
        let k = Self.norm(name)
        guard !k.isEmpty else { return nil }
        if let e = picked[k] { return e }
        if !asked.contains(k) {
            asked.insert(k)
            let n = name, h = hint
            Task { @MainActor in self.queue(k, n, h) }   // not while a view is drawing
        }
        let kind = hint.split(separator: ",").first.map(String.init) ?? ""
        return (kind.isEmpty ? nil : FoodEmoji.for(kind)) ?? FoodEmoji.for(name)
    }

    static func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

    private func queue(_ k: String, _ name: String, _ hint: String) {
        waiting[k] = (name, hint)
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    /// A moment to gather the names on screen, then up to 25 at a time.
    private func drain() async {
        try? await Task.sleep(for: .seconds(1.5))
        while !waiting.isEmpty {
            let batch = Array(waiting.prefix(25))
            for (k, _) in batch { waiting[k] = nil }
            if let found = await Self.ask(batch.map { $0.value }) {
                for (i, (k, _)) in batch.enumerated() where i < found.count { if let e = found[i] { picked[k] = e } }
                UserDefaults.standard.set(picked, forKey: Self.key)
            }
        }
        running = false
    }

    static let schema: JSON = ["type": "object", "required": ["icons"], "properties": ["icons": ["type": "array", "items": [
        "type": "object", "required": ["n", "icon"],
        "properties": ["n": ["type": "number"] as JSON, "icon": ["type": "string", "enum": FoodEmoji.icons] as JSON] as JSON] as JSON] as JSON] as JSON]

    static func prompt(_ foods: [(name: String, hint: String)]) -> String {
        "Pick the icon that best shows each food in a food diary: what the food itself is, not a flavour or an ingredient in its name (matcha chips are crisps, not tea; mulled wine is wine). For a meal of several things, the main dish. Coffees, lattes and iced coffees are the coffee cup; yoghurt is the bowl. Answer with each food's number.\n"
            + foods.enumerated().map { i, f in "\(i + 1). \(f.name)" + (f.hint.isEmpty ? "" : " (food table entry: \(f.hint))") }.joined(separator: "\n")
    }

    /// The AI's pick for each, in order (nil where it gave none).
    private static func ask(_ foods: [(name: String, hint: String)]) async -> [String?]? {
        guard let answer = try? await Gemini.ask(schema: schema, parts: [["text": prompt(foods)]], quick: true, tries: 1, job: "quick") else { return nil }
        var out = [String?](repeating: nil, count: foods.count)
        for p in CheatDays.list(answer["icons"]) {
            if let n = num(p["n"]).map({ Int($0) - 1 }), out.indices.contains(n), FoodEmoji.icons.contains(str(p["icon"])) { out[n] = str(p["icon"]) }
        }
        return out
    }
}
