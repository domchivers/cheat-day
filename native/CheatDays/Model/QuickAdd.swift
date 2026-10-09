import Foundation

/// Something that can be added in a tap: a preset, a saved meal, a recent food, any food from History, or the food list.
struct QuickEntry: Identifiable {
    enum Kind { case preset, meal, recent, past, food }
    var id: String { key }
    let key: String
    let basis: JSON
    let kcal: Double
    let detail: String
    let uses: Double
    let lastUsed: String
    let kind: Kind
    var name: String { str(basis["name"]) }
}

/// The bundled food list and presets (copied from the web app by tools/native-data.sh).
enum FoodsDB {
    static let rows: [[Any]] = load("foods") as? [[Any]] ?? []
    static let presets: [JSON] = (load("presets") as? [Any])?.compactMap { $0 as? JSON } ?? []
    private static func load(_ name: String) -> Any? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// Everyday foods matching every word (plurals folded), best matches first (the web app's searchLocal, simplified).
    static func search(_ query: String, limit: Int = 25) -> [JSON] {
        let stop: Set<String> = ["a", "an", "of", "the", "and", "with", "some", "my", "one"]
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { !$0.isEmpty && !stop.contains($0) }
        guard !words.isEmpty else { return [] }
        var scored: [(Int, [Any])] = []
        for row in rows {
            let name = str(row.first).lowercased()
            let hay = name + " " + (row.count > 3 ? str(row[3]) : "") + " " + (row.count > 5 ? str(row[5]).lowercased() : "")
            var score = 0, ok = true
            for raw in words {
                let forms = Set([raw, raw.replacingOccurrences(of: "(ies|es|s)$", with: "", options: .regularExpression), raw.replacingOccurrences(of: "ies$", with: "y", options: .regularExpression)]).filter { !$0.isEmpty }
                var best = 0
                for w in forms {
                    if name.hasPrefix(w) { best = max(best, 3) }
                    else if name.contains(" " + w) || name.contains("," + w) { best = max(best, 2) }
                    else if hay.contains(w) { best = max(best, 1) }
                }
                if best == 0 { ok = false; break }
                score += best
            }
            if ok { scored.append((score * 100 - name.count, row)) }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map { FoodMath.foodItem($0.1) }
    }
}

extension Store {
    func isFavourite(_ key: String) -> Bool { (dict(dict(doc["favs"])[key])["on"] as? Bool) == true }

    /// Presets, saved meals and recent foods, most used first (the web app's quickEntries).
    var quickEntries: [QuickEntry] { cached("quick") { buildQuickEntries() } }
    private func buildQuickEntries() -> [QuickEntry] {
        var out: [QuickEntry] = []
        let presetUses = dict(doc["presetUses"])
        for p in FoodsDB.presets {
            let name = str(p["name"]), kcal = (num(p["kcal"]) ?? 0).rounded()
            var basis: JSON = ["name": name, "source": "quick", "unit": "ml", "unitLabel": str(p["unit"]).isEmpty ? "serving" : str(p["unit"]), "kcalPerServing": kcal]
            if let v = num(p["protein"]) { basis["pServ"] = v; basis["cServ"] = num(p["carbs"]) ?? 0; basis["fServ"] = num(p["fat"]) ?? 0 }
            out.append(QuickEntry(key: "preset:" + name, basis: basis, kcal: kcal, detail: str(p["detail"]), uses: num(presetUses[name]) ?? 0, lastUsed: "", kind: .preset))
        }
        for m in list(doc["meals"]) {
            let basis = mealBasis(m), kcal = (num(basis["kcalPerServing"]) ?? 0).rounded()
            guard kcal > 0 else { continue }
            out.append(QuickEntry(key: "meal:" + str(m["id"]), basis: basis, kcal: kcal, detail: "1 portion of \(Int(num(m["portions"]) ?? 1))",
                                  uses: num(m["uses"]) ?? 0, lastUsed: str(m["lastUsed"]), kind: .meal))
        }
        for r in list(doc["recent"]) {
            let basis = dict(r["basis"]), kcal = num(r["lastKcal"]) ?? 0
            guard !str(basis["name"]).isEmpty else { continue }
            out.append(QuickEntry(key: str(r["key"]), basis: basis, kcal: kcal, detail: FoodMath.amountText(basis, kcal: kcal),
                                  uses: num(r["uses"]) ?? 0, lastUsed: str(r["lastUsed"]), kind: .recent))
        }
        return out.sorted { ($0.uses, $0.lastUsed) > ($1.uses, $1.lastUsed) }
    }

    var favourites: [QuickEntry] { quickEntries.filter { isFavourite($0.key) }.sorted { $0.name < $1.name } }

    /// What you usually have at this meal, from the days with times kept (the web app's mealHabits).
    func usual(for meal: String) -> [QuickEntry] { cached("usual-" + meal) { buildUsual(meal) } }
    private func buildUsual(_ meal: String) -> [QuickEntry] {
        var counts: [String: [String: Int]] = [:]
        func count(_ it: JSON) {
            guard it["addedAt"] as? String != nil || !str(it["meal"]).isEmpty else { return }
            let k = str(it["name"]).lowercased(), g = Meals.of(it)
            counts[k, default: [:]][g, default: 0] += 1
        }
        todayItems.forEach(count)
        for h in list(doc["history"]).prefix(60) { list(h["items"]).forEach(count) }
        let scored: [(QuickEntry, Int)] = quickEntries.compactMap { e in
            let h = counts[e.name.lowercased()] ?? [:], n = h[meal] ?? 0, top = h.values.max() ?? 0
            return n > 0 && n * 2 >= top ? (e, n) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(6).map { $0.0 }
    }

    /// Everything ever logged that matches, then the food list.
    func search(_ query: String) -> (mine: [QuickEntry], foods: [JSON]) { cached("search-" + query.lowercased()) { buildSearch(query) } }
    private func buildSearch(_ query: String) -> (mine: [QuickEntry], foods: [JSON]) {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ([], []) }
        let hit: (JSON) -> Bool = { b in let t = (str(b["name"]) + " " + str(b["brand"])).lowercased(); return words.allSatisfy { t.contains($0) } }
        var mine = quickEntries.filter { hit($0.basis) }
        var seen = Set(mine.map { ($0.name + "|" + str($0.basis["brand"])).lowercased() })
        let days: [(String, [JSON])] = [(str(day["date"]), list(day["items"]))] + list(doc["history"]).map { (str($0["date"]), list($0["items"])) }
        for (date, items) in days {
            for it in items where hit(it) {
                let k = (str(it["name"]) + "|" + str(it["brand"])).lowercased()
                guard !seen.contains(k), let kcal = num(it["kcal"]), kcal > 0 else { continue }
                seen.insert(k)
                let basis = FoodMath.basisOf(it)
                mine.append(QuickEntry(key: k, basis: basis, kcal: kcal, detail: "last had \(Self.when(date))", uses: 1, lastUsed: date, kind: .past))
            }
        }
        mine.sort { (isFavourite($0.key) ? 1 : 0, $0.uses) > (isFavourite($1.key) ? 1 : 0, $1.uses) }
        return (Array(mine.prefix(40)), FoodsDB.search(query))
    }

    static func when(_ date: String) -> String {
        let t = DayKey.string(Date())
        if date == t { return "today" }
        if date == DayKey.shift(t, days: -1) { return "yesterday" }
        return DayKey.date(date).formatted(.dateTime.day().month(.abbreviated))
    }

    /// A saved meal as one food: a portion of it (the web app's mealBasis).
    func mealBasis(_ m: JSON) -> JSON {
        var kcal = 0.0, grams = 0.0
        let items = list(m["items"])
        for it in items {
            let k = num(it["kcal"]) ?? 0
            kcal += k
            if let g = num(it["grams"]) ?? FoodMath.amounts(it, kcal: k).grams { grams += g }
        }
        let mac = macros(items), portions = pos(m["portions"]) ?? 1
        var b: JSON = ["name": str(m["name"]).isEmpty ? "Meal" : str(m["name"]), "source": "meal", "mealId": str(m["id"]), "unit": "g",
                       "kcalPerServing": kcal / portions, "unitLabel": "portion",
                       "pServ": mac.p / portions, "cServ": mac.c / portions, "fServ": mac.f / portions]
        if grams > 0 {
            b["kcalPer100"] = kcal / grams * 100; b["servingSize"] = grams / portions
            b["p100"] = mac.p / grams * 100; b["c100"] = mac.c / grams * 100; b["f100"] = mac.f / grams * 100
        }
        if let photo = m["photo"] as? String, !photo.hasPrefix("data:") { b["photo"] = photo }
        return b
    }
}
