import HealthKit
import UIKit

/// Smart scales, any brand: their apps (VeSync, Withings, Eufy, Renpho, Fitbit, Garmin, Zepp…) save weigh-ins to
/// Apple Health, and Cheat Days reads them from there. Weight, body fat, lean mass and BMI come into Body, one row
/// a day (the latest reading that day), and up to the account like any other weigh-in.
@MainActor
enum HealthSync {
    static let health = HKHealthStore()
    static var available: Bool { HKHealthStore.isHealthDataAvailable() }
    static var on: Bool {
        get { UserDefaults.standard.bool(forKey: "health.on") }
        set { UserDefaults.standard.set(newValue, forKey: "health.on") }
    }
    static var lastPull: Date? { UserDefaults.standard.object(forKey: "health.lastPull") as? Date }

    /// Health's measure, the record's key, its unit, and what to multiply by (Health keeps body fat as 0.18 for 18%).
    private static let kinds: [(HKQuantityTypeIdentifier, String, HKUnit, Double)] = [
        (.bodyMass, "weight", .gramUnit(with: .kilo), 1),
        (.bodyFatPercentage, "fat", .percent(), 100),
        (.leanBodyMass, "lean", .gramUnit(with: .kilo), 1),
        (.bodyMassIndex, "bmi", .count(), 1)
    ]

    /// Ask once for permission to read, then bring readings in. Returns how many days came in.
    static func connect() async throws -> Int {
        guard available else { throw APIError(status: 0, message: "Apple Health isn't available on this device.") }
        let types = Set(kinds.compactMap { HKObjectType.quantityType(forIdentifier: $0.0) as HKObjectType? })
        try await health.requestAuthorization(toShare: [], read: types)
        on = true
        return await pull(force: true)
    }

    static func disconnect() { on = false; UserDefaults.standard.removeObject(forKey: "health.lastPull") }

    /// New readings since last time (the first time, the last 400 days). Safe to call often.
    @discardableResult
    static func pull(force: Bool = false) async -> Int {
        guard on, available else { return 0 }
        if !force, let last = lastPull, Date().timeIntervalSince(last) < 120 { return 0 }
        let since = lastPull.map { $0.addingTimeInterval(-3 * 86400) } ?? Calendar.current.date(byAdding: .day, value: -400, to: Date())!
        var byDay: [String: JSON] = [:]
        for k in kinds {
            guard let type = HKQuantityType.quantityType(forIdentifier: k.0) else { continue }
            for s in await samples(type, since: since).sorted(by: { $0.endDate < $1.endDate }) {
                let day = DayKey.string(s.endDate)
                var row = byDay[day] ?? ["day": day]
                row[k.1] = (s.quantity.doubleValue(for: k.2) * k.3 * 10).rounded() / 10   // the day's latest wins
                let at = ISO8601DateFormatter().string(from: s.endDate)
                if str(row["updatedAt"]) < at { row["updatedAt"] = at }
                byDay[day] = row
            }
        }
        UserDefaults.standard.set(Date(), forKey: "health.lastPull")
        let store = Store.shared
        let mine = Dictionary(store.bodyRows.map { (str($0["day"]), $0) }, uniquingKeysWith: { a, _ in a })
        var n = 0
        for day in byDay.keys.sorted() {
            guard let row = byDay[day] else { continue }
            // nothing new: the record already has these numbers for that day
            if let have = mine[day], kinds.allSatisfy({ k in
                guard let v = num(row[k.1]) else { return true }
                return num(have[k.1]).map { abs($0 - v) < 0.05 } ?? false
            }) { continue }
            store.saveBody(row)
            n += 1
        }
        return n
    }

    private static func samples(_ type: HKQuantityType, since: Date) async -> [HKQuantitySample] {
        await withCheckedContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: since, end: Date(), options: .strictStartDate)
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKQuantitySample]) ?? [])
            }
            health.execute(q)
        }
    }
}
