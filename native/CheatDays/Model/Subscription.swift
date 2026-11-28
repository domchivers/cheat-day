import StoreKit
import SwiftUI

/// Cheat Days' subscription (28 Nov, design/paywall-mockup.png): a hard paywall. A 7-day free trial on both plans
/// (A$12.99 a month, A$79.99 a year), then a subscription keeps logging, Ask and workouts going. Without one the app
/// still opens: Today and past days to look at, friends and family to view and cheer, Settings to export or delete.
///
/// Nothing is locked until the App Store has the plans: with no products back (App Store Connect not set up yet, the
/// tests, the demo) the app stays open, so testers are never shut out by a store that isn't ready.
@MainActor @Observable
final class Subscription {
    static let shared = Subscription()

    static let yearlyID = "com.cheatdays.app.yearly"
    static let monthlyID = "com.cheatdays.app.monthly"

    private(set) var products: [Product] = []
    /// The plan they're on, while it's live (a free trial counts).
    private(set) var current: Product.SubscriptionInfo.Status?
    private(set) var currentID: String?
    private(set) var renews: Date?
    private(set) var inTrial = false
    private(set) var loaded = false
    /// The signed proof of the live subscription, for the server's own check before AI calls.
    private(set) var proof: String?
    var problem: String?
    var buying = false

    private var updates: Task<Void, Never>?

    /// Subscribed or in the trial.
    var active: Bool { currentID != nil }
    /// The store has the plans and they're on none of them: the paywall instead of the paid parts.
    var locked: Bool {
        if Self.bypass { return false }
        return loaded && !products.isEmpty && !active
    }
    /// Tests, the demo and the marketing record never meet the paywall.
    static var bypass: Bool {
        let a = ProcessInfo.processInfo.arguments
        return a.contains { $0.hasPrefix("-uitest") || $0.hasPrefix("-demo") } || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var yearly: Product? { products.first { $0.id == Self.yearlyID } }
    var monthly: Product? { products.first { $0.id == Self.monthlyID } }

    private init() {}

    /// Once at launch: the plans, what they're on, and every change from here on (a renewal, a refund, Family Sharing).
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await load(); await refresh() }
    }

    func load() async {
        do { products = try await Product.products(for: [Self.yearlyID, Self.monthlyID]).sorted { $0.price > $1.price } }
        catch { products = [] }
        loaded = true
    }

    /// What they're entitled to now, from Apple's signed transactions on this phone.
    func refresh() async {
        var id: String?, until: Date?, trial = false, jws: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.productType == .autoRenewable, t.revocationDate == nil else { continue }
            if let e = t.expirationDate, e < Date() { continue }
            id = t.productID; until = t.expirationDate; jws = result.jwsRepresentation
            trial = t.offerType == .introductory
        }
        currentID = id; renews = until; inTrial = trial; proof = jws
    }

    /// Buy a plan (its free week first, when they haven't had one). True when it's on.
    @discardableResult
    func buy(_ p: Product) async -> Bool {
        buying = true; problem = nil
        defer { buying = false }
        do {
            switch try await p.purchase() {
            case .success(let v):
                guard case .verified(let t) = v else { problem = "Apple couldn't confirm the purchase. Try Restore purchases."; return false }
                await t.finish(); await refresh(); return active
            case .pending: problem = "Waiting for approval (Ask to Buy). It'll turn on once it's approved."; return false
            case .userCancelled: return false
            @unknown default: return false
            }
        } catch { problem = "Couldn't reach the App Store. Check your connection and try again."; return false }
    }

    /// Restore purchases: their Apple ID's subscriptions back on this phone.
    func restore() async {
        buying = true; problem = nil
        defer { buying = false }
        do { try await AppStore.sync() } catch { problem = "Couldn't reach the App Store. Check your connection and try again." }
        await refresh()
        if !active, problem == nil { problem = "No Cheat Days subscription on this Apple ID." }
    }

    /// The trial or plan, said plainly for Settings: "Free until 5 Dec", "Renews 28 Nov 2027".
    var status: String {
        guard active else { return "Not subscribed" }
        guard let renews else { return "Active" }
        let thisYear = Calendar.current.isDate(renews, equalTo: Date(), toGranularity: .year)
        let d = thisYear ? renews.formatted(.dateTime.day().month(.abbreviated))
                         : renews.formatted(.dateTime.day().month(.abbreviated).year())   // .omitted is iOS 18 only
        return inTrial ? "Free until \(d)" : "Renews \(d)"
    }
    var planName: String { currentID == Self.monthlyID ? "Cheat Days monthly" : currentID == Self.yearlyID ? "Cheat Days yearly" : "Cheat Days" }
}

/// A paid part of the app (Add, Ask, workouts): itself while they're subscribed or in the trial, else the paywall in its place.
struct Paid<Content: View>: View {
    @ViewBuilder var content: () -> Content
    private var subs: Subscription { Subscription.shared }
    var body: some View {
        if subs.locked { PaywallView(closable: false) } else { content() }
    }
}
