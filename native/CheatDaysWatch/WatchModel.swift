import Foundation
import SwiftUI
import WatchConnectivity

/// The watch's side of the link (WatchLink on the phone): Today as the phone last sent it, kept between launches, and
/// questions sent to the phone's assistant.
@MainActor
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchModel()
    @Published var today: WatchToday

    private static let cacheKey = "watch.today"

    override init() {
        today = WatchCoding.value(WatchToday.self, UserDefaults.standard.data(forKey: Self.cacheKey)) ?? .empty
        super.init()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refresh() {
        Task { _ = await send([WatchKey.today: true]) }
    }

    func set(_ t: WatchToday) {
        today = t
        if let d = WatchCoding.data(t) { UserDefaults.standard.set(d, forKey: Self.cacheKey) }
    }

    enum Outcome {
        case reply([String: Any])
        case failed(String)
    }

    /// A message to the phone and its answer. The phone's app is woken for it if it isn't open.
    func send(_ message: [String: Any]) async -> Outcome {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return .failed("Still connecting to your iPhone. Try again in a moment.") }
        guard WCSession.default.isReachable else { return .failed("Your iPhone isn't nearby. Keep it close, or on the same Wi-Fi.") }
        let out: Outcome = await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            WCSession.default.sendMessage(message, replyHandler: { (r: [String: Any]) in
                cont.resume(returning: .reply(r))
            }, errorHandler: { (_: Error) in
                cont.resume(returning: .failed("Couldn't reach Cheat Days on your iPhone. Open it there and try again."))
            })
        }
        if case .reply(let r) = out {
            if let error = r[WatchKey.error] as? String { return .failed(error) }
            if let t = WatchCoding.value(WatchToday.self, r[WatchKey.today]) { set(t) }
        }
        return out
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let d: Data? = session.receivedApplicationContext[WatchKey.today] as? Data
        Task { @MainActor in
            if let t = WatchCoding.value(WatchToday.self, d) { self.set(t) }
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let d: Data? = applicationContext[WatchKey.today] as? Data
        Task { @MainActor in
            if let t = WatchCoding.value(WatchToday.self, d) { self.set(t) }
        }
    }
}

extension Color {
    /// "aab2f8" as a colour.
    init(hex: String) {
        let v: UInt64 = UInt64(hex, radix: 16) ?? 0xAAB2F8
        self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}

/// The phone's theme on the watch.
struct WatchTheme {
    let c: WatchToday.Colours
    var accent: Color { Color(hex: c.accent) }
    var onAccent: Color { Color(hex: c.onAccent) }
    var hero: Color { Color(hex: c.hero) }
    var heroLabel: Color { Color(hex: c.heroLabel) }
    var track: Color { Color(hex: c.track) }
    func meal(_ m: String) -> Color { Color(hex: c.meals[m] ?? c.accent) }
    /// The phone's cards.
    static let card = Color(red: 0.11, green: 0.115, blue: 0.135)
}

enum Num {
    static func int(_ v: Double) -> String { Int(v.rounded()).formatted() }
}
