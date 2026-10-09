import ActivityKit
import Foundation
import UserNotifications

/// The gym session on the lock screen and in the Dynamic Island (a Live Activity), plus a
/// "rest's over" notification, which still arrives when the phone is locked and the page is asleep.
final class WorkoutTimer {
    static let shared = WorkoutTimer()
    private var activity: Activity<WorkoutActivityAttributes>?
    private let restAlertID = "rest-over"

    /// From the page: { type: "session", name, startedAt (ms), restEnds (ms or null), next, setsDone }
    func update(from body: [String: Any]) {
        let name = (body["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Gym session"
        let startedMs = (body["startedAt"] as? Double) ?? Date().timeIntervalSince1970 * 1000
        let restEnds = (body["restEnds"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }.flatMap { $0 > Date() ? $0 : nil }
        let next = body["next"] as? String ?? ""
        let state = WorkoutActivityAttributes.ContentState(restEnds: restEnds, next: next, setsDone: body["setsDone"] as? Int ?? 0)

        scheduleRestAlert(at: restEnds, next: next)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        if let current = activity, current.activityState == .active {
            Task { await current.update(content) }
        } else {
            // one workout on the lock screen at a time
            for old in Activity<WorkoutActivityAttributes>.activities { Task { await old.end(nil, dismissalPolicy: .immediate) } }
            let attributes = WorkoutActivityAttributes(name: name, startedAt: Date(timeIntervalSince1970: startedMs / 1000))
            activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }
    }

    func end() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [restAlertID])
        for current in Activity<WorkoutActivityAttributes>.activities { Task { await current.end(nil, dismissalPolicy: .immediate) } }
        activity = nil
    }

    private func scheduleRestAlert(at ends: Date?, next: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restAlertID])
        guard let ends, ends.timeIntervalSinceNow > 1 else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let note = UNMutableNotificationContent()
            note.title = "Rest's over"
            note.body = next.isEmpty ? "Time for your next set" : "Next: \(next)"
            note.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, ends.timeIntervalSinceNow), repeats: false)
            center.add(UNNotificationRequest(identifier: self.restAlertID, content: note, trigger: trigger))
        }
    }
}
