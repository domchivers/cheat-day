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

    /// Where a body-fat goal lands: the weight it means and how much of the change is fat. Some lean mass goes too
    /// on a cut, so a fifth of what's lost is counted as lean, not all fat.
    static func fatGoal(weight w: Double, fatPct: Double, target: Double, leanShare: Double = 0.2) -> (weight: Double, fat: Double, lean: Double) {
        let fat = w * fatPct / 100, t = target / 100
        let delta = (fat - t * w) / ((1 - leanShare) - t)   // kg to lose (negative: to gain)
        let w2 = w - delta
        return ((w2 * 10).rounded() / 10, w2 * t, w2 * (1 - t))
    }
}
