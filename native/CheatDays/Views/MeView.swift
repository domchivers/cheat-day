import Charts
import SwiftUI

private struct WeightPoint: Identifiable { let id = UUID(); let date: Date; let kg: Double }

/// You: weight trend, this week, and the rest of the app's pages (still web for now) in one list.
struct MeView: View {
    @State private var confirmSignOut = false
    @State private var weighing = false
    @State private var personalise = false
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 48)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName).font(.title2.bold())
                            Text(Supabase.shared.email).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section { weightCard }
                Section {
                    HStack {
                        tile("\(Fmt.int(store.baseBudget(store.today)))", "daily budget")
                        Divider()
                        tile(weekText, "days on budget")
                        Divider()
                        tile("\(workoutsThisWeek)", "workouts this week")
                    }
                    .frame(maxWidth: .infinity)
                }
                Section {
                    Button { personalise = true } label: { Label("Personalise my plan", systemImage: "sparkles") }
                    NavigationLink { CheckInView() } label: { Label("Weekly check-in", systemImage: "chart.line.uptrend.xyaxis") }
                    NavigationLink { BudgetView() } label: { Label("Plan and budget", systemImage: "target") }
                    page("Body and weigh-ins", "scalemass.fill", "body")
                    NavigationLink { HistoryView() } label: { Label("History", systemImage: "calendar") }
                    page("Goals and badges", "trophy.fill", "goals")
                    NavigationLink { MealsView() } label: { Label("Your meals", systemImage: "fork.knife") }
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape.fill") }
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Cheat Days \(Bundle.main.shortVersion)\(store.lastSynced.map { " · synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "")")
                }
            }
            .navigationTitle("Me")
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .refreshable { await store.sync(); await store.pullBody() }
            .sheet(isPresented: $weighing) { WeighInSheet().presentationDetents([.medium]) }
            .fullScreenCover(isPresented: $personalise) { OnboardingView(firstRun: false) { personalise = false } }
            .confirmationDialog("Sign out of Cheat Days on this phone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    WebHost.shared.signOut()
                    Supabase.shared.signOut()
                    store.reset()
                }
            } message: { Text("Everything stays in your account. Sign in again to get it back.") }
        }
    }

    private var displayName: String {
        let e = Supabase.shared.email
        return e.split(separator: "@").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "You"
    }

    private var points: [WeightPoint] {
        let rows = list(store.doc["body"]).compactMap { r -> WeightPoint? in
            guard let kg = pos(r["weight"]), !str(r["day"]).isEmpty else { return nil }
            return WeightPoint(date: DayKey.date(str(r["day"])), kg: kg)
        }
        return Array(rows.sorted { $0.date < $1.date }.suffix(60))
    }

    @ViewBuilder private var weightCard: some View {
        let pts = points
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Weight", color: Theme.heroLabel)
                Spacer()
                if let first = pts.first, let last = pts.last, pts.count > 1 {
                    let change = last.kg - first.kg
                    Text("\(change <= 0 ? "−" : "+")\(String(format: "%.1f", abs(change))) kg")
                        .font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(Theme.accent)
                }
            }
            if let last = pts.last {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", last.kg)).font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text("kg").font(.headline).foregroundStyle(.secondary)
                }
                if pts.count > 1 {
                    Chart(pts) { p in
                        LineMark(x: .value("Day", p.date), y: .value("kg", p.kg))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis(.hidden)
                    .frame(height: 110)
                }
            } else {
                Text("No weigh-ins yet").font(.title3.bold())
                Text("Weigh in and your trend shows here.").font(.footnote).foregroundStyle(.secondary)
            }
            Button { weighing = true } label: { Label("Weigh in", systemImage: "scalemass.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).padding(.top, 4)
        }
        .padding(.vertical, 6)
    }

    private var weekDates: [String] {
        let today = store.today
        let back = (DayKey.weekday(today) + 6) % 7   // Monday first
        return (0...back).map { DayKey.shift(today, days: -back + $0) }
    }

    private var weekText: String {
        var on = 0, logged = 0
        for d in weekDates {
            var kcal = 0.0, budget = 0.0, has = false
            if d == store.today {
                if !store.todayItems.isEmpty { kcal = store.eaten; budget = store.budgetToday; has = true }
            } else if let p = store.pastDay(d), !p.items.isEmpty {
                kcal = p.kcal; budget = p.budget; has = true
            }
            if has { logged += 1; if kcal <= budget { on += 1 } }
        }
        return "\(on)/\(max(logged, 1))"
    }

    private var workoutsThisWeek: Int {
        weekDates.reduce(0) { n, d in
            if d == store.today { return n + store.todayWorkouts.count }
            let h = list(store.doc["history"]).first { str($0["date"]) == d }
            return n + list(h?["workouts"]).count
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.heavy)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func page(_ title: String, _ symbol: String, _ view: String) -> some View {
        NavigationLink {
            WebScreen(view: view, pushed: true)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .onDisappear { Task { try? await Task.sleep(nanoseconds: 1_200_000_000); await Store.shared.sync() } }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
