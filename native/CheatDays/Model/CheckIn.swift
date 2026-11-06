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
    var suggest: Double?           // the new daily average, only when it's worth acting on
    var rate: Adaptive.Rate? = nil
    var tol: Double? = nil         // kg a week either side of the goal that's still on it
    var wellLogged = 0             // last week's days with at least half their budget logged
    var step: Double? = nil        // kcal a day to add (or take off), when it's worth acting on
    var verdict = ""               // what the check-in makes of it, in a line or two
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

    /// kg a day from the weigh-ins that count (Adaptive.rate): the weigh-in day's, or the last four weeks'.
    func weightTrend() -> (perDay: Double, n: Int)? { weightRate().map { ($0.perDay, $0.used.count) } }

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
        // a third of the way to what this week says, from last check-in's figure, so one week can't swing it
        if let before = pos(dict(doc["plan"])["learnedBurn"]) { burn = before * 0.7 + burn * 0.3 }
        return ((burn / 10).rounded() * 10, days.count, trend.n)
    }

    var checkIn: CheckIn { cached("checkIn-" + DayKey.string(Date())) { buildCheckIn() } }
    private func buildCheckIn() -> CheckIn {
        let todayKey = DayKey.string(Date())
        let week = Self.weekOf(todayKey), mon = DayKey.shift(week, days: -7), sun = DayKey.shift(week, days: -1)
        let dates = (0..<7).map { DayKey.shift(mon, days: $0) }
        // each day as the diary shows it, filed or not (a Sunday not yet filed when the check-in opens Monday was
        // left out, and with it often the biggest day of the week); only a barely-logged day (under a third of its
        // budget, a forgotten one) stays out of the average
        let days = dates.compactMap { d -> (kcal: Double, budget: Double)? in
            guard let p = pastDay(d), p.kcal > 0 else { return nil }
            return (p.kcal, p.budget)
        }
        let good = days.filter { $0.budget <= 0 || $0.kcal >= $0.budget / 3 }
        let avg = good.isEmpty ? nil : (good.reduce(0) { $0 + $1.kcal } / Double(good.count)).rounded()
        let recs = dates.compactMap { d in list(doc["history"]).first { str($0["date"]) == d } }
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
                if x <= first.x { return first.x - x <= 7 ? first.v : nil }   // weekly weigh-ins: a reading within the week will do
                if x >= last.x { return x - last.x <= 7 ? last.v : nil }
                guard let k = pts.firstIndex(where: { $0.x >= x }), k > 0 else { return nil }
                let p0 = pts[k - 1], p1 = pts[k]
                return p1.x == p0.x ? p1.v : p0.v + (p1.v - p0.v) * (x - p0.x) / (p1.x - p0.x)
            }
            if let s = at(DayKey.shift(mon, days: -1)), let e = at(sun) { change = ((e - s) * 10).rounded() / 10 }
        }
        // weighing once a week is enough: three weigh-ins over the last six weeks
        let since42 = DayKey.shift(todayKey, days: -42)
        let weighins = wide.indices.filter { (wide.count < 4 || !odd[$0]) && wide[$0].day >= since42 }.count
        let goodDays = wellLoggedDays(since: DayKey.shift(todayKey, days: -21)).count
        let learned = learnedBurn()
        let enough = learned != nil && weighins >= 3
        var needs: [String] = []
        if goodDays < 10 { needs.append("\(10 - goodDays) more logged day\(10 - goodDays == 1 ? "" : "s")") }
        if weighins < 3 { needs.append("\(3 - weighins) more weigh-in\(3 - weighins == 1 ? "" : "s")") }
        if needs.isEmpty && !enough { needs.append("weigh-ins spread over at least a week") }
        let plan = doc["plan"] as? JSON
        let want = plan.map { num($0["rate"]) ?? 0 }
        let now = averageBudget
        let rate = weightRate(), wellLogged = days.filter { $0.budget > 0 && $0.kcal >= $0.budget * 0.5 }.count
        let tol = want.map { Adaptive.tolerance(want: $0, kg: latestWeight?.kg ?? 75) }
        var step: Double?, verdict = ""
        if let want, let tol, let rate {
            let pace = rate.perWeek, off = Adaptive.off(pace, want: want, tol: tol)
            // a week ago's rate, worked out the same way: off then too means it's not one week's water
            let before = weightRate(asOf: DayKey.shift(todayKey, days: -7)).map { Adaptive.off($0.perWeek, want: want, tol: tol) } ?? false
            let far = Adaptive.farOff(pace, want: want, tol: tol)
            let more = pace < want   // under the goal's line: losing faster, or not gaining enough, so more food
            let which = want < 0 ? (more ? "Losing faster than your goal" : "Losing slower than your goal")
                      : want > 0 ? (more ? "Gaining slower than your goal" : "Gaining faster than your goal")
                      : (more ? "Losing when your goal is to hold" : "Gaining when your goal is to hold")
            if !off {
                verdict = "On track. Budget unchanged."
            } else if let s = rate.swing, let last = rate.used.last {
                verdict = "\(DayKey.date(last.day).formatted(.dateTime.weekday(.wide)))'s \(Fmt.kg(last.kg)) looks like a water swing, \(Fmt.one(abs(s))) kg \(s < 0 ? "under" : "over") your trend. Not changing anything on one reading. We'll check again next week."
            } else if !before && !far {
                verdict = "\(which) this week. Could be water, so nothing changes yet. We'll check again next week."
            } else if wellLogged < 6 {
                verdict = "Only \(wellLogged) of 7 days logged. Log every day this week so the check-in can tell what to change."
            } else if enough, let learned {
                let floorK: Double = str(dict(doc["profile"])["sex"]) == "m" ? 1500 : 1200
                var target = max(floorK, pos(plan?["bmr"]).map { $0 * 1.3 } ?? 0, learned.burn + want * Self.kcalPerKg / 7)
                if want < 0 { target = min(target, learned.burn - 200) }   // still a cut
                step = Adaptive.step(target: target, now: now)
                let why = before ? "for 2 weeks in a row" : "by a long way"
                verdict = step == nil ? "Off your goal, but by less than 75 kcal a day. Budget unchanged."
                    : "\(which) \(why). " + (more ? (pace < 0 ? "A little more food protects your muscle." : "A little more food gets it moving.")
                                                  : (want > 0 ? "A little less food keeps the gain lean." : "A little less food gets it moving again."))
            } else {
                verdict = "Off your goal, but it needs \(needs.joined(separator: " and ")) before it can work out a new budget."
            }
        }
        return CheckIn(week: week, mon: mon, sun: sun, logged: days.count, avg: avg, workouts: workouts, change: change,
                       burn: enough ? learned?.burn : nil, burnDays: learned?.days ?? 0, burnWeighins: learned?.weighins ?? 0, needs: needs,
                       pace: rate.map { ($0.perWeek * 100).rounded() / 100 }, want: want, now: now, suggest: step.map { now + $0 },
                       rate: rate, tol: tol, wellLogged: wellLogged, step: step, verdict: verdict)
    }

    var checkInDue: Bool { str(doc["checkInSeen"]) != checkIn.week && checkIn.logged > 0 }

    /// Use the suggestion (or just mark the check-in as seen).
    func finishCheckIn(_ c: CheckIn, use: Bool) {
        perform(["type": "checkIn", "week": c.week, "use": use, "suggest": c.suggest ?? 0, "now": c.now, "burn": c.burn.map { $0 as Any } ?? NSNull(), "at": nowMs(),
                 "step": c.step.map { $0 as Any } ?? NSNull(), "treat": cheatWeekday.map { $0 as Any } ?? NSNull()])
    }

    static func applyCheckInOp(_ op: JSON, to d: inout JSON) {
        guard str(op["type"]) == "checkIn" else { return }
        d["checkInSeen"] = op["week"] ?? ""
        var plan = d["plan"] as? JSON
        if plan != nil {
            plan?["lastCheckIn"] = op["at"] ?? nowMs()
            if let b = num(op["burn"]) { plan?["learnedBurn"] = b; plan?["learnedAt"] = op["at"] ?? nowMs() }
        }
        // a step: the week's change goes on every day but the treat day
        if (op["use"] as? Bool) == true, let step = num(op["step"]) {
            var days: [Int: Int] = [:]
            for (k, v) in dict(d["dayBudgets"]) { if let i = Int(k), let n = num(v) { days[i] = Int(n) } }
            let out = Adaptive.spread(step, budget: Int(pos(d["budget"]) ?? 1600), days: days, treat: num(op["treat"]).map { Int($0) })
            d["budget"] = out.budget
            d["dayBudgets"] = Dictionary(uniqueKeysWithValues: out.days.map { (String($0.key), $0.value as Any) }) as JSON
            if plan != nil {
                plan?["kcal"] = Int(((num(op["now"]) ?? 0) + step).rounded())
                if var macros = plan?["macros"] as? JSON, let c = num(macros["c"]) {
                    macros["c"] = max(0, Int(c) + Int((step / 4).rounded())); plan?["macros"] = macros
                    var goals = dict(d["goals"]); if goals["c"] != nil && !(goals["c"] is NSNull) { goals["c"] = macros["c"]; d["goals"] = goals }
                }
            }
        } else if (op["use"] as? Bool) == true, let suggest = pos(op["suggest"]), let now = pos(op["now"]) {
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
