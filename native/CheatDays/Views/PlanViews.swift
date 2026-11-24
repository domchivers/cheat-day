import SwiftUI

/// The plan on Workouts: which week of the block, this week's days, and today's session with a Start button.
struct PlanCard: View {
    let plan: WorkoutPlan
    var start: (PlanSession) -> Void
    /// Log a planned run, class or match: Log an activity, filled in (25 Nov).
    var log: (PlanActivity) -> Void = { _ in }
    private var store: Store { Store.shared }

    var body: some View {
        let today: String = store.today, mon: String = WorkoutPlan.monday(today)
        let todays: PlanSession? = plan.session(on: today), acts: [PlanActivity] = plan.activities(on: today)
        let easy: Bool = !plan.sessions.isEmpty && plan.isDeload(on: today)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: plan.sessions.isEmpty ? "Your plan" : "Your plan · week \(plan.week(on: today)) of \(plan.weeks)\(easy ? " · easier week" : "")",
                        color: easy ? Theme.warn : Theme.heroLabel)
                Text(plan.title).font(.headline)
            }
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { i in dayCell(DayKey.shift(mon, days: i)) }
            }
            if let t = todays, store.liftedOn(today) {
                Label("Today's \(t.name.lowercased()) is done. Nice.", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            } else if let t = todays {
                session(t, title: "Today: \(t.name)", prominent: true)
            }
            ForEach(acts) { a in activity(a, prominent: todays == nil) }
            if todays == nil && acts.isEmpty, let n = plan.nextDay(after: today) {
                restDay(n)
            }
            if plan.activities.contains(where: { HealthSync.ticks($0.type) }) && HealthSync.available && !HealthSync.workoutsAsked && !askedHealth {
                Button {
                    askedHealth = true
                    Task { await HealthSync.askWorkouts(); await HealthSync.tickPlan() }
                } label: { Label("Tick these off from Apple Health", systemImage: "heart.fill").font(.footnote.weight(.semibold)) }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
    }

    /// Asked to read workouts from Apple Health, this time round (the setting itself isn't watched).
    @State private var askedHealth = false

    @ViewBuilder private func restDay(_ n: (date: String, session: PlanSession?, activities: [PlanActivity])) -> some View {
        let day: String = DayKey.date(n.date).formatted(.dateTime.weekday(.wide))
        if let s = n.session {
            session(s, title: "Rest day. Next: \(day), \(s.name)", prominent: false)
        } else {
            Text("Rest day. Next: \(day), \(n.activities.map { $0.label.lowercased() }.joined(separator: " and "))").font(.subheadline.weight(.bold))
        }
    }

    /// Today's run, class or match: done once one of its kind is logged today, or Log it.
    @ViewBuilder private func activity(_ a: PlanActivity, prominent: Bool) -> some View {
        if done(a, on: store.today) {
            Label("Today's \(a.label.lowercased()) is done\(doneDetail(a)). Nice.", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Today: \(a.label)", systemImage: a.symbol).font(.subheadline.weight(.bold))
                Text("\(a.line) · about \(Fmt.int(store.burn(a.type, minutes: Double(a.minutes), effort: a.effort))) kcal").font(.caption).foregroundStyle(.secondary)
                Group {
                    if prominent {
                        Button { log(a) } label: { Label("Log it", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4) }
                            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                    } else {
                        Button { log(a) } label: { Label("Log it", systemImage: "checkmark").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    }
                }
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }
        }
    }

    /// ": 34 min, 5.1 km" from the one logged today (a watch's, from Apple Health, has the distance).
    private func doneDetail(_ a: PlanActivity) -> String {
        guard let w = store.workouts(on: store.today).first(where: { str($0["type"]) == a.type }), let m = num(w["minutes"]), m > 0 else { return "" }
        let km: String = num(w["km"]).map { ", \(Fmt.one($0)) km" } ?? ""
        return ": \(Int(m)) min" + km
    }

    /// One of its kind logged that day (any activity, for one of their own).
    private func done(_ a: PlanActivity, on date: String) -> Bool {
        store.workouts(on: date).contains { (w: JSON) -> Bool in a.type == "Other" ? list(w["lifts"]).isEmpty : str(w["type"]) == a.type }
    }

    private func session(_ t: PlanSession, title: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.bold))
            Text("\(t.moves.count) exercises · about \(t.minutes) min · \(t.moves.prefix(3).map(\.exercise).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Group {
                if prominent {
                    Button { start(t) } label: { Label(store.session == nil ? "Start \(t.name)" : "Back to your session", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                } else {
                    Button { start(t) } label: { Label("Do \(t.name) today instead", systemImage: "play").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
            .buttonBorderShape(.roundedRectangle(radius: 12))
        }
    }

    private func dayCell(_ date: String) -> some View {
        let wd: Int = DayKey.weekday(date), acts: [PlanActivity] = plan.activities(on: date)
        let lifts: Bool = plan.sessions.contains { $0.weekday == wd }, planned: Bool = lifts || !acts.isEmpty
        let actsDone: Bool = !acts.isEmpty && acts.allSatisfy { done($0, on: date) } && (!lifts || store.liftedOn(date))
        let done: Bool = (store.liftedOn(date) && acts.isEmpty) || actsDone
        let isToday: Bool = date == store.today, cheat: Bool = store.cheatWeekday == wd
        let fill: Color = done ? Color.green.opacity(0.28) : isToday ? Theme.accent : planned ? Theme.track : Color(.tertiarySystemFill).opacity(0.5)
        return VStack(spacing: 3) {
            Text(Calendar.current.veryShortWeekdaySymbols[wd]).font(.caption2.weight(.bold))
                .foregroundStyle(isToday && !done ? Theme.onAccent : Color.primary)
            Group {
                if done { Image(systemName: "checkmark").font(.caption2.weight(.heavy)).foregroundStyle(.green) }
                else if cheat { PizzaIcon(size: 11).scaleEffect(y: -1) }
                else if let a = acts.first, !lifts { Image(systemName: a.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(isToday ? Theme.onAccent : Theme.accent) }
                else if planned { Circle().fill(isToday ? Theme.onAccent : Theme.accent).frame(width: 5, height: 5) }
                else { Color.clear.frame(width: 5, height: 5) }
            }
            .frame(height: 11)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Sets done this week against what the plan has, for each muscle.
struct VolumeRows: View {
    let plan: WorkoutPlan
    private var store: Store { Store.shared }

    var body: some View {
        let planned = plan.volume, done = store.setsThisWeek
        let groups = Muscles.shown.filter { (planned[$0] ?? 0) > 0 }
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Hard sets this week")
            ForEach(groups, id: \.self) { g in
                let p = planned[g] ?? 0, d = done[g] ?? 0
                VStack(spacing: 3) {
                    HStack {
                        Text(g).font(.footnote)
                        Spacer()
                        Text("\(d) / \(p)").font(.footnote.weight(.bold)).monospacedDigit().foregroundStyle(d >= p ? Color.green : .secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(d >= p ? Color.green : Theme.accent).frame(width: geo.size.width * min(1, Double(d) / Double(max(1, p))))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Edit the week: drag days into a new order, open a day to swap moves, change sets and reps.
struct PlanEditor: View {
    @State private var plan: WorkoutPlan
    @State private var building = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    init() {
        _plan = State(initialValue: Store.shared.workoutPlan ?? WorkoutPlan(goal: "muscle", experience: "some", kit: "gym", minutes: 60, focus: [], start: WorkoutPlan.monday(Store.shared.today), sessions: []))
    }

    var body: some View {
        List {
            if !plan.activities.isEmpty {
                // runs, classes and matches (25 Nov): their days and times are changed in the plan builder
                Section {
                    ForEach(plan.activities) { a in
                        HStack(spacing: 12) {
                            Image(systemName: a.symbol).font(.headline).foregroundStyle(Theme.accent).frame(width: 40, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.label).font(.headline)
                                Text("\(a.dayNames) · \(a.line)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { plan.activities.remove(atOffsets: $0) }
                } header: {
                    Text("Also in your week")
                }
            }
            if !plan.sessions.isEmpty { liftSections }
            Section {
                Button { building = true } label: { Label("Change what's in your week", systemImage: "wand.and.stars") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Stop using a plan", systemImage: "trash") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Your week")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onChange(of: plan) { _, now in if !now.sessions.isEmpty || !now.activities.isEmpty { store.saveWorkoutPlan(now) } }
        .sheet(isPresented: $building, onDismiss: { if let p = store.workoutPlan { plan = p } }) { PlanBuilder() }
        .confirmationDialog("Stop using this plan? Your logged workouts stay.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Stop using it", role: .destructive) { store.saveWorkoutPlan(nil); dismiss() }
        }
    }

    /// The weights (or Strong and steady) days, and the block they repeat in.
    @ViewBuilder private var liftSections: some View {
            Section {
                ForEach(plan.sessions) { s in
                    NavigationLink { PlanDayEditor(plan: $plan, id: s.id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(Calendar.current.shortWeekdaySymbols[s.weekday]).font(.subheadline.weight(.heavy)).foregroundStyle(Theme.accent).frame(width: 40, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.headline)
                                Text(s.moves.map(\.exercise).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                .onMove { from, to in
                    let days = plan.sessions.map(\.weekday)
                    plan.sessions.move(fromOffsets: from, toOffset: to)
                    for i in plan.sessions.indices { plan.sessions[i].weekday = days[i] }   // the days stay put; the sessions swap
                }
            } header: {
                Text("Tap Edit to drag sessions to other days")
            } footer: {
                Text(plan.goal == "steady" ? Training.steadyNote : Training.note(plan.experience))
            }
            Section {
                Stepper("Block: \(plan.weeks) weeks", value: $plan.weeks, in: 4...12)
                Button("Start again from week 1") { plan.start = WorkoutPlan.monday(store.today) }
            } footer: {
                Text("You're in week \(plan.week(on: store.today)). The last week of each block is easier: about half the sets at 90% of the weight, so you recover and come back stronger.")
            }
    }
}

/// One day of the plan: its name and weekday, and each move with a swap menu, sets and rep range.
struct PlanDayEditor: View {
    @Binding var plan: WorkoutPlan
    let id: String
    @State private var picking = false

    private var index: Int? { plan.sessions.firstIndex { $0.id == id } }

    var body: some View {
        List {
            if let i = index {
                Section {
                    TextField("Name", text: $plan.sessions[i].name).font(.headline)
                    Picker("Day", selection: Binding(get: { plan.sessions[i].weekday }, set: { setDay($0) })) {
                        ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in Text(Calendar.current.weekdaySymbols[d]).tag(d) }
                    }
                }
                Section {
                    ForEach($plan.sessions[i].moves) { $m in moveRow($m) }
                        .onDelete { plan.sessions[i].moves.remove(atOffsets: $0) }
                        .onMove { plan.sessions[i].moves.move(fromOffsets: $0, toOffset: $1) }
                    Button { picking = true } label: { Label("Add an exercise", systemImage: "plus.circle.fill") }
                } header: {
                    Text("Exercises")
                } footer: {
                    Text("Work in the rep range at one weight. When every set reaches the top, the app moves the weight up next time.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .keyboardDone()
        .navigationTitle(index.map { plan.sessions[$0].name } ?? "Day")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $picking) {
            ExercisePicker(inSession: Set(index.map { plan.sessions[$0].moves.map { $0.exercise.lowercased() } } ?? [])) { picked in
                guard let i = index else { return }
                let r = WorkoutPlanner.ranges(goal: plan.goal, compound: false)
                plan.sessions[i].moves += picked.map { PlanMove(exercise: $0.name, sets: 3, low: r.0, high: r.1) }
            }
        }
    }

    private func moveRow(_ m: Binding<PlanMove>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(m.wrappedValue.exercise).font(.headline)
                Spacer()
                let alts = alternatives(m.wrappedValue.exercise)
                if !alts.isEmpty {
                    Menu {
                        ForEach(alts, id: \.self) { a in Button(a) { m.wrappedValue.exercise = a } }
                    } label: {
                        Label("Swap", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
            }
            if plan.goal == "steady", let how = Training.how(m.wrappedValue.exercise, kit: plan.kit) {
                Text(how).font(.footnote).foregroundStyle(.secondary)
            }
            Stepper("\(m.wrappedValue.sets) sets", value: m.sets, in: 1...8).font(.subheadline)
            Stepper("\(m.wrappedValue.low)–\(m.wrappedValue.high) reps", onIncrement: {
                if m.wrappedValue.high < 30 { m.wrappedValue.low += 1; m.wrappedValue.high += 1 }
            }, onDecrement: {
                if m.wrappedValue.low > 1 { m.wrappedValue.low -= 1; m.wrappedValue.high -= 1 }
            }).font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    /// Other moves for the same muscle.
    private func alternatives(_ name: String) -> [String] {
        guard let g = Muscles.group(name), let all = ExerciseLibrary.groups.first(where: { $0.0 == g })?.1 else { return [] }
        return all.filter { $0.lowercased() != name.lowercased() }
    }

    /// Moving a day onto one that's taken swaps the two.
    private func setDay(_ d: Int) {
        guard let i = index else { return }
        let old = plan.sessions[i].weekday
        if let j = plan.sessions.firstIndex(where: { $0.weekday == d && $0.id != id }) { plan.sessions[j].weekday = old }
        plan.sessions[i].weekday = d
        plan.sort()
    }
}
