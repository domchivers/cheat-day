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
    static var lastPull: Date? {
        // once: read the whole history again, so earlier imports get the scale's exact numbers and their times
        if UserDefaults.standard.integer(forKey: "health.version") < 2 {
            UserDefaults.standard.removeObject(forKey: "health.lastPull")
            UserDefaults.standard.set(2, forKey: "health.version")
        }
        return UserDefaults.standard.object(forKey: "health.lastPull") as? Date
    }

    /// Health's measure, the record's key, its unit, and what to multiply by (Health keeps body fat as 0.18 for 18%).
    private static let kinds: [(HKQuantityTypeIdentifier, String, HKUnit, Double)] = [
        (.bodyMass, "weight", .gramUnit(with: .kilo), 1),
        (.bodyFatPercentage, "fat", .percent(), 100),
        (.leanBodyMass, "lean", .gramUnit(with: .kilo), 1),
        (.bodyMassIndex, "bmi", .count(), 1)
    ]

    /// Ask once for permission to read, then bring readings in. Returns how many days came in.
    static func connect() async throws -> Int {
        try await authorize()
        on = true
        return await pull(force: true)
    }

    /// Weigh-ins before this aren't brought in ("start fresh"); nil brings in the history.
    static var from: Date? {
        get { UserDefaults.standard.object(forKey: "health.from") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "health.from") }
    }

    /// Just the permission, so setup can ask about the history before anything comes in.
    static func authorize() async throws {
        guard available else { throw APIError(status: 0, message: "Apple Health isn't available on this device.") }
        let types = Set(kinds.compactMap { HKObjectType.quantityType(forIdentifier: $0.0) as HKObjectType? })
        try await health.requestAuthorization(toShare: [], read: types.union([HKQuantityType(.stepCount)]))
        UserDefaults.standard.set(true, forKey: "health.stepsAsked")
    }

    /// How many weigh-ins Health has from the last 400 days, the earliest, and the latest (for setup to show).
    static func history() async -> (count: Int, first: Date?, latest: HKQuantitySample?) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return (0, nil, nil) }
        let s = await samples(type, since: Calendar.current.date(byAdding: .day, value: -400, to: Date())!).sorted { $0.endDate < $1.endDate }
        return (s.count, s.first?.endDate, s.last)
    }

    /// Setup's answer: bring in the history, or only weigh-ins from today on.
    static func start(history: Bool) async -> Int {
        from = history ? nil : Calendar.current.startOfDay(for: Date())
        UserDefaults.standard.removeObject(forKey: "health.lastPull")
        on = true
        return await pull(force: true)
    }

    static func disconnect() { on = false; UserDefaults.standard.removeObject(forKey: "health.lastPull") }

    /// New readings since last time (the first time, the last 400 days). Safe to call often.
    @discardableResult
    static func pull(force: Bool = false) async -> Int {
        guard on, available else { return 0 }
        if !force, let last = lastPull, Date().timeIntervalSince(last) < 120 { return 0 }
        var since = lastPull.map { $0.addingTimeInterval(-3 * 86400) } ?? Calendar.current.date(byAdding: .day, value: -400, to: Date())!
        if let from, from > since { since = from }   // started fresh: nothing from before then
        var byDay: [String: JSON] = [:]
        for k in kinds {
            guard let type = HKQuantityType.quantityType(forIdentifier: k.0) else { continue }
            for s in await samples(type, since: since).sorted(by: { $0.endDate < $1.endDate }) {
                let day = DayKey.string(s.endDate)
                var row = byDay[day] ?? ["day": day]
                row[k.1] = Fmt.kg2(s.quantity.doubleValue(for: k.2) * k.3)   // the day's latest wins
                let at = ISO8601DateFormatter().string(from: s.endDate)
                if str(row["updatedAt"]) < at { row["updatedAt"] = at; row["takenAt"] = at }   // the time the scale took it
                row["from"] = "health"
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
            guard shouldImport(row, over: mine[day]) else { continue }
            store.saveBody(row)
            n += 1
        }
        return n
    }

    /// Whether a day's reading from Health goes in. Not when the record already has exactly these numbers
    /// (and the time), and not over a reading typed or read from a screenshot after the scale's: the newest wins.
    nonisolated static func shouldImport(_ row: JSON, over have: JSON?) -> Bool {
        guard let have else { return true }
        if str(have["from"]) != "health", let mineAt = ISO.date(str(have["updatedAt"])), let scaleAt = ISO.date(str(row["takenAt"])), mineAt > scaleAt { return false }
        let same = ["weight", "fat", "lean", "bmi"].allSatisfy { k in
            guard let v = num(row[k]) else { return true }
            return num(have[k]).map { abs($0 - v) < 0.005 } ?? false
        }
        return !(same && !str(have["takenAt"]).isEmpty)
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

/// Planned runs, classes and matches ticked off from Apple Health (25 Nov, design/plan-any-workout-mockup.html): a
/// workout a watch or app saved there, of a kind the plan has on that day this week, is logged as that activity, so
/// the plan card ticks it and the day counts it. Only those: other Health workouts aren't brought in.
extension HealthSync {
    static var workoutsAsked: Bool { UserDefaults.standard.bool(forKey: "health.workoutsAsked") }

    /// Ask to read workouts (Health shows its sheet only the first time). Once a plan has something other than weights.
    static func askWorkouts() async {
        guard available else { return }
        try? await health.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()])
        UserDefaults.standard.set(true, forKey: "health.workoutsAsked")
    }

    /// Whether a plan activity can be ticked from Health (one of their own, "Other", can't be told apart).
    static func ticks(_ type: String) -> Bool { type != "Other" }

    /// The plan's kind of activity for a Health workout, or nil for one the plan doesn't have a kind for.
    static func planType(_ t: HKWorkoutActivityType) -> String? {
        switch t {
        case .running: return "Run"
        case .cycling, .handCycling: return "Cycle"
        case .swimming: return "Swim"
        case .yoga, .pilates, .flexibility, .mindAndBody: return "Yoga / stretch"
        case .highIntensityIntervalTraining, .crossTraining, .mixedCardio, .boxing, .kickboxing, .martialArts: return "HIIT"
        case .soccer, .basketball, .rugby, .hockey, .volleyball, .australianFootball, .cricket, .handball, .lacrosse, .baseball, .softball, .americanFootball:
            return "Team sport"
        case .tennis, .badminton, .squash, .tableTennis, .racquetball, .pickleball: return "Tennis / padel"
        case .climbing: return "Climbing"
        case .socialDance, .cardioDance: return "Dance"
        case .hiking: return "Hike"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        default: return nil
        }
    }

    /// This week's Health workouts that match the plan, logged once each. Returns how many came in.
    @discardableResult
    static func tickPlan() async -> Int {
        let store = Store.shared
        guard available, workoutsAsked, let plan = store.workoutPlan, !plan.activities.isEmpty else { return 0 }
        let since: Date = Calendar.current.startOfDay(for: DayKey.date(WorkoutPlan.monday(store.today)))
        let found: [HKWorkout] = await withCheckedContinuation { (cont: CheckedContinuation<[HKWorkout], Never>) in
            let pred = HKQuery.predicateForSamples(withStart: since, end: Date(), options: .strictStartDate)
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            health.execute(q)
        }
        var seen = Set(UserDefaults.standard.stringArray(forKey: "health.ticked") ?? [])
        var added = 0
        for w in found.sorted(by: { $0.startDate < $1.startDate }) {
            let key: String = w.uuid.uuidString
            guard !seen.contains(key), let type = planType(w.workoutActivityType) else { continue }
            let day: String = DayKey.string(w.startDate)
            guard day <= store.today, let a = plan.activities(on: day).first(where: { $0.type == type }) else { continue }
            seen.insert(key)
            // logged by hand already: that's the one that counts
            if store.workouts(on: day).contains(where: { str($0["type"]) == type }) { continue }
            let km: Double? = w.totalDistance.map { $0.doubleValue(for: .meterUnit(with: .kilo)) }
            store.logFromHealth(type: type, name: a.name, minutes: w.duration / 60, effort: a.effort, date: day, km: km, id: "health-" + key)
            // its map, if the watch kept the route (on the phone only, as the app's own runs)
            let pts: [RoutePoint] = await route(for: w)
            if pts.count > 1 { RouteStore.save(pts, id: "health-" + key) }
            added += 1
        }
        UserDefaults.standard.set(Array(seen), forKey: "health.ticked")
        return added
    }
}
