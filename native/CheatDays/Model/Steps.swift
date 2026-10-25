import HealthKit
import SwiftUI

/// Today's steps from Apple Health (the iPhone counts them, and a watch adds to it). Shown on Today; nothing is added
/// to your budget, so workouts aren't counted twice.
@MainActor @Observable
final class Steps {
    static let shared = Steps()
    private(set) var today: Int?
    private var health: HKHealthStore { HealthSync.health }
    private let type = HKQuantityType(.stepCount)

    /// Asks once (alongside the scale permission, or on first use), then reads today's total.
    func refresh() async {
        guard HealthSync.available else { return }
        if !UserDefaults.standard.bool(forKey: "health.stepsAsked") {
            guard HealthSync.on else { return }   // only once Health is in use; the scale row asks for both
            await ask()
        }
        let start = Calendar.current.startOfDay(for: Date())
        let pred = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let n: Int? = await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: pred, options: .cumulativeSum) { _, s, _ in
                cont.resume(returning: s?.sumQuantity().map { Int($0.doubleValue(for: .count())) })
            }
            health.execute(q)
        }
        today = (n ?? 0) > 0 ? n : nil   // nothing (or not allowed): don't show a zero
    }

    func ask() async {
        _ = try? await health.requestAuthorization(toShare: [], read: [type])
        UserDefaults.standard.set(true, forKey: "health.stepsAsked")
    }
}
