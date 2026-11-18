import Foundation

/// Body fat alongside weight: on a cut, 80 kg can be 14.5% or 13% depending on what's been lost. Scales measure body
/// fat noisily (±2–3%), so it's averaged over the last few readings; fat and lean mass follow from the trend weight.
extension Store {
    /// The averaged body fat % from the last few readings (up to six weeks back), and how many went into it.
    var fatTrend: (pct: Double, n: Int)? {
        let since = DayKey.shift(DayKey.string(Date()), days: -42)
        let readings = bodyRows.filter { str($0["day"]) >= since }.compactMap { pos($0["fat"]) }.filter { $0 > 2 && $0 < 60 }
        guard readings.count >= 2 else { return nil }
        let last = readings.suffix(4)
        return ((last.reduce(0, +) / Double(last.count) * 10).rounded() / 10, last.count)
    }

    var goalFat: Double? { pos(doc["goalFat"]) }

    /// When the trend reaches a weight at the 4-week pace, worked out one way for Me and Body alike (they'd disagreed:
    /// one from the latest reading, the other from the trend). Nil when the trend isn't heading there.
    func reachDate(_ target: Double) -> Date? {
        guard let now = trendWeight ?? latestWeight?.kg, let t = weightTrend() else { return nil }
        let left = target - now, perWeek = t.perDay * 7
        guard abs(left) >= 0.3, perWeek != 0, (perWeek < 0) == (left < 0) else { return nil }
        let days = Int(abs(left / perWeek) * 7)
        return days < 1500 ? Calendar.current.date(byAdding: .day, value: days, to: Date()) : nil
    }

    /// The trend's within 0.3 kg of a weight: too close for reachDate to give a date, so "any day now".
    func nearGoal(_ target: Double) -> Bool {
        guard let now = trendWeight ?? latestWeight?.kg else { return false }
        return abs(target - now) < 0.3
    }

    /// Where a body-fat goal lands: the weight it means and how much of the change is fat. Some lean mass goes too
    /// on a cut, so a fifth of what's lost is counted as lean, not all fat.
    static func fatGoal(weight w: Double, fatPct: Double, target: Double, leanShare: Double = 0.2) -> (weight: Double, fat: Double, lean: Double) {
        let fat = w * fatPct / 100, t = target / 100
        let delta = (fat - t * w) / ((1 - leanShare) - t)   // kg to lose (negative: to gain)
        let w2 = w - delta
        return ((w2 * 10).rounded() / 10, w2 * t, w2 * (1 - t))
    }

    /// The other way: the body fat % a goal weight means, counting the same fifth of the change as lean.
    static func fatAt(weight w: Double, fatPct: Double, goal w2: Double, leanShare: Double = 0.2) -> Double {
        guard w2 > 0 else { return fatPct }
        let fat = w * fatPct / 100, delta = w - w2
        return max(0, (fat - (1 - leanShare) * delta) / w2 * 100)
    }

    /// One goal, two ways to say it (18 Nov). They were kept apart, so a weight goal and a body-fat goal could each
    /// say something different. The goal weight is the goal; the body-fat goal is shown as what it means, and setting
    /// one sets the goal weight it comes to, to a tenth of a kilo so the % reads back as typed.
    func setGoalFat(_ pct: Double, now: Double) {
        guard let bf = fatTrend, now > 0 else { return }
        let w2 = Store.fatGoal(weight: now, fatPct: bf.pct, target: pct).weight
        perform(["type": "set", "key": "goalWeight", "value": w2], syncAfter: 2)
        perform(["type": "set", "key": "goalFat", "value": pct], syncAfter: 2)
        if dict(doc["goalStart"]).isEmpty, let w = latestWeight?.kg { perform(["type": "set", "key": "goalStart", "value": ["weight": w, "day": today] as JSON], syncAfter: 2) }
    }
    /// The body fat % the goal weight comes to now, if there's a goal weight and enough body-fat readings.
    func goalFatShown(now: Double) -> Double? {
        guard let bf = fatTrend, let w2 = pos(doc["goalWeight"]), now > 0 else { return nil }
        return (Store.fatAt(weight: now, fatPct: bf.pct, goal: w2) * 10).rounded() / 10
    }
}
