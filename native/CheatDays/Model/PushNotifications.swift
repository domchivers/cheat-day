import UIKit
import UserNotifications

/// Lock-screen notifications from friends (reactions, comments, food sent, friend requests): the app registers with
/// Apple's push service and hands its device token to the server's push function, which sends through APNs.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Push.upload(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    // shown even while the app is open
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { Task { await FriendActivity.shared.load() } }
        return [.banner, .sound]
    }

    // tapping one: food sent goes to Today (it's waiting there), anything else to Friends
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let kind = response.notification.request.content.userInfo["kind"] as? String ?? ""
        await MainActor.run {
            NotificationCenter.default.post(name: .openTab, object: kind.contains("send") ? 0 : 2)
        }
    }
}

extension Notification.Name {
    static let openTab = Notification.Name("cheatDaysOpenTab")
}

@MainActor
enum Push {
    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "push.social") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "push.social") }
    }

    /// Ask (once, from the system) and register; quietly does nothing if notifications are off.
    static func start() async {
        guard on, Supabase.shared.session != nil else { return }
        let c = UNUserNotificationCenter.current()
        let s = await c.notificationSettings()
        if s.authorizationStatus == .notDetermined { _ = try? await c.requestAuthorization(options: [.alert, .badge, .sound]) }
        let now = await c.notificationSettings()
        guard now.authorizationStatus == .authorized || now.authorizationStatus == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func upload(_ token: String) async {
        UserDefaults.standard.set(token, forKey: "push.token")
        // the app's own reminders are local, so only friends' news comes from the server
        let body: JSON = ["action": "subscribe", "tz": TimeZone.current.identifier,
                          "subscription": ["endpoint": "apns:\(token)", "keys": ["p256dh": "apns", "auth": "apns"] as JSON] as JSON,
                          "prefs": ["lunch": false, "social": on] as JSON]
        _ = try? await Supabase.shared.call("/functions/v1/push", body: body)
    }

    static func setOn(_ value: Bool) async {
        on = value
        if let token = UserDefaults.standard.string(forKey: "push.token") {
            if value { await upload(token) }
            else { _ = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "unsubscribe", "endpoint": "apns:\(token)"]) }
        } else if value { await start() }
    }
}
