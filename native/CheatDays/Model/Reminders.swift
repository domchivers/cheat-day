import Foundation
import UserNotifications

/// Reminders scheduled on the phone itself: a nudge at 2pm if nothing's logged, and the weigh-in reminder
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
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("lunch-") || $0.hasPrefix("weigh-") })
        let prefs = store.reminderPrefs
        guard prefs.lunch || prefs.weigh != nil else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let cal = Calendar.current, todayKey = DayKey.string(Date())
        let loggedToday = !store.todayItems.isEmpty
        let weighedToday = store.latestWeight?.day == todayKey
        for offset in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: Date()) else { continue }
            let key = DayKey.string(day)
            if prefs.lunch, offset < 7, !(offset == 0 && loggedToday) {
                add(center, id: "lunch-\(key)", day: day, hour: 14, minute: 0, title: "Nothing logged yet today", body: "Take a moment to add what you've had so far.")
            }
            if let w = prefs.weigh, store.weighDays.contains(cal.component(.weekday, from: day) - 1), !(offset == 0 && weighedToday) {
                let parts = w.split(separator: ":").compactMap { Int($0) }
                add(center, id: "weigh-\(key)", day: day, hour: parts.first ?? 7, minute: parts.count > 1 ? parts[1] : 30,
                    title: "Weigh-in day", body: "Step on the scale before breakfast and log it in Cheat Days.")
            }
        }
    }

    private static func add(_ center: UNUserNotificationCenter, id: String, day: Date, hour: Int, minute: Int, title: String, body: String) {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        c.hour = hour; c.minute = minute
        guard let when = Calendar.current.date(from: c), when > Date() else { return }
        let note = UNMutableNotificationContent()
        note.title = title; note.body = body; note.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: note, trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: false)))
    }
}
