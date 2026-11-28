import StoreKit
import SwiftUI

/// The paywall (28 Nov, design/paywall-mockup.png): the brand line, four ticks, the two plans with yearly first, one
/// button, and what Apple asks to be on it: the price, period and renewal, how to cancel, Restore, Terms and Privacy.
/// `closable`: a ✕ when it's offered (the end of sign-up); none when it stands in for a paid screen (Paid).
struct PaywallView: View {
    var closable = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var subs: Subscription { Subscription.shared }
    @State private var pick = Subscription.yearlyID
    @State private var trial = true   // still eligible for the free week (Apple says, once the plans are in)

    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://domchivers.github.io/cheat-day/privacy.html")!

    private var chosen: Product? { pick == Subscription.yearlyID ? subs.yearly : subs.monthly }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Theme.hero, Theme.bg], startPoint: .top, endPoint: .center).ignoresSafeArea()
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentFill).frame(width: 48, height: 48)
                    .overlay(Image(systemName: "link").font(.title3.weight(.heavy)).foregroundStyle(Theme.onAccent))
                    .padding(.top, 30).padding(.bottom, 18)
                (Text("Every day can feel\nlike ") + Text("a cheat day.").foregroundColor(Theme.accent))
                    .font(.system(size: 28, weight: .heavy)).multilineTextAlignment(.center)
                Spacer(minLength: 16)
                VStack(alignment: .leading, spacing: 18) {
                    tick("Snap a plate, get the calories")
                    tick("Ask about food and workouts")
                    tick("Plan takeaway and cheat days")
                    tick("A plan that learns from you")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                Spacer(minLength: 16)
                plan(Subscription.yearlyID, "Yearly", subs.yearly, note: trial ? "7 days free" : "Best value",
                     detail: subs.yearly.map { "\(perMonth($0)) a month" } ?? "", tag: saving())
                plan(Subscription.monthlyID, "Monthly", subs.monthly, note: trial ? "7 days free" : "Cancel any time", detail: "a month", tag: nil)
                Button { Task { if let p = chosen, await subs.buy(p) { dismiss() } } } label: {
                    Group { if subs.buying { ProgressView() } else { Text(trial ? "Start my free week" : "Continue") } }
                        .font(.headline.weight(.heavy)).frame(maxWidth: .infinity).frame(height: 56)
                        .foregroundStyle(Theme.onAccent).background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain).disabled(chosen == nil || subs.buying).padding(.top, 8)
                if let problem = subs.problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).multilineTextAlignment(.center).padding(.top, 8) }
                Text(fine).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 12).padding(.horizontal, 6)
                HStack(spacing: 20) {
                    Button("Restore purchases") { Task { await subs.restore(); if subs.active { dismiss() } } }
                    Button("Terms") { openURL(Self.terms) }
                    Button("Privacy") { openURL(Self.privacy) }
                }
                .font(.caption).underline().foregroundStyle(.secondary).buttonStyle(.plain).padding(.top, 10).padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            if closable {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain).padding(.trailing, 20).padding(.top, 8).accessibilityLabel("Close")
            }
        }
        .task {
            if !subs.loaded { await subs.load() }
            if let s = subs.yearly?.subscription { trial = await s.isEligibleForIntroOffer }
        }
    }

    private func tick(_ s: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26).background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(s).font(.body.weight(.medium))
        }
    }

    private func plan(_ id: String, _ name: String, _ p: Product?, note: String, detail: String, tag: String?) -> some View {
        let on = pick == id
        return Button { pick = id } label: {
            HStack(spacing: 12) {
                Circle().strokeBorder(on ? Theme.accent : Color.secondary.opacity(0.6), lineWidth: 2).frame(width: 22, height: 22)
                    .overlay { if on { Circle().fill(Theme.accent).frame(width: 11, height: 11) } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(p?.displayPrice ?? "…").font(.headline)
                    Text(detail).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).frame(height: 68)
            .background(on ? Theme.accent.opacity(0.08) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Theme.accent : Color.secondary.opacity(0.35), lineWidth: 1.5))
            .overlay(alignment: .topLeading) {
                if let tag {
                    Text(tag).font(.caption2.weight(.heavy)).foregroundStyle(Theme.onAccent).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).offset(x: 14, y: -10)
                }
            }
        }
        .buttonStyle(.plain).padding(.bottom, 12)
    }

    /// The yearly price a month, in their own currency.
    private func perMonth(_ p: Product) -> String { (p.price / 12).formatted(p.priceFormatStyle) }

    /// "SAVE 49%": yearly against twelve months of monthly, when both are in.
    private func saving() -> String? {
        guard let y = subs.yearly, let m = subs.monthly, m.price > 0 else { return nil }
        let pct = Int(((1 - (y.price as NSDecimalNumber).doubleValue / ((m.price as NSDecimalNumber).doubleValue * 12)) * 100).rounded())
        return pct >= 5 ? "SAVE \(pct)%" : nil
    }

    /// Apple's terms for an auto-renewing plan, for the one picked.
    private var fine: String {
        guard let p = chosen else { return "Renews automatically until you cancel. Cancel any time in Settings, at least 24 hours before it renews." }
        let period = p.id == Subscription.yearlyID ? "a year" : "a month"
        return (trial ? "7 days free, then \(p.displayPrice) \(period). " : "\(p.displayPrice) \(period). ")
            + "Renews automatically until you cancel; cancel any time in Settings, at least 24 hours before it renews."
    }
}
