import Foundation

/// Puts back food that went missing from past days. Until 30 October a web screen that hadn't run for days could file
/// its half-logged copy of a day over the whole one (usually dinner and the evening's snacks were lost). Each day's
/// shared summary (what friends saw, as the day ended) still lists everything, and the daily backups have the full
/// foods with their macros, so the app compares, once per account, and adds back what History is missing. It only
/// ever adds: a food deleted that day isn't in the summary, so it can't come back.
extension Store {
    private static let repairKey = "repair.history.v1."

    /// Runs once per account, after a sync; quietly does nothing offline (it tries again next launch).
    func repairHistory() async {
        guard let user = Supabase.shared.userId, lastSynced != nil,
              !UserDefaults.standard.bool(forKey: Self.repairKey + user) else { return }
        guard let shared = try? await Supabase.shared.myDays() else { return }
        let found = Self.missingFood(history: list(doc["history"]), shared: shared, since: DayKey.shift(today, days: -120), before: today)
        guard !found.isEmpty else { UserDefaults.standard.set(true, forKey: Self.repairKey + user); return }

        // the full versions (with protein, carbs and fat) from the backups, where there are any
        let backups = (try? await Supabase.shared.backups()) ?? []
        var rich: [String: JSON] = [:], workouts: [String: [JSON]] = [:]
        for b in backups {
            let d = dict(b["data"])
            var entries = list(d["history"])
            if !dict(d["day"]).isEmpty { entries.append(dict(d["day"])) }
            for e in entries where found[str(e["date"])] != nil {
                let date = str(e["date"])
                for it in list(e["items"]) { let k = date + "|" + Self.foodKey(it); if rich[k] == nil || FoodMath.macros(it, kcal: num(it["kcal"]) ?? 0) != nil { rich[k] = it } }
                if list(e["workouts"]).count > workouts[date, default: []].count { workouts[date] = list(e["workouts"]) }
            }
        }
        var days = 0
        for (date, miss) in found {
            let items: [JSON] = miss.items.map { p in
                let it = rich[date + "|" + Self.foodKey(p)] ?? p
                var b = FoodMath.basisOf(it)
                b["kcal"] = p["kcal"] ?? it["kcal"] ?? 0
                b["shareLabel"] = it["shareLabel"] ?? ""
                b["addedAt"] = p["addedAt"] ?? it["addedAt"] ?? NSNull()
                b["meal"] = p["meal"] ?? it["meal"] ?? NSNull()
                return b
            }
            let wos = miss.workouts > 0 ? (workouts[date] ?? []) : []
            guard !items.isEmpty || !wos.isEmpty else { continue }
            perform(["type": "restorePast", "date": date, "items": items, "workouts": wos], syncAfter: 1)
            days += 1
        }
        UserDefaults.standard.set(true, forKey: Self.repairKey + user)
        if days > 0 { notice = "Found food missing from \(days) past day\(days == 1 ? "" : "s") and put it back." }
    }

    /// Runs once per account: a day whose calories were raised, then overwritten by a stale copy, gets them back,
    /// so it doesn't show as over when it wasn't.
    func repairBudgets() async {
        let key = "repair.budget.v1."
        guard let user = Supabase.shared.userId, lastSynced != nil, !UserDefaults.standard.bool(forKey: key + user),
              let shared = try? await Supabase.shared.myDays() else { return }
        for (date, budget) in Self.lostBudgets(history: list(doc["history"]), shared: shared, before: today) {
            perform(["type": "restorePast", "date": date, "items": [Any](), "workouts": [Any](), "budget": budget], syncAfter: 1)
        }
        UserDefaults.standard.set(true, forKey: key + user)
    }

    /// Past days showing as over, whose shared summary had a higher budget that day.
    static func lostBudgets(history: [JSON], shared: [JSON], before: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in shared {
            let date = str(s["day"])
            guard date < before, let b = pos(s["budget"]), let h = history.first(where: { str($0["date"]) == date }),
                  let have = num(h["budget"]), b > have, (num(h["kcal"]) ?? 0) > have else { continue }
            out[date] = b
        }
        return out
    }

    static func foodKey(_ it: JSON) -> String { "\(str(it["name"]).lowercased())|\(Int((num(it["kcal"]) ?? 0).rounded()))|\(str(it["addedAt"]))" }

    /// Per past date, the foods in its shared summary that History doesn't have, and how many workouts it's short.
    /// A day counts only when at least 30 kcal of food is missing (rounding and late edits aside).
    static func missingFood(history: [JSON], shared: [JSON], since: String, before: String) -> [String: (items: [JSON], workouts: Int)] {
        let byDate = Dictionary(history.map { (str($0["date"]), $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: (items: [JSON], workouts: Int)] = [:]
        for s in shared {
            let date = str(s["day"])
            guard date >= since, date < before, let h = byDate[date] else { continue }
            let have = Set(list(h["items"]).map(foodKey))
            let all = list(s["items"])
            let food = all.filter { (num($0["kcal"]) ?? 0) > 0 && !str($0["name"]).hasPrefix("Workout: ") }
            let missing = food.filter { !have.contains(foodKey($0)) }
            guard missing.reduce(0, { $0 + (num($1["kcal"]) ?? 0) }) >= 30 else { continue }
            let sharedWorkouts = all.filter { str($0["name"]).hasPrefix("Workout: ") }.count
            out[date] = (missing, max(0, sharedWorkouts - list(h["workouts"]).count))
        }
        return out
    }

    /// The op: foods (and workouts) put back on a past day, each once, the totals worked out again.
    static func applyRestore(_ op: JSON, to d: inout JSON) {
        guard str(op["type"]) == "restorePast" else { return }
        let date = str(op["date"])
        var history = list(d["history"])
        guard let i = history.firstIndex(where: { str($0["date"]) == date }) else { return }
        if let b = num(op["budget"]) {   // only the budget: the day's food and totals stay as they are
            history[i]["budget"] = max(b, num(history[i]["budget"]) ?? 0)
            d["history"] = history
            return
        }
        var items = list(history[i]["items"]), have = Set(items.map(foodKey))
        for it in list(op["items"]) where have.insert(foodKey(it)).inserted {
            // the same food added at the same moment with another amount: it was changed that day, so it's updated
            let at = str(it["addedAt"]), name = str(it["name"]).lowercased()
            if !at.isEmpty, let j = items.firstIndex(where: { str($0["addedAt"]) == at && str($0["name"]).lowercased() == name }) {
                items[j]["kcal"] = it["kcal"]
            } else { items.append(it) }
        }
        var wos = list(history[i]["workouts"])
        func wkey(_ w: JSON) -> String { "\(str(w["name"]))|\(Int((num(w["minutes"]) ?? 0).rounded()))|\(Int((num(w["kcal"]) ?? 0).rounded()))" }
        var wHave = Set(wos.map(wkey))
        for w in list(op["workouts"]) where wHave.insert(wkey(w)).inserted {
            wos.append(["name": w["name"] ?? "", "type": w["type"] ?? NSNull(), "effort": w["effort"] ?? NSNull(),
                        "minutes": w["minutes"] ?? 0, "kcal": w["kcal"] ?? 0, "lifts": w["lifts"] ?? [Any]()] as JSON)
        }
        var p = 0.0, c = 0.0, f = 0.0
        for it in items { if let m = FoodMath.macros(it, kcal: num(it["kcal"]) ?? 0) { p += m.p; c += m.c; f += m.f } }
        history[i]["items"] = items
        history[i]["workouts"] = wos
        history[i]["kcal"] = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        history[i]["burned"] = wos.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        history[i]["p"] = Int(p.rounded()); history[i]["c"] = Int(c.rounded()); history[i]["f"] = Int(f.rounded())
        d["history"] = history
    }
}
