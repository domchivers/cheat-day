import SwiftUI

/// Personal bests and the weekly goal's views (26 Nov, design/bests-weekgoal-mockup.html).

/// A best on Workouts: what, the time or distance, and when; one set today is gold.
struct BestTile: View {
    let entry: BestEntry
    var body: some View {
        let fresh: Bool = entry.date == Store.shared.today
        let value: String = entry.def.text(entry.value)
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.def.tile).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.heavy)).monospacedDigit().foregroundStyle(.primary).lineLimit(1)
            Text(fresh ? "New · today" : Bests.day(entry.date)).font(.caption2.weight(fresh ? .bold : .regular))
                .foregroundStyle(fresh ? Color.yellow : Color.secondary)
        }
        .padding(10)
        .frame(minWidth: 96, alignment: .leading)
        .background(fresh ? Color.yellow.opacity(0.14) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Best \(entry.def.tile): \(value), \(Bests.day(entry.date))")
    }
}

/// This week's workouts against the goal: a bar each, filled as they're done (one long bar past seven).
struct GoalBars: View {
    let done: Int
    let goal: Int
    var body: some View {
        if goal <= 7 {
            HStack(spacing: 6) {
                ForEach(0..<goal, id: \.self) { (i: Int) in
                    Capsule().fill(i < done ? Theme.accent : Color(.tertiarySystemFill)).frame(width: 30, height: 8)
                }
            }
            .accessibilityHidden(true)
        } else {
            ProgressView(value: Double(min(done, goal)), total: Double(goal)).tint(Theme.accent).frame(maxWidth: 220)
                .accessibilityHidden(true)
        }
    }
}

/// The workouts goal, set from Workouts: the same one as on Goals' weekly targets.
struct WeekGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    var body: some View {
        let goal: Int = store.workoutsGoal
        NavigationStack {
            List {
                Section {
                    Stepper(value: Binding(get: { goal }, set: { (v: Int) in set(v) }), in: 0...14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Workouts a week").font(.headline)
                            Text(goal == 0 ? "Off" : "\(goal) a week").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Any workout counts: a run, a ride, weights, a class. A week that hits it adds to your weeks in a row. One week short in a month doesn't end it, as rest days don't end your logging streak, so a sick week or a holiday is fine. It's the same goal as on Goals.")
                }
            }
            .navigationTitle("Weekly goal").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func set(_ v: Int) {
        var g: [String: Int] = store.weekGoals
        g["workouts"] = v
        store.perform(["type": "set", "key": "weekGoals", "value": g as JSON], syncAfter: 2)
    }
}

/// All their bests, by kind; each opens the workout it came from.
struct BestsView: View {
    /// "run", "ride", "walk", "hike", or "routes" (26 Nov, design/matched-routes-mockup.html)
    @State private var tab: String = "run"
    @State private var named: Int = 0
    private var store: Store { Store.shared }

    var body: some View {
        let _ = named   // (route names found show)
        let all: [String: BestEntry] = store.bests()
        let kind: MoveKind? = MoveKind(rawValue: tab)
        let routes: [RouteGroup] = kind == nil ? store.routeGroups().sorted { (a: RouteGroup, b: RouteGroup) -> Bool in a.runs.count > b.runs.count } : []
        List {
            Section {
                Picker("Kind", selection: $tab) {
                    ForEach(MoveKind.allCases) { (k: MoveKind) in Text(k.title).tag(k.rawValue) }
                    Text("Routes").tag("routes")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            if let kind {
                Section {
                    ForEach(BestDef.all.filter { (d: BestDef) -> Bool in d.kind == kind }) { (d: BestDef) in
                        if let b = all[d.key] {
                            NavigationLink { WorkoutDetail(workout: b.workout, date: b.date) } label: {
                                row(d.title, value: Self.value(d, b.value), when: Bests.day(b.date))
                            }
                        } else {
                            row(d.title, value: "–", when: "Not yet")
                        }
                    }
                } footer: {
                    Text("Found from your runs, rides, walks and hikes. Fastest times come from the ones mapped with Start, on the workout's own clock, which pauses itself at the lights.")
                }
            } else {
                Section {
                    if routes.isEmpty {
                        Text("Do a run, ride, walk or hike with Start the same way twice and it shows here.").foregroundStyle(.secondary)
                    }
                    ForEach(routes) { (g: RouteGroup) in
                        if let last = g.runs.last {
                            NavigationLink { WorkoutDetail(workout: last.workout, date: last.date) } label: { RouteRow(group: g) }
                        }
                    }
                } footer: {
                    Text("Routes you've done twice or more with Start, either way round. Each is named from Apple Maps: the park or suburb where it starts. Your routes stay on your phone.")
                }
                .task(id: routes.count) {
                    for g in routes { await RouteMatch.nameIfNeeded(g) }
                    named += 1
                }
            }
        }
        .navigationTitle("Your bests")
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    /// A ride's time with its speed: "18:40 · 32.1 km/h".
    static func value(_ d: BestDef, _ v: Double) -> String {
        guard d.kind == .ride, let m = d.fastest, v > 0 else { return d.text(v) }
        return d.text(v) + String(format: " · %.1f km/h", m / v * 3.6)
    }

    private func row(_ title: String, value: String, when: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(when).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.body.weight(.heavy)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value), \(when)")
    }
}

/// After a run or ride: a new best says so, with what it beat; a second best, smaller.
struct BestNewsCard: View {
    let news: BestNews
    var body: some View {
        let first: Bool = news.place == 1
        VStack(alignment: .leading, spacing: 3) {
            Label(first ? news.headline.uppercased() : news.headline + ": " + BestsView.value(news.def, news.value),
                  systemImage: first ? "medal.fill" : "2.circle.fill")
                .font(first ? .caption.weight(.heavy) : .subheadline.weight(.semibold)).foregroundStyle(first ? Color.yellow : Color.primary)
            if first {
                Text(BestsView.value(news.def, news.value)).font(.title2.weight(.heavy)).monospacedDigit()
            }
            if let l = news.line { Text(l).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(first ? 14 : 10)
        .background(Color.yellow.opacity(first ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
