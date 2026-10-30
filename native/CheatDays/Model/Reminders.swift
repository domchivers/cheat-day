import Foundation
import UserNotifications

/// Reminders scheduled on the phone itself: one ahead of each meal to plan it (7am, 12pm, 5pm; tapping opens the
/// planner for that meal), and the weigh-in reminder
/// on your weigh-in days. Today's is cancelled once you've logged or weighed. Settings are the website's
/// (`reminders`, `weighDays`), so they match everywhere.
extension Store {
    var reminderPrefs: (lunch: Bool, weigh: String?) {
        let r = dict(doc["reminders"])
        let weigh: String? = r.keys.contains("weigh") ? (r["weigh"] as? String) : "07:30"
        return ((r["lunch"] as? Bool) ?? true, weigh)
    }
    var weighDays: [Int] { let d = (doc["weighDays"] as? [Any])?.compactMap { num($0).map(Int.init) } ?? []; return d.isEmpty ? [0] : d }

    func setReminders(lunch: Bool, weigh: String?) {
        var r = dict(doc["reminders"]); r["lunch"] = lunch; r["weigh"] = weigh ?? NSNull()
        if r["social"] == nil { r["social"] = true }
        perform(["type": "set", "key": "reminders", "value": r], syncAfter: 1)
        Task { await Reminders.reschedule(self) }
    }
    func setWeighDays(_ days: [Int]) {
        perform(["type": "set", "key": "weighDays", "value": days.sorted()], syncAfter: 1)
        Task { await Reminders.reschedule(self) }
    }
    func setShareDay(_ on: Bool) { perform(["type": "set", "key": "shareDay", "value": on], syncAfter: 1) }
}

enum Reminders {
    static func ask() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func reschedule(_ store: Store) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("lunch-") || $0.hasPrefix("meal-") || $0.hasPrefix("weigh-") })
        let prefs = store.reminderPrefs
        guard prefs.lunch || prefs.weigh != nil else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let cal = Calendar.current, todayKey = DayKey.string(Date())
        let weighedToday = store.latestWeight?.day == todayKey
        for offset in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: Date()) else { continue }
            let key = DayKey.string(day)
            // ahead of each meal, so there's time to plan it; not for one already logged today, nor on a cheat day
            if prefs.lunch, offset < 7, !store.isCheatDay(key) {
                for m in mealTimes where !(offset == 0 && store.todayItems.contains { Meals.of($0) == m.meal }) {
                    add(center, id: "meal-\(m.meal)-\(key)", day: day, hour: m.hour, minute: 0, title: "Plan your \(m.meal.lowercased())",
                        body: m.body, info: ["kind": "plan", "meal": m.meal])
                }
            }
            if let w = prefs.weigh, store.weighDays.contains(cal.component(.weekday, from: day) - 1), !(offset == 0 && weighedToday) {
                let parts = w.split(separator: ":").compactMap { Int($0) }
                add(center, id: "weigh-\(key)", day: day, hour: parts.first ?? 7, minute: parts.count > 1 ? parts[1] : 30,
                    title: "Time to weigh in", body: store.habitFocus(on: key).map { "Step on the scale before breakfast. This week, try: \($0)" } ?? "Step on the scale before breakfast and log it in Cheat Days.")
            }
        }
    }

    /// When each meal's reminder comes: early enough to plan it.
    static let mealTimes: [(meal: String, hour: Int, body: String)] = [
        ("Breakfast", 7, "Tap for ideas from what's in, with the protein you want."),
        ("Lunch", 12, "Tap for ideas that fit what you've got left today."),
        ("Dinner", 17, "Still time to plan it: tap for ideas from what's in your cupboard.")
    ]

    private static func add(_ center: UNUserNotificationCenter, id: String, day: Date, hour: Int, minute: Int, title: String, body: String, info: [String: String] = [:]) {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        c.hour = hour; c.minute = minute
        guard let when = Calendar.current.date(from: c), when > Date() else { return }
        let note = UNMutableNotificationContent()
        note.title = title; note.body = body; note.sound = .default; note.userInfo = info
        center.add(UNNotificationRequest(identifier: id, content: note, trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: false)))
    }
}
