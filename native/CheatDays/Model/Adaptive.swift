import Foundation

/// The weekly check-in's maths, kept apart from the record so it can be tested on real numbers: the weight rate from
/// the right weigh-ins, whether it's off the goal for long enough to act on, and how a change spreads over the week.
/// From the owner's adaptive check-in spec (design/adaptive-calorie-checkin.md).
enum Adaptive {
    static let kcalPerKg = 7700.0
    static let maxStep = 150.0, deadZone = 75.0, swingKg = 0.8

    struct Reading: Equatable { let day: String; let kg: Double; var usual = true }

    /// The weight rate and how it was got: which readings counted, which were left out, and whether the latest
    /// one sits so far off the earlier trend that it's likely water.
    struct Rate {
        let perWeek: Double
        let used: [Reading]
        let left: [Reading]         // on the chart but not counted: another day, or marked as not usual
        let method: String          // "last 5 Saturdays", "last 4 weeks"
        var swing: Double? = nil    // kg the latest reading sits off the earlier trend, when it's over 0.8
        var perDay: Double { perWeek / 7 }
    }

    /// Least squares through the readings, x in days from the first.
    static func line(_ pts: [Reading]) -> (slope: Double, intercept: Double)? {
        guard pts.count >= 2, let first = pts.first else { return nil }
        let t0 = DayKey.date(first.day).timeIntervalSince1970 / 86400
        let xs = pts.map { DayKey.date($0.day).timeIntervalSince1970 / 86400 - t0 }, ys = pts.map(\.kg)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let den = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        guard den > 0 else { return nil }
        let slope = xs.indices.reduce(0) { $0 + (xs[$1] - mx) * (ys[$1] - my) } / den
        return (slope, my - slope * mx)
    }

    /// With a weigh-in day: the latest 6 usual readings on it. Without one: every usual reading in the last 4 weeks
    /// (6 when there aren't 4), unusual-looking ones dropped. Needs 3 readings over 2 weeks or more.
    static func rate(_ all: [Reading], weighDay: Int?, end: String) -> Rate? {
        let rows = all.filter { $0.day <= end && $0.day >= DayKey.shift(end, days: -70) }.sorted { $0.day < $1.day }
        var used: [Reading], method: String
        if let wd = weighDay {
            used = Array(rows.filter { $0.usual && DayKey.weekday($0.day) == wd }.suffix(6))
            method = "last \(used.count) \(Calendar.current.weekdaySymbols[wd])s"
        } else {
            let usual = rows.filter(\.usual)
            let odd = usual.count >= 4 ? Trend.fit(days: usual.map(\.day), values: usual.map(\.kg)).odd : Array(repeating: false, count: usual.count)
            let kept = usual.indices.filter { !odd[$0] }.map { usual[$0] }
            let four = kept.filter { $0.day >= DayKey.shift(end, days: -28) }
            used = four.count >= 4 ? four : kept.filter { $0.day >= DayKey.shift(end, days: -42) }
            method = four.count >= 4 ? "last 4 weeks" : "last 6 weeks"
        }
        guard used.count >= 3, let first = used.first, let last = used.last,
              DayKey.date(last.day).timeIntervalSince(DayKey.date(first.day)) >= 14 * 86400 - 3600,
              let fit = line(used) else { return nil }
        let left = rows.filter { r in r.day >= first.day && !used.contains(r) }
        var rate = Rate(perWeek: fit.slope * 7, used: used, left: left, method: method)
        // the latest reading against the line through the ones before it
        if used.count >= 4, let before = line(Array(used.dropLast())) {
            let x = (DayKey.date(last.day).timeIntervalSince1970 - DayKey.date(first.day).timeIntervalSince1970) / 86400
            let off = last.kg - (before.intercept + before.slope * x)
            if abs(off) > swingKg { rate.swing = off }
        }
        return rate
    }

    /// The weekday they usually weigh on: 70% or more of the days with a usual weigh-in over the last 8 weeks (at least 4),
    /// so a Saturday weigher's midweek readings stay off the line without them finding the setting. Nil for daily weighers.
    static func usualDay(_ all: [Reading], end: String) -> Int? {
        let days = Set(all.filter { $0.usual && $0.day <= end && $0.day > DayKey.shift(end, days: -56) }.map(\.day))
        guard days.count >= 4 else { return nil }
        let counts = Dictionary(grouping: days, by: DayKey.weekday).mapValues(\.count)
        guard let best = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }), Double(best.value) >= Double(days.count) * 0.7 else { return nil }
        return best.key
    }

    /// How far from the goal still counts as on it, in kg a week: 0.15% of body weight losing, 0.1% holding or gaining.
    static func tolerance(want: Double, kg: Double) -> Double { kg * (want < 0 ? 0.0015 : 0.001) }

    static func off(_ pace: Double, want: Double, tol: Double) -> Bool { abs(pace - want) > tol }

    /// So far off that one week is enough: twice the goal (losing 0.9 on a 0.45 goal), or going the wrong way.
    static func farOff(_ pace: Double, want: Double, tol: Double) -> Bool { abs(pace - want) >= max(abs(want), 2 * tol) }

    /// The change to the daily average budget: nothing under 75, never more than 150 at once.
    static func step(target: Double, now: Double) -> Double? {
        let d = target - now
        guard abs(d) >= deadZone else { return nil }
        return min(maxStep, max(-maxStep, d))
    }

    /// A daily change as the week's budgets: the week's total spread over every day but the treat day, rounded to 25.
    static func spread(_ change: Double, budget: Int, days: [Int: Int], treat: Int?) -> (budget: Int, days: [Int: Int]) {
        let n = treat == nil ? 7.0 : 6.0
        let per = Int((change * 7 / n / 25).rounded() * 25)
        var out: [Int: Int] = [:]
        for (d, v) in days where d != treat { out[d] = v + per }
        if let t = treat { out[t] = days[t] ?? budget }   // the treat day keeps what it had, even when it was the everyday budget
        return (budget + per, out)
    }
}

extension Store {
    /// What they picked: a weekday (0 Sunday … 6 Saturday), -1 for any day, or nil to let the app work it out.
    var weighDaySetting: Int? { num(dict(doc["prefs"])["weighDay"]).map { Int($0) } }
    /// The day of the week whose weigh-ins count, or nil when any day's do: their pick, or the day they usually weigh.
    var weighDay: Int? {
        if let s = weighDaySetting { return s < 0 ? nil : s }
        return Adaptive.usualDay(weighReadings, end: today)
    }
    func setWeighDay(_ d: Int?) { perform(["type": "weighDay", "day": d.map { $0 as Any } ?? NSNull()]) }

    var weighReadings: [Adaptive.Reading] {
        bodyRows.compactMap { r in pos(r["weight"]).map { Adaptive.Reading(day: str(r["day"]), kg: $0, usual: (r["usual"] as? Bool) != false) } }
    }

    func weightRate(asOf end: String? = nil) -> Adaptive.Rate? {
        Adaptive.rate(weighReadings, weighDay: weighDay, end: end ?? DayKey.string(Date()))
    }

    /// Whether a weigh-in was taken the usual way, and what was different when it wasn't. Kept in the record only:
    /// the scale table has no column for it.
    func markWeighIn(_ day: String, usual: Bool, why: [String] = []) {
        perform(["type": "body", "row": ["day": day, "usual": usual, "why": why] as JSON])
    }

    /// The weigh-in-day reading still waiting for a yes or no: one Apple Health brought in today or yesterday.
    var weighInToConfirm: (day: String, kg: Double, at: Date?)? {
        guard let wd = weighDay, let r = bodyRows.last(where: { pos($0["weight"]) != nil && str($0["day"]) <= today }),
              DayKey.weekday(str(r["day"])) == wd, str(r["day"]) >= DayKey.shift(today, days: -1),
              r["usual"] == nil || r["usual"] is NSNull, str(r["from"]) == "health" else { return nil }
        return (str(r["day"]), pos(r["weight"]) ?? 0, ISO.date(str(r["takenAt"])))
    }

    static func applyWeighDayOp(_ op: JSON, to d: inout JSON) {
        guard str(op["type"]) == "weighDay" else { return }
        var prefs = dict(d["prefs"])
        prefs["weighDay"] = op["day"] ?? NSNull()
        d["prefs"] = prefs
    }
}
