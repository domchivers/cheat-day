import HealthKit
import Foundation

/// What you eat, saved to Apple Health (25 Nov, design/health-food-mockup.html): each meal of a day as one entry of
/// calories, protein, carbs and fat, so a watch and other apps see it. Off until it's turned on in Settings › Your data.
/// Each entry has a sync identifier for its day, meal and measure: a changed meal saves a newer version over it, and an
/// emptied one is deleted. What was last sent is remembered, so only meals that changed are written.
extension HealthSync {
    static var foodOn: Bool {
        get { UserDefaults.standard.bool(forKey: "health.food") && mine }
        set { UserDefaults.standard.set(newValue, forKey: "health.food"); if newValue { claim() } }
    }

    /// Health's measure and its unit, and the meal's number for it.
    private static let foodKinds: [(id: HKQuantityTypeIdentifier, unit: HKUnit, value: (FoodMeal) -> Double)] = [
        (.dietaryEnergyConsumed, .kilocalorie(), { $0.kcal }),
        (.dietaryProtein, .gram(), { $0.p }),
        (.dietaryCarbohydrates, .gram(), { $0.c }),
        (.dietaryFatTotal, .gram(), { $0.f })
    ]

    /// A meal's totals for Health, and when it was eaten.
    struct FoodMeal: Equatable {
        var meal: String
        var kcal: Double, p: Double, c: Double, f: Double
        var at: Date
        /// What's compared with what was sent last time (whole numbers: a rounding wobble isn't a change).
        var sig: String { [kcal, p, c, f].map { String(Int($0.rounded())) }.joined(separator: ",") }
    }

    /// Ask to save food (Health shows its sheet only the first time), then send the last two weeks. Whether it's on.
    static func startFood() async -> Bool {
        guard available else { return false }
        let types: Set<HKSampleType> = Set(foodKinds.map { (k) -> HKSampleType in HKQuantityType(k.id) })
        do { try await health.requestAuthorization(toShare: types, read: []) } catch { return false }
        let ok: Bool = health.authorizationStatus(for: HKQuantityType(.dietaryEnergyConsumed)) == .sharingAuthorized
        foodOn = ok
        if ok {
            UserDefaults.standard.removeObject(forKey: "health.foodSent")
            await sendFood(days: 14)
        }
        return ok
    }

    /// Off: nothing more is sent. What's already in Health stays there (theirs to delete in Health).
    static func stopFood() {
        foodOn = false
        UserDefaults.standard.removeObject(forKey: "health.foodSent")
    }

    private static var foodWait: Task<Void, Never>?
    private static var sending = false, again = false

    /// The record changed: a moment after the last change, the past week's meals that changed go to Health.
    static func foodChanged() {
        guard foodOn, available else { return }
        foodWait?.cancel()
        foodWait = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            await sendFood(days: 7)
        }
    }

    /// Today and the days before it, each meal that's changed since it was last sent.
    static func sendFood(days: Int) async {
        // not before the record has come down: an emptied one (just switched accounts) would delete the meals from Health
        guard foodOn, available, Store.shared.lastSynced != nil else { return }
        if sending { again = true; return }
        sending = true
        defer { sending = false }
        repeat {
            again = false
            let store = Store.shared
            var sent: [String: String] = (UserDefaults.standard.dictionary(forKey: "health.foodSent") as? [String: String]) ?? [:]
            for i in 0..<days {
                let day: String = DayKey.shift(store.today, days: -i)
                let items: [JSON] = store.pastDay(day)?.items ?? []
                let meals: [FoodMeal] = Self.foodMeals(items, day: day, now: Date())
                for name in Self.foodMealNames {
                    let key: String = day + "|" + name
                    let m: FoodMeal? = meals.first { $0.meal == name }
                    let sig: String = m?.sig ?? ""
                    if sig == (sent[key] ?? "") { continue }
                    if await write(m, day: day, meal: name) { sent[key] = sig.isEmpty ? nil : sig }
                }
            }
            UserDefaults.standard.set(sent, forKey: "health.foodSent")
        } while again
    }

    /// One meal's entries: saved as a newer version, or deleted when the meal is empty (or a measure is 0).
    private static func write(_ m: FoodMeal?, day: String, meal: String) async -> Bool {
        let version: Int = Int(Date().timeIntervalSince1970)
        var save: [HKObject] = []
        var gone: [(HKQuantityType, String)] = []
        for k in foodKinds {
            let type = HKQuantityType(k.id)
            let id: String = "cheatdays.food.\(day).\(meal).\(k.id.rawValue)"
            if let m, k.value(m) > 0.5 {
                let meta: [String: Any] = [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: version, HKMetadataKeyFoodType: meal]
                save.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: k.unit, doubleValue: k.value(m)), start: m.at, end: m.at, metadata: meta))
            } else {
                gone.append((type, id))
            }
        }
        var ok = true
        for (type, id) in gone {
            let pred = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [id])
            let done: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                health.deleteObjects(of: type, predicate: pred) { success, _, _ in cont.resume(returning: success) }
            }
            ok = ok && done
        }
        if !save.isEmpty {
            let done: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                health.save(save) { success, _ in cont.resume(returning: success) }
            }
            ok = ok && done
        }
        return ok
    }

    /// The meals Health gets, and "Other" for a food with none.
    nonisolated static let foodMealNames: [String] = ["Breakfast", "Lunch", "Dinner", "Snacks", "Other"]

    /// A day's foods as Health's meals: totals, and when (the last one added that day, or the meal's usual time),
    /// never later than now. Meals with no calories are left out.
    nonisolated static func foodMeals(_ items: [JSON], day: String, now: Date) -> [FoodMeal] {
        let start: Date = DayKey.date(day)
        let usual: [String: Double] = ["Breakfast": 8, "Lunch": 12.5, "Dinner": 18.5, "Snacks": 15, "Other": 12]
        var out: [FoodMeal] = []
        for name in foodMealNames {
            let mine: [JSON] = items.filter { (it: JSON) -> Bool in
                let m: String = str(it["meal"])
                return name == "Other" ? !["Breakfast", "Lunch", "Dinner", "Snacks"].contains(m) : m == name
            }
            var meal = FoodMeal(meal: name, kcal: 0, p: 0, c: 0, f: 0, at: start.addingTimeInterval((usual[name] ?? 12) * 3600))
            var latest: Date?
            for it in mine {
                let k: Double = num(it["kcal"]) ?? 0
                meal.kcal += k
                if let x = FoodMath.macros(it, kcal: k) { meal.p += x.p; meal.c += x.c; meal.f += x.f }
                if let a = ISO.date(str(it["addedAt"])), DayKey.string(a) == day, latest.map({ a > $0 }) ?? true { latest = a }
            }
            if let latest { meal.at = latest }
            if meal.at > now { meal.at = max(start, now) }
            if meal.kcal >= 0.5 { out.append(meal) }
        }
        return out
    }
}
