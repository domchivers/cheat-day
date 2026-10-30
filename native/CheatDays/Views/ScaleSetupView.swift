import HealthKit
import SwiftUI

/// A bathroom scale in the flat style of the Fluent icons: light body, a small blue display, two foot pads.
struct ScaleIcon: View {
    var size: CGFloat = 80
    var body: some View {
        Canvas { ctx, sz in
            let u = sz.width / 32
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * u, y: y * u, width: w * u, height: h * u), cornerRadius: c * u, style: .continuous)
            }
            ctx.fill(r(3, 5.5, 26, 24, 6), with: .color(Color(red: 0.55, green: 0.61, blue: 0.68)))
            ctx.fill(r(3, 3, 26, 24.5, 6), with: .linearGradient(Gradient(colors: [Color(red: 0.91, green: 0.93, blue: 0.96), Color(red: 0.73, green: 0.77, blue: 0.82)]),
                                                               startPoint: CGPoint(x: 0, y: 3 * u), endPoint: CGPoint(x: 0, y: 27.5 * u)))
            ctx.fill(r(10, 6.5, 12, 5, 2.2), with: .color(Color(red: 0.23, green: 0.29, blue: 0.37)))
            ctx.fill(r(11.5, 8.2, 9, 1.6, 0.8), with: .color(Color(red: 0.37, green: 0.72, blue: 1.0)))
            let pad = Color(red: 0.81, green: 0.85, blue: 0.89)
            ctx.fill(Path(ellipseIn: CGRect(x: 6.9 * u, y: 15.6 * u, width: 7.2 * u, height: 8.8 * u)), with: .color(pad))
            ctx.fill(Path(ellipseIn: CGRect(x: 17.9 * u, y: 15.6 * u, width: 7.2 * u, height: 8.8 * u)), with: .color(pad))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// After signing in, before the tour: connect a smart scale through Apple Health, choose whether its old weigh-ins
/// come in or only new ones, then how it works day to day. Skippable; Body has the same switch later.
struct ScaleSetupView: View {
    let done: () -> Void
    enum Step { case intro, history, connected }
    @State private var step = Step.intro
    @State private var busy = false
    @State private var problem: String?
    @State private var found: (count: Int, first: Date?, latest: HKQuantitySample?) = (0, nil, nil)
    @State private var keepHistory = true
    @State private var brought = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case .intro: intro
                case .history: history
                case .connected: connected
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            Spacer()
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).multilineTextAlignment(.center).padding(.bottom, 10) }
            Button { Task { await next() } } label: {
                Text(busy ? "One moment…" : step == .intro ? "Connect Apple Health" : step == .history ? "Continue" : "Show me around")
                    .font(.headline).foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity).frame(height: 50)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain).disabled(busy)
            Button("Not now") { done() }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.heroLabel)
                .padding(.top, 14).opacity(step == .intro ? 1 : 0).disabled(step != .intro)
        }
        .padding(.horizontal, 28).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .animation(.snappy, value: step)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            ScaleIcon(size: 80)
            Text("Connect your scale").font(.title2.weight(.heavy))
            Text("Weigh-ins come in by themselves, with body fat and lean mass if your scale measures them.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Works with VeSync, Withings, Eufy, Renpho, Fitbit, Garmin and others, through Apple Health.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var history: some View {
        VStack(spacing: 14) {
            FluentIcon(emoji: "📈", size: 72)
            Text(found.count > 0 ? "Bring in your history?" : "No weigh-ins yet").font(.title2.weight(.heavy))
            Text(found.count > 0
                 ? "We found \(found.count) weigh-in\(found.count == 1 ? "" : "s") in Apple Health\(found.first.map { ", back to \($0.formatted(.dateTime.month(.wide).year()))" } ?? "")."
                 : "Nothing in Apple Health yet. New weigh-ins will come in from now on.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if found.count > 0 {
                choice(true, "Bring in my history", "Your trend starts with everything you've weighed. Best if the scale's been yours all along.")
                choice(false, "Start fresh from today", "Only new weigh-ins from now on. Good if the old ones aren't yours or aren't right.")
            }
        }
    }

    private func choice(_ value: Bool, _ title: String, _ text: String) -> some View {
        Button { keepHistory = value } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(keepHistory == value ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: keepHistory)
    }

    private var connected: some View {
        VStack(spacing: 14) {
            FluentIcon(emoji: "✅", size: 64)
            Text("Scale connected").font(.title2.weight(.heavy))
            if let s = found.latest, keepHistory || s.endDate >= Calendar.current.startOfDay(for: Date()) {
                VStack(spacing: 2) {
                    Text("Latest weigh-in").font(.footnote).foregroundStyle(.secondary)
                    Text("\(Fmt.kg2(s.quantity.doubleValue(for: .gramUnit(with: .kilo)))) kg").font(.title.weight(.heavy))
                    Text(s.endDate.formatted(.relative(presentation: .named)) + (brought > 1 ? " · \(brought) days brought in" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(14)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 10) {
                stepRow(1, "Weigh yourself as usual.")
                stepRow(2, "Open your scale's app once, so it sends the weigh-in to Apple Health.")
                stepRow(3, "Open Cheat Days: it picks it up straight away.")
            }
            .padding(.top, 4)
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.footnote.weight(.heavy)).foregroundStyle(Theme.onAccent).frame(width: 22, height: 22).background(Theme.accent, in: Circle())
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func next() async {
        problem = nil
        switch step {
        case .intro:
            busy = true
            defer { busy = false }
            do {
                try await HealthSync.authorize()
                found = await HealthSync.history()
                step = .history
            } catch { problem = error.localizedDescription }
        case .history:
            busy = true
            brought = await HealthSync.start(history: keepHistory || found.count == 0)
            busy = false
            step = .connected
        case .connected:
            done()
        }
    }
}
