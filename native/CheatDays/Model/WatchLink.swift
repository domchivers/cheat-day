import Foundation
import SwiftUI
import UIKit
import WatchConnectivity

/// The phone's side of the watch app (25 Nov, design/watch-app-v5-mockup.html): Today goes to the watch whenever the
/// record changes, and the watch's questions are answered here, by the same assistant as the phone's chat, since the
/// AI lives on the phone. Add on the watch adds the estimate here, exactly as the chat's Add does.
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private var last: Data?
    /// Estimates the watch was shown, by id, for its Add.
    private var shown: [String: (estimate: JSON, meal: String)] = [:]

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var ready: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
    }

    /// Today to the watch, when it's changed since last time (Store.persist).
    func update(_ store: Store) {
        guard ready, let d = WatchCoding.data(Self.today(store)), d != last else { return }
        last = d
        try? WCSession.default.updateApplicationContext([WatchKey.today: d])
    }

    // MARK: Today for the watch

    static func today(_ store: Store) -> WatchToday {
        let items: [JSON] = store.todayItems
        let meals: [WatchToday.Meal] = Meals.all.compactMap { (name: String) -> WatchToday.Meal? in
            let mine: [JSON] = items.filter { (it: JSON) -> Bool in Meals.of(it) == name }
            guard !mine.isEmpty else { return nil }
            return WatchToday.Meal(name: name, kcal: mine.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, foods: mine.map(food))
        }
        let eaten: Double = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return WatchToday(date: store.today, budget: store.budgetToday, eaten: eaten, protein: store.macros(items).p,
                          proteinGoal: store.proteinGoal, meals: meals, colours: colours())
    }

    private static func food(_ it: JSON) -> WatchToday.Food {
        let name: String = str(it["name"])
        let k: Double = num(it["kcal"]) ?? 0
        return WatchToday.Food(id: str(it["id"]), name: name, kcal: k, amount: FoodMath.amountText(it, kcal: k), icon: icon(name, hint: str(it["matched"])))
    }

    private static func icon(_ name: String, hint: String = "") -> String {
        let a: String = FoodEmoji.asset(FoodIcons.shared.icon(name, hint: hint) ?? "🍽️")
        // only icons both apps have (FoodIcons.xcassets); the phone shows its own emoji for the rest, the watch a plate
        return UIImage(named: a) != nil ? a : FoodEmoji.asset("🍽️")
    }

    /// The theme's dark-mode colours, as the watch is always dark.
    private static func colours() -> WatchToday.Colours {
        let p: Palette = Palette.current
        return WatchToday.Colours(accent: hex(p.accent), onAccent: hex(p.onAccent), hero: hex(p.hero), heroLabel: hex(p.heroLabel), track: hex(p.track),
                                  meals: Dictionary(uniqueKeysWithValues: Meals.all.map { ($0, hex(Theme.meal($0))) }))
    }

    private static func hex(_ c: Color) -> String {
        let ui: UIColor = UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    // MARK: the watch's questions

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.last = nil; self.update(Store.shared) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.last = nil; self.update(Store.shared) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let box = Reply(replyHandler)
        let text: String = (message[WatchKey.food] as? String) ?? ""
        let chat: WatchChat? = WatchCoding.value(WatchChat.self, message[WatchKey.ask])
        let add: String? = message[WatchKey.add] as? String
        let wantsToday: Bool = message[WatchKey.today] != nil
        Task { @MainActor in
            let out: [String: Any] = await self.handle(food: text, chat: chat, add: add, today: wantsToday)
            box.send(out)
        }
    }

    /// The reply handler, carried to the main actor.
    private final class Reply: @unchecked Sendable {
        let send: ([String: Any]) -> Void
        init(_ f: @escaping ([String: Any]) -> Void) { send = f }
    }

    private func handle(food: String, chat: WatchChat?, add: String?, today: Bool) async -> [String: Any] {
        let store = Store.shared
        if let id = add {
            guard let s = shown[id] else { return [WatchKey.error: "That one's gone. Say it again."] }
            Self.add(s.estimate, meal: s.meal, store: store)
            shown[id] = nil
            return [WatchKey.today: WatchCoding.data(Self.today(store)) ?? Data()]
        }
        if !food.isEmpty {
            do {
                let r: JSON = try await Assistant.ask([Assistant.Turn(me: true, text: food)], store: store)
                guard let e = r["estimate"] as? JSON else {
                    // no food in it: the assistant's words, as the watch's chat would show them
                    return [WatchKey.error: str(r["reply"]).isEmpty ? "Couldn't tell what that was. Try again?" : str(r["reply"])]
                }
                return [WatchKey.food: WatchCoding.data(remember(e, r: r)) ?? Data()]
            } catch {
                return [WatchKey.error: "Couldn't reach the assistant. Check your phone's connection."]
            }
        }
        if let chat, !chat.lines.isEmpty {
            let turns: [Assistant.Turn] = chat.lines.map { (l: WatchLine) -> Assistant.Turn in Assistant.Turn(me: l.me, text: l.text) }
            do {
                let r: JSON = try await Assistant.ask(turns, store: store)
                let est: WatchEstimate? = (str(r["kind"]) == "estimate" ? r["estimate"] as? JSON : nil).map { (e: JSON) -> WatchEstimate in remember(e, r: r) }
                let text: String = str(r["reply"]).isEmpty ? (est.map { "\($0.name): about \(Int($0.kcal.rounded())) kcal." } ?? "") : str(r["reply"])
                return [WatchKey.ask: WatchCoding.data(WatchAnswer(text: text, estimate: est)) ?? Data()]
            } catch {
                return [WatchKey.error: "Couldn't reach the assistant. Check your phone's connection."]
            }
        }
        _ = today
        return [WatchKey.today: WatchCoding.data(Self.today(store)) ?? Data()]
    }

    /// An estimate as the watch shows it, kept here for its Add.
    private func remember(_ e: JSON, r: JSON) -> WatchEstimate {
        let meal: String = str(r["meal"]).isEmpty ? Meals.forEstimate(e, opened: Meals.now) : str(r["meal"])
        let id: String = UUID().uuidString
        shown[id] = (e, meal)
        let parts: [WatchToday.Food] = list(e["parts"]).map { (p: JSON) -> WatchToday.Food in
            let name: String = str(p["name"])
            return WatchToday.Food(id: UUID().uuidString, name: name, kcal: num(p["kcal"]) ?? 0, amount: "", icon: Self.icon(name))
        }
        let shownParts: [WatchToday.Food] = parts.isEmpty
            ? [WatchToday.Food(id: id, name: str(e["name"]), kcal: num(e["kcal_total"]) ?? 0, amount: "", icon: Self.icon(str(e["name"])))]
            : parts
        return WatchEstimate(id: id, name: str(e["name"]), meal: meal, kcal: num(e["kcal_total"]) ?? 0, protein: num(e["protein_g"]) ?? 0, parts: shownParts)
    }

    /// As the chat's Add does it (AssistantView's estimate card): one food, the AI's numbers kept on it.
    private static func add(_ e: JSON, meal: String, store: Store) {
        let k: Double = num(e["kcal_total"]) ?? 0
        var b: JSON = Assistant.basis(name: str(e["name"]), kcal: k, grams: num(e["portion_g"]), unit: str(e["unit"]).isEmpty ? "g" : str(e["unit"]),
                                      p: num(e["protein_g"]) ?? 0, c: num(e["carbs_g"]) ?? 0, f: num(e["fat_g"]) ?? 0)
        if !str(e["shop"]).isEmpty { b["shop"] = str(e["shop"]) }
        if let g = pos(e["aiPortion"]) ?? pos(e["portion_g"]) { b["aiGrams"] = g; b["aiKcal"] = num(e["aiPortionKcal"]) ?? k }
        b["aiMatches"] = list(e["parts"]).map { "\(str($0["name"])) → \(str($0["match"]).isEmpty ? "unchecked" : str($0["match"]))" }.joined(separator: "; ")
        b["from"] = "watch"
        _ = store.add(b, kcal: k, meal: meal)
    }
}
