import Charts
import SwiftUI

private struct DayBar: Identifiable { let id: String; let label: String; let kcal: Double; let walk: Double; let today: Bool }

/// Workouts: the week, one big Start, routines and today's, with past workouts and every exercise a tap away.
struct WorkoutsView: View {
    @State private var showSession = false
    @State private var showActivity = false
    @State private var confirmRoutineDelete: JSON?
    @State private var building = false
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            List {
                if let s = store.session {
                    Section {
                        Button { showSession = true } label: { liveCard(s) }.buttonStyle(.plain)
                    }
                    .listRowBackground(Theme.hero)
                }
                if let plan = store.workoutPlan {
                    Section {
                        PlanCard(plan: plan) { ps in
                            if store.session == nil { store.startPlanSession(ps, plan: plan) }
                            showSession = true
                        }
                        .listRowBackground(Theme.hero)
                        VolumeRows(plan: plan)
                        NavigationLink { PlanEditor() } label: { Label("Edit your week", systemImage: "slider.horizontal.3") }
                    }
                } else {
                    Section {
                        Button { building = true } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "calendar.badge.plus").font(.title2).foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Get a workout plan").font(.headline)
                                    Text("A week built around your days, kit and goal, with weights that go up when you're ready.").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section { weekCard }
                if store.session == nil {
                    Section {
                        Button { store.startSession(nil); showSession = true } label: {
                            Label("Start a gym session", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 16)).foregroundStyle(Theme.onAccent)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    }
                }
                Section {
                    Button { showActivity = true } label: { Label("Log a walk, run or class", systemImage: "figure.walk") }
                }
                let walked = Steps.shared.today
                if !store.todayWorkouts.isEmpty || walked != nil {
                    Section {
                        if let walked { walkingRow(walked) }
                        ForEach(keyed(store.todayWorkouts)) { entry in
                            let w = entry.item
                            NavigationLink { WorkoutDetail(workout: w, date: store.today) } label: { WorkoutRow(workout: w, date: nil) }
                                .swipeActions { Button(role: .destructive) { store.deleteWorkout(str(w["id"])) } label: { Label("Delete", systemImage: "trash") } }
                        }
                    } header: { Text("Today") } footer: {
                        if walked != nil { Text("Walking is counted from your steps and weight. It isn't a workout, so it doesn't add to your workout count, badges or budget.") }
                    }
                }
                if !store.routines.isEmpty {
                    Section("Your routines") {
                        ForEach(keyed(store.routines)) { entry in
                            let r = entry.item
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(str(r["name"])).font(.body.weight(.semibold))
                                    Text("\(list(r["exercises"]).count) exercises · tap play to start").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    guard store.session == nil else { showSession = true; return }
                                    store.startSession(r); showSession = true
                                } label: {
                                    Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.borderless)
                            }
                            .swipeActions { Button(role: .destructive) { store.deleteRoutine(str(r["id"])) } label: { Label("Delete", systemImage: "trash") } }
                        }
                    }
                }
                Section {
                    if let last = store.pastWorkouts.max(by: { $0.date < $1.date }) {
                        NavigationLink { PastWorkoutsView() } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Past workouts")
                                Text("Last: \(Store.when(last.date).capitalizedFirst) · \(str(last.workout["name"]))").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    NavigationLink { ExerciseBrowser() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All exercises")
                            Text("Your bests and the library").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Workouts")
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .refreshable { await store.sync(); await Steps.shared.refresh() }
            .task { await Steps.shared.refresh() }
            .navigationDestination(isPresented: $showSession) { SessionView() }
            .sheet(isPresented: $building) { PlanBuilder() }
            .sheet(isPresented: $showActivity) { ActivitySheet().presentationDetents([.medium, .large]) }
        }
    }

    private func liveCard(_ s: LiveSession) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "dumbbell.fill").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name.isEmpty ? "Gym session" : s.name).font(.headline)
                Text(s.looksForgotten && s.setsDone > 0 ? "Forgot to finish? Tap to wrap it up" : "\(s.setsDone) sets done · tap to carry on")
                    .font(.footnote).foregroundStyle(s.looksForgotten && s.setsDone > 0 ? Theme.warn : .secondary)
            }
            Spacer()
            Text(Date(timeIntervalSince1970: s.startedAt / 1000), style: .timer)
                .font(.title2.weight(.heavy)).monospacedDigit().foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 6)
    }

    private static func barFill(_ b: DayBar) -> LinearGradient {
        let all = b.kcal + b.walk, split = all > 0 ? b.kcal / all : 0
        let low = all > 0 ? Theme.accent : Theme.track, high = all > 0 ? Theme.walk : Theme.track
        return LinearGradient(stops: [.init(color: low, location: 0), .init(color: low, location: split), .init(color: high, location: split), .init(color: high, location: 1)], startPoint: .bottom, endPoint: .top)
    }

    private var weekCard: some View {
        let days = store.week
        let bars = days.map { d in DayBar(id: d.date, label: String(DayKey.date(d.date).formatted(.dateTime.weekday(.narrow))), kcal: d.kcal,
                                          walk: Steps.shared.kcal(on: d.date), today: d.date == store.today) }
        let total = days.reduce(0) { $0 + $1.kcal }, count = days.reduce(0) { $0 + $1.count }
        let walked = bars.reduce(0) { $0 + $1.walk }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week").font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(count) workout\(count == 1 ? "" : "s") · \(Fmt.int(total)) kcal").font(.subheadline).foregroundStyle(.secondary)
                    if walked > 0 { Text("+ walking \(Fmt.int(walked)) kcal").font(.subheadline).foregroundStyle(Theme.walk) }
                }
            }
            // one bar a day: workouts from the bottom, the walking share in green on top; an empty day keeps a small grey stub
            Chart(bars) { b in
                BarMark(x: .value("Day", b.id), y: .value("kcal", b.kcal + b.walk > 0 ? b.kcal + b.walk : 4))
                    .foregroundStyle(Self.barFill(b))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .chartXAxis {
                AxisMarks(values: bars.map(\.id)) { v in
                    AxisValueLabel { if let id = v.as(String.self), let b = bars.first(where: { $0.id == id }) { Text(b.today ? "Today" : b.label).fontWeight(b.today ? .bold : .regular) } }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 110)
            if walked > 0 {
                HStack(spacing: 14) {
                    key(Theme.accent, "Workouts")
                    key(Theme.walk, "Walking")
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func key(_ colour: Color, _ name: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(colour).frame(width: 9, height: 9)
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Today's walking: the steps Apple Health counted, as calories. Not a workout.
    private func walkingRow(_ steps: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.walk)
                .frame(width: 34, height: 34).background(Theme.walk.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Walking").font(.body.weight(.semibold))
                Text("\(steps.formatted()) steps · from Apple Health").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.int(Steps.shared.kcal(on: DayKey.string(Date())))).font(.body.weight(.bold)).monospacedDigit().foregroundStyle(Theme.walk)
        }
    }
}

/// Every past workout, newest first, by the month.
struct PastWorkoutsView: View {
    private var store: Store { Store.shared }

    var body: some View {
        List {
            ForEach(PastMonth.grouped(store.allPastWorkouts)) { m in
                Section {
                    ForEach(m.rows) { p in
                        NavigationLink { WorkoutDetail(workout: p.workout, date: p.date) } label: {
                            WorkoutRow(workout: p.workout, date: p.date, day: DayKey.date(p.date).formatted(.dateTime.weekday(.abbreviated).day()))
                        }
                    }
                } header: {
                    HStack {
                        Text(m.title).textCase(nil)
                        Spacer()
                        Text("\(m.rows.count) workout\(m.rows.count == 1 ? "" : "s") · \(Fmt.int(m.kcal)) kcal").textCase(nil).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Past workouts")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }
}

struct PastMonth: Identifiable {
    struct Row: Identifiable { let id: String; let date: String; let workout: JSON }
    let id: String   // 2026-10
    let rows: [Row]
    var kcal: Double { rows.reduce(0) { $0 + (num($1.workout["kcal"]) ?? 0) } }
    /// The month's name, with the year once it isn't this year's.
    var title: String {
        let thisYear = id.prefix(4) == DayKey.string(Date()).prefix(4), date = DayKey.date(id + "-01")
        return thisYear ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.month(.wide).year())
    }

    static func grouped(_ past: [(date: String, index: Int, workout: JSON)]) -> [PastMonth] {
        let rows = past.sorted { $0.date > $1.date }.map { Row(id: "\($0.date)-\($0.index)", date: $0.date, workout: $0.workout) }
        return Dictionary(grouping: rows) { String($0.date.prefix(7)) }
            .map { PastMonth(id: $0.key, rows: $0.value) }
            .sorted { $0.id > $1.id }
    }
}

struct WorkoutRow: View {
    let workout: JSON
    let date: String?
    var day: String? = nil   // how to show the date, where the month's already said
    var body: some View {
        let lifts = list(workout["lifts"])
        let sets = lifts.reduce(0) { $0 + max(list($1["detail"]).count, Int(num($1["sets"]) ?? 0)) }
        HStack(spacing: 12) {
            Image(systemName: Activities.symbol(lifts.isEmpty ? str(workout["type"]) : "Gym weights"))
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34).background(Theme.hero, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(str(workout["name"])).font(.body.weight(.semibold))
                Text([day ?? date.map { Store.when($0).capitalizedFirst },"\(Int(num(workout["minutes"]) ?? 0)) min",
                      lifts.isEmpty ? nil : "\(lifts.count) exercise\(lifts.count == 1 ? "" : "s") · \(sets) sets"].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.int(num(workout["kcal"]) ?? 0)).font(.body.weight(.bold)).monospacedDigit().foregroundStyle(Theme.accent)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// One finished workout: every exercise and set.
struct WorkoutDetail: View {
    let workout: JSON
    let date: String
    @State private var savedRoutine = false
    @State private var sharing = false
    private var store: Store { Store.shared }

    var body: some View {
        let lifts = list(workout["lifts"])
        List {
            Section {
                HStack {
                    stat("\(Int(num(workout["minutes"]) ?? 0))", "minutes")
                    stat(Fmt.int(num(workout["kcal"]) ?? 0), "kcal")
                    stat("\(lifts.count)", "exercises")
                }
            }
            ForEach(keyed(lifts)) { entry in
                let l = entry.item
                Section {
                    let detail = list(l["detail"])
                    if detail.isEmpty {
                        Text("\(Fmt.one(num(l["sets"]) ?? 0)) × \(Fmt.one(num(l["reps"]) ?? 0))\((num(l["kg"]) ?? 0) > 0 ? " @ \(Fmt.one(num(l["kg"]) ?? 0)) kg" : "")")
                    } else {
                        ForEach(detail.indices, id: \.self) { j in
                            HStack {
                                Text("Set \(j + 1)").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Fmt.one(num(detail[j]["reps"]) ?? 0)) reps").monospacedDigit()
                                if (num(detail[j]["kg"]) ?? 0) > 0 { Text("\(Fmt.one(num(detail[j]["kg"]) ?? 0)) kg").monospacedDigit().frame(width: 70, alignment: .trailing) }
                            }
                        }
                    }
                } header: {
                    NavigationLink { ExerciseDetail(name: str(l["exercise"])) } label: {
                        Text(str(l["exercise"])).font(.headline).foregroundStyle(.primary).textCase(nil)
                    }
                }
            }
            if !lifts.isEmpty {
                Section {
                    Button(savedRoutine ? "Saved as a routine" : "Save as a routine") {
                        store.saveRoutine(name: str(workout["name"]), exercises: lifts.map { ["exercise": $0["exercise"] ?? "", "sets": $0["sets"] ?? 3, "reps": $0["reps"] ?? 8, "kg": $0["kg"] ?? 0] as JSON })
                        savedRoutine = true
                    }
                    .disabled(savedRoutine)
                }
            }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") } } }
        .sheet(isPresented: $sharing) { ComposeSheet(preset: ComposeSheet.workoutPost(workout)) }
        .navigationTitle(str(workout["name"]))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(spacing: 2) { Text(v).font(.title2.weight(.heavy)).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }
}

/// A walk, run or class: type, minutes, effort.
struct ActivitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var type = "Walk"
    @State private var minutes = 30.0
    @State private var effort = "moderate"
    @State private var name = ""
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Activities.all.filter { !$0.lifting }, id: \.name) { a in
                                Button { type = a.name } label: {
                                    Label(a.name, systemImage: Activities.symbol(a.name)).font(.subheadline.weight(.bold))
                                        .padding(.horizontal, 12).padding(.vertical, 9)
                                        .background(type == a.name ? Theme.accent : Color(.tertiarySystemFill), in: Capsule())
                                        .foregroundStyle(type == a.name ? Theme.onAccent : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section("How long") {
                    Stepper("\(Int(minutes)) minutes", value: $minutes, in: 5...300, step: 5)
                    Picker("Effort", selection: $effort) {
                        Text("Easy").tag("easy"); Text("Moderate").tag("moderate"); Text("Hard").tag("hard")
                    }
                    .pickerStyle(.segmented)
                }
                Section { TextField("Name it (optional)", text: $name) } footer: {
                    Text("About \(Fmt.int(store.burn(type, minutes: minutes, effort: effort))) kcal. An estimate, like every tracker's.")
                }
            }
            .keyboardDone()
            .navigationTitle("Log an activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { store.logActivity(type: type, name: name.trimmingCharacters(in: .whitespaces), minutes: minutes, effort: effort); dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
    }
}
