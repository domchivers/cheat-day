import UIKit
import UserNotifications

/// Lock-screen notifications from friends (reactions, comments, food sent, friend requests): the app registers with
/// Apple's push service and hands its device token to the server's push function, which sends through APNs.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // a message can be answered from its notification
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "message", actions: [reply], intentIdentifiers: [])])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Push.upload(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    // shown even while the app is open
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Start running's switches are for a locked phone: open, the timer's own voice says it (25 Nov)
        if notification.request.identifier.hasPrefix("run.switch.") { return [] }
        Task { @MainActor in await FriendActivity.shared.load(); await Messages.shared.load(); await Messages.shared.refresh() }
        return [.banner, .sound]
    }

    // tapping one: food sent goes to Today (it's waiting there), anything else to Friends
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String ?? "", post = info["post"] as? String ?? ""
        // for another account on this phone: that account first, then the reply or the screen (26 Nov)
        if let who = info["user"] as? String, !who.isEmpty { await Accounts.shared.ensure(who) }
        // Reply, typed on the notification itself: sent without opening the app
        if let r = response as? UNTextInputNotificationResponse, r.actionIdentifier == "reply", post.hasPrefix("chat:") {
            let text = r.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { await Messages.shared.send(to: String(post.dropFirst(5)), text: text) }
            return
        }
        await MainActor.run {
            if kind == "plan" { Nav.shared.plan(info["meal"] as? String ?? "Lunch"); return }   // a meal reminder: its planner
            if kind.contains("message"), post.hasPrefix("chat:") { Nav.shared.chat(String(post.dropFirst(5))); Task { await Messages.shared.load() }; return }
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
    var friendsSeg = 1   // the feed first
    var focusPost: String?
    /// A message notification tapped: that chat, on Friends.
    var chatWith: String?
    /// A friend's QR code scanned with the Camera app: Add a friend, with their code in.
    var addCode: String?
    /// The meal a reminder asked to plan: Today opens the planner on it.
    var planMeal: String?

    func today() { NotificationCenter.default.post(name: .openTab, object: 0) }
    func plan(_ meal: String) { planMeal = meal; today() }
    func people() { friendsSeg = 0; NotificationCenter.default.post(name: .openTab, object: 2) }
    func chat(_ friend: String) { chatWith = friend; NotificationCenter.default.post(name: .openTab, object: 2) }
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

    /// One row per account on this phone (26 Nov): "apns:<token>#<account>", so each account's news still comes.
    static func endpoint(_ token: String) -> String { "apns:\(token)#\(Supabase.shared.userId ?? "")" }

    static func upload(_ token: String) async {
        UserDefaults.standard.set(token, forKey: "push.token")
        guard Supabase.shared.userId != nil else { return }
        // the one row from before accounts (the token alone): gone, so nothing comes twice
        _ = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "unsubscribe", "endpoint": "apns:\(token)"] as JSON)
        // the app's own reminders are local, so only friends' news comes from the server
        let body: JSON = ["action": "subscribe", "tz": TimeZone.current.identifier,
                          "subscription": ["endpoint": endpoint(token), "keys": ["p256dh": "apns", "auth": "apns"] as JSON] as JSON,
                          "prefs": ["lunch": false, "social": on] as JSON]
        _ = try? await Supabase.shared.call("/functions/v1/push", body: body)
    }

    static func setOn(_ value: Bool) async {
        on = value
        if let token = UserDefaults.standard.string(forKey: "push.token") {
            if value { await upload(token) }
            else { _ = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "unsubscribe", "endpoint": endpoint(token)]) }
        } else if value { await start() }
    }

    /// Logging out of this account: its notifications stop coming to this phone.
    static func leave() async {
        guard let token = UserDefaults.standard.string(forKey: "push.token") else { return }
        _ = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "unsubscribe", "endpoint": endpoint(token)] as JSON)
    }
}
