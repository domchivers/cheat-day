import Foundation

/// The weekly check-in, ported from the web app: last week's facts, what you really burn (from food and
/// weigh-ins), and a budget suggestion that moves at most 200 kcal a week.
struct CheckIn {
    var week: String, mon: String, sun: String
    var logged: Int, avg: Double?, workouts: Int
    var change: Double?            // trend weight change over last week, kg
    var burn: Double?, burnDays: Int, burnWeighins: Int
    var needs: [String]
    var pace: Double?              // kg a week over the last 4 weeks
    var want: Double?              // the plan's kg a week
    var now: Double                // average budget across the week
    var suggest: Double?
}

enum Trend {
    /// A robust local fit (LOWESS) through readings, and which readings look unusual (the web app's trendOf).
    static func fit(days: [String], values ys: [Double], tol: Double = 0.035) -> (fit: [Double], odd: [Bool]) {
        let n = ys.count
        let xs = days.map { DayKey.date($0).timeIntervalSince1970 / 86400 }
        guard n >= 3 else { return (ys, Array(repeating: false, count: n)) }
        func med(_ a: [Double]) -> Double { let b = a.sorted(), m = b.count / 2; return b.count % 2 == 1 ? b[m] : (b[m - 1] + b[m]) / 2 }
        let k = min(n, max(5, Int((Double(n) * 0.4).rounded(.up))))
        let floorV = abs(med(ys)) * 0.003 == 0 ? 0.05 : abs(med(ys)) * 0.003
        func flag(_ skip: [Bool]) -> [Bool?] {
            ys.indices.map { a -> Bool? in
                let nb = ys.indices.filter { $0 != a && !skip[$0] && abs(xs[$0] - xs[a]) <= 21 }.map { ys[$0] }
                guard nb.count >= 3 else { return nil }
                let m = med(nb), spread = med(nb.map { abs($0 - m) }) * 1.4826
                return abs(ys[a] - m) > max(tol * abs(m), min(4 * spread, 2 * tol * abs(m)))
            }
        }
        let first = flag(Array(repeating: false, count: n))
        let second = flag(first.map { $0 ?? false })
        let odd = second.indices.map { second[$0] ?? (first[$0] ?? false) }
        var rw = odd.map { $0 ? 0.0 : 1.0 }, fit = ys
        for _ in 0..<3 {
            for a in 0..<n {
                let dist = xs.map { abs($0 - xs[a]) }
                let h = max(dist.sorted()[k - 1], 14) * 1.0001
                var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, lo = Double.infinity, hi = -Double.infinity
                for b in 0..<n {
                    let u = dist[b] / h; if u >= 1 { continue }
                    let w = pow(1 - pow(u, 3), 3) * rw[b]; if w <= 0 { continue }
                    let dx = xs[b] - xs[a]
                    sw += w; sx += w * dx; sy += w * ys[b]; sxx += w * dx * dx; sxy += w * dx * ys[b]
                    if w > 0.05 { lo = min(lo, ys[b]); hi = max(hi, ys[b]) }
                }
                let den = sw * sxx - sx * sx
                var v = den > 1e-9 ? (sy * sxx - sx * sxy) / den : (sw > 0 ? sy / sw : ys[a])
                if lo.isFinite { v = min(hi, max(lo, v)) }
                fit[a] = v
            }
            let res = ys.indices.map { ys[$0] - fit[$0] }, mad = max(med(res.map { abs($0) }), floorV)
            rw = res.indices.map { a -> Double in
                if odd[a] { return 0 }
                let u = res[a] / (6 * mad)
                return abs(u) < 1 ? pow(1 - u * u, 2) : 0
            }
        }
        return (fit, odd)
    }
}

extension Store {
    private static let kcalPerKg = 7700.0

    /// Monday of the week a date is in.
    static func weekOf(_ date: String) -> String {
        let back = (DayKey.weekday(date) + 6) % 7
        return DayKey.shift(date, days: -back)
    }

    var averageBudget: Double { (0...6).reduce(0) { $0 + (pos(dict(doc["dayBudgets"])[String($1)]) ?? pos(doc["budget"]) ?? 1600) } / 7 }

    private var weights: [(day: String, kg: Double)] {
        let todayKey = DayKey.string(Date()), since = DayKey.shift(todayKey, days: -70)
        return bodyRows.compactMap { r -> (day: String, kg: Double)? in
            guard let kg = pos(r["weight"]), str(r["day"]) <= todayKey, str(r["day"]) >= since else { return nil }
            return (str(r["day"]), kg)
        }
    }

    /// kg a day over the last four weeks, ignoring unusual readings (the web app's weightTrend).
    func weightTrend() -> (perDay: Double, n: Int)? {
        let wide = weights
        let odd = wide.count >= 4 ? Trend.fit(days: wide.map(\.day), values: wide.map(\.kg)).odd : Array(repeating: false, count: wide.count)
        let since = DayKey.shift(DayKey.string(Date()), days: -28)
        let pts = wide.indices.filter { !odd[$0] && wide[$0].day >= since }.map { wide[$0] }
        guard pts.count >= 3 else { return nil }
        let t0 = DayKey.date(pts[0].day).timeIntervalSince1970 / 86400
        let xs = pts.map { DayKey.date($0.day).timeIntervalSince1970 / 86400 - t0 }, ys = pts.map(\.kg)
        guard (xs.last ?? 0) >= 7 else { return nil }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let num = xs.indices.reduce(0) { $0 + (xs[$1] - mx) * (ys[$1] - my) }, den = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        return den > 0 ? (num / den, pts.count) : nil
    }

    /// Properly logged days; a finished week with fewer than five of them is left out.
    func wellLoggedDays(since: String) -> [JSON] {
        let days = list(doc["history"]).filter { h in
            guard str(h["date"]) >= since, let b = pos(h["budget"]) else { return false }
            return (num(h["kcal"]) ?? 0) >= b * 0.6
        }
        let thisWeek = Self.weekOf(DayKey.string(Date()))
        var per: [String: Int] = [:]
        for h in days { per[Self.weekOf(str(h["date"])), default: 0] += 1 }
        return days.filter { h in let wk = Self.weekOf(str(h["date"])); return wk == thisWeek || wk < since || (per[wk] ?? 0) >= 5 }
    }

    func learnedBurn() -> (burn: Double, days: Int, weighins: Int)? {
        guard let trend = weightTrend() else { return nil }
        let days = wellLoggedDays(since: DayKey.shift(DayKey.string(Date()), days: -21))
        guard days.count >= 10 else { return nil }
        let eat = days.reduce(0) { $0 + (num($1["kcal"]) ?? 0) } / Double(days.count)
        var burn = eat - trend.perDay * Self.kcalPerKg
        if let est = pos(dict(doc["plan"])["tdee"]) { burn = max(est * 0.7, min(est * 1.3, burn)) }
        return ((burn / 10).rounded() * 10, days.count, trend.n)
    }

    var checkIn: CheckIn {
        let todayKey = DayKey.string(Date())
        let week = Self.weekOf(todayKey), mon = DayKey.shift(week, days: -7), sun = DayKey.shift(week, days: -1)
        let dates = (0..<7).map { DayKey.shift(mon, days: $0) }
        let recs = dates.compactMap { d in list(doc["history"]).first { str($0["date"]) == d && (num($0["kcal"]) ?? 0) > 0 } }
        let good = recs.filter { h in guard let b = pos(h["budget"]) else { return true }; return (num(h["kcal"]) ?? 0) >= b * 0.6 }
        let avg = good.isEmpty ? nil : (good.reduce(0) { $0 + (num($1["kcal"]) ?? 0) } / Double(good.count)).rounded()
        let workouts = recs.reduce(0) { $0 + list($1["workouts"]).count }

        let wide = weights
        var change: Double?
        var odd = Array(repeating: false, count: wide.count)
        if wide.count >= 3 {
            let t = Trend.fit(days: wide.map(\.day), values: wide.map(\.kg))
            odd = t.odd
            let pts = wide.indices.filter { !t.odd[$0] }.map { (x: DayKey.date(wide[$0].day).timeIntervalSince1970 / 86400, v: t.fit[$0]) }
            func at(_ date: String) -> Double? {
                let x = DayKey.date(date).timeIntervalSince1970 / 86400
                guard let first = pts.first, let last = pts.last else { return nil }
                if x <= first.x { return first.x - x <= 3 ? first.v : nil }
                if x >= last.x { return x - last.x <= 3 ? last.v : nil }
                guard let k = pts.firstIndex(where: { $0.x >= x }), k > 0 else { return nil }
                let p0 = pts[k - 1], p1 = pts[k]
                return p1.x == p0.x ? p1.v : p0.v + (p1.v - p0.v) * (x - p0.x) / (p1.x - p0.x)
            }
            if let s = at(DayKey.shift(mon, days: -1)), let e = at(sun) { change = ((e - s) * 10).rounded() / 10 }
        }
        let since28 = DayKey.shift(todayKey, days: -28)
        let weighins = wide.indices.filter { (wide.count < 4 || !odd[$0]) && wide[$0].day >= since28 }.count
        let goodDays = wellLoggedDays(since: DayKey.shift(todayKey, days: -21)).count
        let learned = learnedBurn()
        let enough = learned != nil && weighins >= 4
        var needs: [String] = []
        if goodDays < 10 { needs.append("\(10 - goodDays) more logged day\(10 - goodDays == 1 ? "" : "s")") }
        if weighins < 4 { needs.append("\(4 - weighins) more weigh-in\(4 - weighins == 1 ? "" : "s")") }
        if needs.isEmpty && !enough { needs.append("weigh-ins spread over at least a week") }
        let plan = doc["plan"] as? JSON
        let want = plan.map { num($0["rate"]) ?? 0 }
        let now = averageBudget
        var suggest: Double?
        if enough, let learned, let want {
            let floorK: Double = str(dict(doc["profile"])["sex"]) == "m" ? 1500 : 1200
            let target = max(floorK, ((learned.burn + want * Self.kcalPerKg / 7) / 10).rounded() * 10)
            let d = ((max(-200, min(200, target - now))) / 10).rounded() * 10
            suggest = abs(d) < 50 ? now : ((now + d) / 10).rounded() * 10
        }
        let trend = weightTrend()
        return CheckIn(week: week, mon: mon, sun: sun, logged: recs.count, avg: avg, workouts: workouts, change: change,
                       burn: enough ? learned?.burn : nil, burnDays: learned?.days ?? 0, burnWeighins: learned?.weighins ?? 0, needs: needs,
                       pace: trend.map { ($0.perDay * 7 * 100).rounded() / 100 }, want: want, now: now, suggest: suggest)
    }

    var checkInDue: Bool { str(doc["checkInSeen"]) != checkIn.week && checkIn.logged > 0 }

    /// Use the suggestion (or just mark the check-in as seen).
    func finishCheckIn(_ c: CheckIn, use: Bool) {
        perform(["type": "checkIn", "week": c.week, "use": use, "suggest": c.suggest ?? 0, "now": c.now, "burn": c.burn.map { $0 as Any } ?? NSNull(), "at": nowMs()])
    }

    static func applyCheckInOp(_ op: JSON, to d: inout JSON) {
        guard str(op["type"]) == "checkIn" else { return }
        d["checkInSeen"] = op["week"] ?? ""
        var plan = d["plan"] as? JSON
        if plan != nil {
            plan?["lastCheckIn"] = op["at"] ?? nowMs()
            if let b = num(op["burn"]) { plan?["learnedBurn"] = b; plan?["learnedAt"] = op["at"] ?? nowMs() }
        }
        if (op["use"] as? Bool) == true, let suggest = pos(op["suggest"]), let now = pos(op["now"]) {
            let ratio = suggest / now, diff = suggest - now
            func r10(_ v: Double) -> Int { Int((v / 10).rounded() * 10) }
            d["budget"] = r10((pos(d["budget"]) ?? 1600) * ratio)
            var days = dict(d["dayBudgets"]); for (k, v) in days { if let n = num(v) { days[k] = r10(n * ratio) } }; d["dayBudgets"] = days
            if plan != nil {
                plan?["kcal"] = Int(suggest)
                if var macros = plan?["macros"] as? JSON, let c = num(macros["c"]) {
                    macros["c"] = max(0, Int(c) + Int((diff / 4).rounded())); plan?["macros"] = macros
                    var goals = dict(d["goals"]); if goals["c"] != nil && !(goals["c"] is NSNull) { goals["c"] = macros["c"]; d["goals"] = goals }
                }
            }
        }
        if let plan { d["plan"] = plan }
    }
}
