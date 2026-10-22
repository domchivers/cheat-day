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
        Task { @MainActor in await FriendActivity.shared.load() }
        return [.banner, .sound]
    }

    // tapping one: food sent goes to Today (it's waiting there), anything else to Friends
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String ?? "", post = info["post"] as? String ?? ""
        await MainActor.run {
            if kind.contains("send") { Nav.shared.today() }
            else if !post.isEmpty || kind.contains("comment") { Nav.shared.feed(post: post) }
            else { Nav.shared.people() }   // a reaction to your day
            Task { await FriendActivity.shared.load() }
        }
    }
}

extension Notification.Name {
    static let openTab = Notification.Name("cheatDaysOpenTab")
}

/// Taking you to the thing a notification or an Activity row is about: Today for food sent, Friends' People for a
/// request or a reaction to your day, the feed (scrolled to the post) for anything about a post.
@Observable @MainActor
final class Nav {
    static let shared = Nav()
    var friendsSeg = 0
    var focusPost: String?

    func today() { NotificationCenter.default.post(name: .openTab, object: 0) }
    func people() { friendsSeg = 0; NotificationCenter.default.post(name: .openTab, object: 2) }
    func feed(post: String? = nil) {
        friendsSeg = 1
        focusPost = (post?.isEmpty ?? true) ? nil : post
        NotificationCenter.default.post(name: .openTab, object: 2)
    }
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

    /// Settings' test button: registers if needed, then asks the server to send one to this phone (and your other devices).
    static func test() async -> String {
        let st = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if st == .denied { return "Notifications are off for Cheat Days. Turn them on in the iPhone's Settings → Notifications → Cheat Days." }
        if UserDefaults.standard.string(forKey: "push.token") == nil {
            await start()
            try? await Task.sleep(for: .seconds(3))   // Apple hands the token back shortly after registering
            guard UserDefaults.standard.string(forKey: "push.token") != nil else { return "This phone couldn't register for notifications yet. Check you're online and try again." }
        }
        guard let (d, code) = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "test"]), code < 300,
              let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { return "Couldn't reach the server. Try again in a moment." }
        let n = Int(num(j["sent"]) ?? 0)
        FriendActivity.shared.addSample()
        return n > 0 ? "Sent. Lock your phone: it should pop up in a few seconds. The bell in Friends shows it too." : "The server couldn't deliver it to this phone. Tell Claude so the logs can be checked."
    }

    static func setOn(_ value: Bool) async {
        on = value
        if let token = UserDefaults.standard.string(forKey: "push.token") {
            if value { await upload(token) }
            else { _ = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "unsubscribe", "endpoint": "apns:\(token)"]) }
        } else if value { await start() }
    }
}
