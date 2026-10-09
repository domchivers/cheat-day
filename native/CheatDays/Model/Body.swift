import Foundation

/// Weigh-ins: kept in the record's `body` list (one row per day) and in the `body_metrics` table, where
/// scale imports land too. Same rules as the web app's upsertBody and pullBody.
extension Store {
    static let bodyKeys = ["weight", "fat", "muscle", "lean", "water", "bone", "visceral", "bmr", "age", "bmi"]

    var bodyRows: [JSON] { list(doc["body"]).sorted { str($0["day"]) < str($1["day"]) } }
    var latestWeight: (day: String, kg: Double)? {
        let todayKey = DayKey.string(Date())
        guard let r = bodyRows.last(where: { pos($0["weight"]) != nil && str($0["day"]) <= todayKey }) else { return nil }
        return (str(r["day"]), pos(r["weight"]) ?? 0)
    }

    func weighIn(_ kg: Double, fat: Double? = nil, day: String? = nil) {
        var row: JSON = ["day": day ?? DayKey.string(Date()), "updatedAt": ISO.now(), "weight": (kg * 10).rounded() / 10]
        if let fat { row["fat"] = (fat * 10).rounded() / 10 }
        perform(["type": "body", "row": row])
        Task {
            guard let me = Supabase.shared.userId else { return }
            var cloud = row; cloud.removeValue(forKey: "updatedAt"); cloud["user_id"] = me; cloud["updated_at"] = ISO.now()
            _ = try? await Supabase.shared.rest("/rest/v1/body_metrics?on_conflict=user_id,day", method: "POST", body: [cloud], prefer: "resolution=merge-duplicates")
        }
    }

    /// Readings that arrived from elsewhere (a scale's Shortcut, another phone) come into the record.
    func pullBody() async {
        guard let me = Supabase.shared.userId else { return }
        let since = DayKey.shift(DayKey.string(Date()), days: -400)
        guard let d = try? await Supabase.shared.rest("/rest/v1/body_metrics?user_id=eq.\(me)&day=gte.\(since)&select=*&order=day.asc"),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else { return }
        let mine = Dictionary(bodyRows.map { (str($0["day"]), $0) }, uniquingKeysWith: { a, _ in a })
        let tombs = dict(doc["tombs"])
        for case let r as JSON in rows {
            let day = str(r["day"]), at = str(r["updated_at"])
            if let m = mine[day], str(m["updatedAt"]) >= at { continue }
            if let gone = num(tombs["body:\(day)"]), let t = ISO.date(at), gone >= t.timeIntervalSince1970 * 1000 { continue }
            var row: JSON = ["day": day, "updatedAt": at]
            for k in Self.bodyKeys { if let v = num(r[k]) { row[k] = v } }
            perform(["type": "body", "row": row], syncAfter: 2)
        }
    }

    static func applyBodyOp(_ op: JSON, to d: inout JSON) {
        guard str(op["type"]) == "body" else { return }
        let row = dict(op["row"]), day = str(row["day"])
        guard !day.isEmpty else { return }
        var tombs = dict(d["tombs"]); if tombs["body:\(day)"] != nil { tombs.removeValue(forKey: "body:\(day)"); d["tombs"] = tombs }
        var body = list(d["body"])
        if let i = body.firstIndex(where: { str($0["day"]) == day }) { body[i].merge(row) { _, new in new } } else { body.append(row) }
        body.sort { str($0["day"]) < str($1["day"]) }
        d["body"] = Array(body.suffix(400))
        let todayKey = DayKey.string(Date())
        if let last = body.last(where: { pos($0["weight"]) != nil && str($0["day"]) <= todayKey }), let w = pos(last["weight"]) { d["weightKg"] = (w * 10).rounded() / 10 }
    }
}
