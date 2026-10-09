import SwiftUI

/// Plan and budget: the plan in a card, the daily budget, a different budget on some days, the cheat day, and eating back workouts.
struct BudgetView: View {
    @State private var base: Double = 1600
    @State private var days: [Int: Double] = [:]
    @State private var perDay = false
    @State private var eatBack = false
    @State private var loaded = false
    @State private var personalise = false
    @State private var cheat = false
    private var store: Store { Store.shared }
    private let order = [1, 2, 3, 4, 5, 6, 0]

    var body: some View {
        List {
            Section { planCard } footer: {
                if !dict(store.doc["plan"]).isEmpty { Text("The weekly check-in can nudge this as your weight moves.") }
            }
            Section {
                HStack {
                    Text("Every day")
                    Spacer()
                    Stepper(value: $base, in: 1000...5000, step: 50) { EmptyView() }.labelsHidden()
                    Text("\(Fmt.int(base))").font(.title3.weight(.heavy)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([1400.0, 1600, 1800, 2000, 2200, 2500], id: \.self) { v in
                            Chip(text: Fmt.int(v), on: base == v) { base = v }
                        }
                    }
                }
            } header: { Text("Daily budget") }
            Section {
                Toggle("Different budget on some days", isOn: $perDay.animation(.snappy))
                if perDay {
                    ForEach(order, id: \.self) { d in
                        HStack {
                            Text(Calendar.current.weekdaySymbols[d])
                            if store.cheatWeekday == d { PizzaIcon(size: 14).scaleEffect(y: -1) }
                            Spacer()
                            Stepper(value: Binding(get: { days[d] ?? base }, set: { days[d] = $0 }), in: 1000...6000, step: 50) { EmptyView() }.labelsHidden()
                            Text(Fmt.int(days[d] ?? base)).font(.headline).monospacedDigit().frame(minWidth: 60, alignment: .trailing)
                                .foregroundStyle(days[d] != nil && days[d] != base ? Theme.warn : .primary)
                        }
                    }
                    Button("Make every day the same") { withAnimation { days = [:] } }.foregroundStyle(.secondary)
                }
            } footer: {
                Text("This week: \(Fmt.int(weekly)) kcal, about \(Fmt.int(weekly / 7)) a day.")
            }
            Section {
                Button { cheat = true } label: {
                    HStack {
                        PizzaIcon(size: 20).scaleEffect(y: -1)
                        Text(store.cheatWeekday.map { "Cheat day: \(Calendar.current.weekdaySymbols[$0])" } ?? "Pick a cheat day")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                Toggle(isOn: $eatBack) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Eat back workout calories")
                        Text("A workout adds what it burned to that day's budget").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Plan and budget")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !loaded { load(); loaded = true } }
        .onChange(of: base) { _, _ in save() }
        .onChange(of: days) { _, _ in save() }
        .onChange(of: perDay) { _, on in if !on { days = [:] }; save() }
        .onChange(of: eatBack) { _, _ in save() }
        .fullScreenCover(isPresented: $personalise, onDismiss: load) { OnboardingView(firstRun: false) { personalise = false } }
        .sheet(isPresented: $cheat, onDismiss: load) { CheatDayView() }
    }

    private var weekly: Double { order.reduce(0) { $0 + (perDay ? (days[$1] ?? base) : base) } }

    private var planCard: some View {
        let plan = dict(store.doc["plan"]), macros = dict(plan["macros"])
        return VStack(alignment: .leading, spacing: 10) {
            if plan.isEmpty {
                Text("No plan yet").font(.headline)
                Text("Answer a few questions and the app works out your budget, protein and a cheat day around the food you love.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Eyebrow(text: "Your plan", color: Theme.heroLabel)
                Text(goalLine(plan)).font(.title3.bold())
                HStack(spacing: 18) {
                    stat(Fmt.int(num(plan["kcal"]) ?? 0), "kcal a day")
                    stat("\(Int(num(macros["p"]) ?? 0))g", "protein")
                    stat("\(Int(num(macros["c"]) ?? 0))g", "carbs")
                    stat("\(Int(num(macros["f"]) ?? 0))g", "fat")
                }
            }
            Button { personalise = true } label: {
                Label(plan.isEmpty ? "Work out my plan" : "Personalise my plan", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14)).foregroundStyle(.black)
        }
        .padding(.vertical, 6)
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(v).font(.headline.weight(.heavy)).monospacedDigit(); Text(l).font(.caption).foregroundStyle(.secondary) }
    }

    private func goalLine(_ plan: JSON) -> String {
        let rate = num(plan["rate"]) ?? 0
        switch str(plan["goal"]) {
        case "lose", "cut": return "Losing \(Fmt.one(abs(rate))) kg a week"
        case "recomp": return "Leaner and stronger"
        case "leanbulk", "bulk": return "Building muscle"
        default: return "Keeping steady"
        }
    }

    private func load() {
        base = pos(store.doc["budget"]) ?? 1600
        var d: [Int: Double] = [:]
        for (k, v) in dict(store.doc["dayBudgets"]) { if let i = Int(k), let n = pos(v) { d[i] = n } }
        days = d; perDay = !d.isEmpty
        eatBack = store.doc["eatBack"] as? Bool ?? false
    }

    private func save() {
        guard loaded else { return }
        var out = JSON()
        if perDay { for (k, v) in days where v != base { out[String(k)] = Int(v) } }
        store.perform(["type": "budget", "budget": Int(base), "dayBudgets": out, "eatBack": eatBack], syncAfter: 2)
    }
}
