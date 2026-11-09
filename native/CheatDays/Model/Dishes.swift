import Foundation

/// A meal's foods as Today shows them: dishes (foods added together in one go, shown as one row that opens to show
/// them) and single foods. A dish is foods sharing a dish tag (set when an estimate's Add, a takeaway's Add all or
/// yesterday's meal again puts them on), or, for foods from before tags, three or more added within two seconds of
/// each other to the same meal (one tap, nobody types that fast), named after the meal. Split foods stay apart.
enum Dishes {
    struct Dish: Identifiable {
        let id: String, name: String, items: [JSON]
        var kcal: Double { items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) } }
        var ids: [String] { items.map { str($0["id"]) } }
    }
    enum Row: Identifiable {
        case food(JSON), dish(Dish)
        var id: String {
            switch self {
            case .food(let f): return str(f["id"]).isEmpty ? str(f["name"]) + str(f["addedAt"]) : str(f["id"])
            case .dish(let d): return "dish:" + d.id
            }
        }
    }

    static func rows(_ items: [JSON], meal: String) -> [Row] {
        var groups: [String: [Int]] = [:]   // dish id → indexes of its foods
        // tagged
        for (i, it) in items.enumerated() where !str(it["dish"]).isEmpty { groups[str(it["dish"]), default: []].append(i) }
        // untagged, added in one go
        let loose = items.indices.filter { str(items[$0]["dish"]).isEmpty && items[$0]["undished"] as? Bool != true }
            .compactMap { i in ISO.date(str(items[i]["addedAt"])).map { (i, $0) } }.sorted { $0.1 < $1.1 }
        var run: [(Int, Date)] = []
        func close() { if run.count >= 3 { groups["t:" + str(items[run[0].0]["id"])] = run.map(\.0) }; run = [] }
        for x in loose {
            if let last = run.last, x.1.timeIntervalSince(last.1) > 2 { close() }
            run.append(x)
        }
        close()
        // one row a group, where its first food was; the rest as they are
        var inGroup: [Int: String] = [:]
        for (g, idx) in groups { for i in idx { inGroup[i] = g } }
        var out: [Row] = [], shown = Set<String>()
        for (i, it) in items.enumerated() {
            guard let g = inGroup[i] else { out.append(.food(it)); continue }
            guard !shown.contains(g), let idx = groups[g] else { continue }
            shown.insert(g)
            let foods = idx.sorted().map { items[$0] }
            let named = foods.map { str($0["dishName"]) }.first { !$0.isEmpty }
            // a tag with only one food left (the rest deleted) is just that food
            if foods.count < 2 { out.append(.food(foods[0])); continue }
            out.append(.dish(Dish(id: g, name: named ?? "\(meal) · \(foods.count) foods", items: foods)))
        }
        return out
    }
}
