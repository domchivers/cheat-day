import HealthKit
import SwiftUI

/// Steps from Apple Health (the iPhone counts them, and a watch adds to it): today's on Today, and the week's as a
/// walking burn on Workouts. Nothing is added to your budget: the activity level you chose already allows for
/// everyday walking, so counting it again would let you eat more than you burn.
@MainActor @Observable
final class Steps {
    static let shared = Steps()
    private(set) var today: Int?
    /// The last seven days' steps by day ("2026-10-30": 8240), today included.
    private(set) var byDay: [String: Int] = [:]
    private var health: HKHealthStore { HealthSync.health }
    private let type = HKQuantityType(.stepCount)

    /// What walking burns on top of resting: about 0.4 kcal a step for every 1,000 kg of you (260 for 8,000 steps
    /// at 80 kg), the usual net figure for walking pace.
    static func kcal(steps: Int, kg: Double) -> Double { (Double(steps) * kg * 0.0004).rounded() }

    func kcal(on date: String) -> Double {
        guard let n = byDay[date], n > 0 else { return 0 }
        return Self.kcal(steps: n, kg: Store.shared.latestWeight?.kg ?? 75)
    }

    /// For the screenshot harness: steps without asking Health.
    func preview(_ days: [String: Int]) { byDay = days; today = days[DayKey.string(Date())] }

    /// Asks once (alongside the scale permission, or on first use), then reads the week's daily totals.
    func refresh() async {
        guard HealthSync.available else { return }
        if !UserDefaults.standard.bool(forKey: "health.stepsAsked") {
            guard HealthSync.on else { return }   // only once Health is in use; the scale row asks for both
            await ask()
        }
        let cal = Calendar.current, todayStart = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -6, to: todayStart) else { return }
        let pred = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let days: [String: Int] = await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: pred, options: .cumulativeSum,
                                                anchorDate: todayStart, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, _ in
                var out: [String: Int] = [:]
                results?.enumerateStatistics(from: start, to: Date()) { s, _ in
                    if let n = s.sumQuantity()?.doubleValue(for: .count()), n > 0 { out[DayKey.string(s.startDate)] = Int(n) }
                }
                cont.resume(returning: out)
            }
            health.execute(q)
        }
        byDay = days
        today = days[DayKey.string(Date())]   // nothing (or not allowed): don't show a zero
    }

    func ask() async {
        _ = try? await health.requestAuthorization(toShare: [], read: [type])
        UserDefaults.standard.set(true, forKey: "health.stepsAsked")
    }
}
