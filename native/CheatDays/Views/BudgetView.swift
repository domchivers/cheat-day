import SwiftUI

/// Your plan, laid out like Progress: the daily budget in big type, the week as bars (tap a day to give it its own
/// budget), the cheat day, weigh-in day and eating back workouts in one list, then the personal plan.
struct BudgetView: View {
    @State private var base: Double = 1600
    @State private var days: [Int: Double] = [:]
    @State private var day: Int?   // the weekday whose own budget is open under the bars
    @State private var eatBack = false
    @State private var loaded = false
    @State private var personalise = false
    @State private var cheat = false
    private var store: Store { Store.shared }
    private let order = [1, 2, 3, 4, 5, 6, 0]
    private var varied: Bool { days.contains { $0.value != base } }
    private func budget(_ d: Int) -> Double { days[d] ?? base }
    private var weekly: Double { order.reduce(0) { $0 + budget($1) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero.padding(.horizontal, 18).padding(.top, 10)
                HStack(alignment: .firstTextBaseline) {
                    section("Your week")
                    Spacer()
                    if varied {
                        Button("Make every day the same") { withAnimation(.snappy) { days = [:]; day = nil } }.font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                    } else {
                        Text("Tap a day to change it").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 18)
                weekCard.padding(.horizontal, 14)
                section("Settings")
                settings.padding(.horizontal, 14)
                HStack(alignment: .firstTextBaseline) {
                    section("Personal plan")
                    Spacer()
                    if !dict(store.doc["plan"]).isEmpty { Button("Redo") { personalise = true }.font(.footnote.weight(.bold)).foregroundStyle(Theme.accent) }
                }
                .padding(.trailing, 18)
                planCard.padding(.horizontal, 14)
            }
            .padding(.bottom, 110)
        }
        .background(Theme.bg)
        .navigationTitle("Your plan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !loaded { load(); loaded = true } }
        .onChange(of: base) { _, _ in save() }
        .onChange(of: days) { _, _ in save() }
        .onChange(of: eatBack) { _, _ in save() }
        .fullScreenCover(isPresented: $personalise, onDismiss: load) { OnboardingView(firstRun: false) { personalise = false } }
        .sheet(isPresented: $cheat, onDismiss: load) { CheatDayView() }
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.headline.weight(.heavy)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 8)
    }
    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    private func round(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38).background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain).buttonRepeatBehavior(.enabled).accessibilityLabel(label)
    }

    // MARK: the budget

    private var hero: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily budget").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.int(base)).font(.system(size: 48, weight: .heavy, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    Text("kcal").font(.headline).foregroundStyle(.secondary)
                }
                Text(varied ? "\(Fmt.int(weekly)) this week · about \(Fmt.int(weekly / 7)) a day" : "\(Fmt.int(weekly)) this week")
                    .font(.subheadline).foregroundStyle(.primary.opacity(0.8)).monospacedDigit()
            }
            Spacer(minLength: 0)
            round("minus", "Lower the daily budget") { withAnimation(.snappy) { base = max(1000, base - 50) } }
            round("plus", "Raise the daily budget") { withAnimation(.snappy) { base = min(5000, base + 50) } }
        }
    }

    /// A bar a day, as tall as its budget against the everyday one; the cheat day's letter is in the accent with a dot.
    private var weekCard: some View {
        card {
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(order, id: \.self) { d in
                        let v = budget(d), on = day == d, isCheat = store.cheatWeekday == d
                        Button { withAnimation(.snappy) { day = on ? nil : d } } label: {
                            VStack(spacing: 5) {
                                Spacer(minLength: 0)
                                Text(Fmt.int(v)).font(.system(size: 10.5, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                                    .foregroundStyle(on ? .primary : .secondary)
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.25)))
                                    .frame(height: min(72, max(18, 44 * v / max(base, 1))))
                                Text(Calendar.current.veryShortWeekdaySymbols[d]).font(.caption2.weight(.semibold))
                                    .foregroundStyle(isCheat ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                                Circle().fill(isCheat ? Theme.accent : .clear).frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(Calendar.current.weekdaySymbols[d])\(isCheat ? ", cheat day" : ""), \(Fmt.int(v))")
                    }
                }
                .frame(height: 118)
                if let d = day {
                    Divider().padding(.top, 12)
                    HStack {
                        (Text(Calendar.current.weekdaySymbols[d]).font(.body.weight(.semibold))
                         + Text(store.cheatWeekday == d ? " · cheat day" : "").font(.footnote).foregroundStyle(.secondary))
                        Spacer()
                        Stepper(value: Binding(get: { budget(d) }, set: { days[d] = $0 }), in: 1000...6000, step: 50) { EmptyView() }.labelsHidden()
                        Text(Fmt.int(budget(d))).font(.headline.weight(.heavy)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                    }
                    .padding(.top, 12)
                }
            }
            .padding(14)
        }
    }

    // MARK: settings

    private var settings: some View {
        card {
            VStack(spacing: 0) {
                Button { cheat = true } label: {
                    HStack {
                        Text("Cheat day").font(.body.weight(.semibold))
                        Spacer()
                        Text(store.cheatWeekday.map { Calendar.current.weekdaySymbols[$0] } ?? "Pick one").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 13).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 14)
                Group {
            // the check-in counts this day's usual weigh-ins only, so a midweek reading can't move the trend
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weigh-in day").font(.body.weight(.semibold))
                    Text(store.weighDaySetting == nil
                         ? store.weighDay.map { "\(Calendar.current.weekdaySymbols[$0]), the day you usually weigh" } ?? "Every weigh-in counts until there's a usual day"
                         : "Only this day's weigh-ins count in the check-in").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // -2 is Automatic (nothing stored), -1 is any day
                Picker("Weigh-in day", selection: Binding(get: { store.weighDaySetting ?? -2 }, set: { store.setWeighDay($0 == -2 ? nil : $0) })) {
                    Text("Automatic").tag(-2)
                    Text("Any day").tag(-1)
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in Text(Calendar.current.weekdaySymbols[d]).tag(d) }
                }
                .labelsHidden().pickerStyle(.menu)
            }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                Divider().padding(.leading, 14)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $eatBack.animation(.snappy)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Eat back workout calories").font(.body.weight(.semibold))
                            Text("Best left off if you're losing weight.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if eatBack {
                        Text("Your budget already allows for your training, and burn figures run high. Eating them back will slow your results.")
                            .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
        }
    }

    // MARK: the personal plan

    @ViewBuilder private var planCard: some View {
        let plan = dict(store.doc["plan"]), macros = dict(plan["macros"])
        if plan.isEmpty {
            Button { personalise = true } label: {
                card {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 38, height: 38).background(Color(.tertiarySystemFill), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Work out my plan").font(.body.weight(.bold)).foregroundStyle(.primary)
                            Text("A few questions, then your budget, protein and cheat day are set for you.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                }
            }
            .buttonStyle(.plain)
        } else {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(goalLine(plan)).font(.body.weight(.bold))
                    HStack(spacing: 0) {
                        stat("\(Int(num(macros["p"]) ?? 0))g", "protein")
                        Divider().frame(height: 34)
                        stat("\(Int(num(macros["c"]) ?? 0))g", "carbs")
                        Divider().frame(height: 34)
                        stat("\(Int(num(macros["f"]) ?? 0))g", "fat")
                    }
                    Text("The weekly check-in can nudge this as your weight moves.").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) { Text(v).font(.title3.weight(.heavy)).monospacedDigit(); Text(l).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }

    private func goalLine(_ plan: JSON) -> String {
        let rate = num(plan["rate"]) ?? 0
        switch str(plan["goal"]) {
        case "lose", "cut": return "Losing \(Fmt.kg(abs(rate))) kg a week"   // 0.45, not rounded to 0.5
        case "recomp": return "Leaner and stronger"
        case "leanbulk", "bulk": return "Building muscle"
        default: return "Keeping steady"
        }
    }

    private func load() {
        base = pos(store.doc["budget"]) ?? 1600
        var d: [Int: Double] = [:]
        for (k, v) in dict(store.doc["dayBudgets"]) { if let i = Int(k), let n = pos(v) { d[i] = n } }
        days = d
        eatBack = store.doc["eatBack"] as? Bool ?? false
    }

    private func save() {
        guard loaded else { return }
        var out = JSON()
        for (k, v) in days where v != base { out[String(k)] = Int(v) }
        store.perform(["type": "budget", "budget": Int(base), "dayBudgets": out, "eatBack": eatBack], syncAfter: 2)
    }
}
