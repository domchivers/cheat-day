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

    /// The latest weigh-in exactly as the scale read it, and when.
    var lastWeighIn: (kg: Double, day: String, at: Date?)? {
        let todayKey = DayKey.string(Date())
        guard let r = bodyRows.last(where: { pos($0["weight"]) != nil && str($0["day"]) <= todayKey }) else { return nil }
        return (pos(r["weight"]) ?? 0, str(r["day"]), ISO.date(str(r["takenAt"]).isEmpty ? str(r["updatedAt"]) : str(r["takenAt"])))
    }

    /// The smoothed trend weight, worked out one way everywhere (the last 120 days of weigh-ins).
    var trendWeight: Double? {
        let since = DayKey.shift(today, days: -120)
        let rows = bodyRows.compactMap { r -> (String, Double)? in
            guard let kg = pos(r["weight"]), str(r["day"]) >= since, str(r["day"]) <= today else { return nil }
            return (str(r["day"]), kg)
        }
        guard rows.count >= 4 else { return rows.last?.1 }
        return Trend.fit(days: rows.map(\.0), values: rows.map(\.1)).fit.last
    }

    /// "today, 7:42", "yesterday, 7:42", "Mon 13 Oct, 7:42"; just the day when the time isn't known.
    static func whenTaken(day: String, at: Date?) -> String {
        let d = Store.when(day)
        let dayText = d == "today" || d == "yesterday" ? d : DayKey.date(day).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard let at, DayKey.string(at) == day else { return dayText }
        return "\(dayText), \(at.formatted(date: .omitted, time: .shortened))"
    }

    func weighIn(_ kg: Double, fat: Double? = nil, day: String? = nil) {
        var row: JSON = ["day": day ?? DayKey.string(Date()), "updatedAt": ISO.now(), "weight": Fmt.kg2(kg)]
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
        if str(op["type"]) == "deleteBody" {
            let day = str(op["day"])
            d["body"] = list(d["body"]).filter { str($0["day"]) != day }
            var tombs = dict(d["tombs"]); tombs["body:\(day)"] = op["at"] ?? nowMs(); d["tombs"] = tombs
            return
        }
        guard str(op["type"]) == "body" else { return }
        let row = dict(op["row"]), day = str(row["day"])
        guard !day.isEmpty else { return }
        var tombs = dict(d["tombs"]); if tombs["body:\(day)"] != nil { tombs.removeValue(forKey: "body:\(day)"); d["tombs"] = tombs }
        var body = list(d["body"])
        if let i = body.firstIndex(where: { str($0["day"]) == day }) { body[i].merge(row) { _, new in new } } else { body.append(row) }
        body.sort { str($0["day"]) < str($1["day"]) }
        d["body"] = Array(body.suffix(400))
        let todayKey = DayKey.string(Date())
        if let last = body.last(where: { pos($0["weight"]) != nil && str($0["day"]) <= todayKey }), let w = pos(last["weight"]) { d["weightKg"] = Fmt.kg2(w) }
    }
}
