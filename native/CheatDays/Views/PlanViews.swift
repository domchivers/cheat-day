import SwiftUI

/// The plan on Workouts: which week of the block, this week's days, and today's session with a Start button.
struct PlanCard: View {
    let plan: WorkoutPlan
    var start: (PlanSession) -> Void
    private var store: Store { Store.shared }

    var body: some View {
        let today = store.today, mon = WorkoutPlan.monday(today)
        let todays = plan.session(on: today), easy = plan.isDeload(on: today)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "Your plan · week \(plan.week(on: today)) of \(plan.weeks)\(easy ? " · easier week" : "")", color: easy ? Theme.warn : Theme.heroLabel)
                Text(plan.title).font(.headline)
            }
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { i in dayCell(DayKey.shift(mon, days: i)) }
            }
            if let t = todays, store.liftedOn(today) {
                Label("Today's \(t.name.lowercased()) is done. Nice.", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            } else if let t = todays {
                session(t, title: "Today: \(t.name)", prominent: true)
            } else if let n = plan.next(after: today) {
                session(n.session, title: "Rest day. Next: \(DayKey.date(n.date).formatted(.dateTime.weekday(.wide))), \(n.session.name)", prominent: false)
            }
        }
        .padding(.vertical, 6)
    }

    private func session(_ t: PlanSession, title: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.bold))
            Text("\(t.moves.count) exercises · about \(t.minutes) min · \(t.moves.prefix(3).map(\.exercise).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Group {
                if prominent {
                    Button { start(t) } label: { Label(store.session == nil ? "Start \(t.name)" : "Back to your session", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.borderedProminent).foregroundStyle(.black)
                } else {
                    Button { start(t) } label: { Label("Do \(t.name) today instead", systemImage: "play").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
            .buttonBorderShape(.roundedRectangle(radius: 12))
        }
    }

    private func dayCell(_ date: String) -> some View {
        let wd = DayKey.weekday(date), planned = plan.sessions.contains { $0.weekday == wd }
        let done = store.liftedOn(date), isToday = date == store.today, cheat = store.cheatWeekday == wd
        let fill: Color = done ? Color.green.opacity(0.28) : isToday ? Theme.accent : planned ? Theme.track : Color(.tertiarySystemFill).opacity(0.5)
        return VStack(spacing: 3) {
            Text(Calendar.current.veryShortWeekdaySymbols[wd]).font(.caption2.weight(.bold))
                .foregroundStyle(isToday && !done ? Color.black : Color.primary)
            Group {
                if done { Image(systemName: "checkmark").font(.caption2.weight(.heavy)).foregroundStyle(.green) }
                else if cheat { PizzaIcon(size: 11).scaleEffect(y: -1) }
                else if planned { Circle().fill(isToday ? Color.black : Theme.accent).frame(width: 5, height: 5) }
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

/// Build a plan: what it's for, days, time, kit, experience, muscles to bring up, and routines to keep.
struct PlanBuilder: View {
    @Environment(\.dismiss) private var dismiss
    @State private var goal = "muscle"
    @State private var days = 3
    @State private var minutes = 60
    @State private var kit = "gym"
    @State private var experience = "some"
    @State private var focus: Set<String> = []
    @State private var keep: Set<String> = []
    @State private var loaded = false
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    label("What's it for?")
                    ChoiceCard(title: "Build muscle", sub: "Moderate weights, 6–15 reps", symbol: "figure.strengthtraining.traditional", on: goal == "muscle") { goal = "muscle" }
                    ChoiceCard(title: "Get stronger", sub: "Heavier on the big lifts, 3–6 reps", symbol: "scalemass.fill", on: goal == "strength") { goal = "strength" }
                    ChoiceCard(title: "General fitness", sub: "Lighter, more reps, keeps you moving well", symbol: "heart.fill", on: goal == "fitness") { goal = "fitness" }
                    label("Days a week")
                    Picker("Days", selection: $days) { ForEach(1...6, id: \.self) { Text("\($0)").tag($0) } }.pickerStyle(.segmented)
                    label("Time per session")
                    Picker("Minutes", selection: $minutes) { ForEach([30, 45, 60, 75], id: \.self) { Text("\($0) min").tag($0) } }.pickerStyle(.segmented)
                    label("Where?")
                    Picker("Kit", selection: $kit) { Text("Full gym").tag("gym"); Text("Dumbbells").tag("dumbbells"); Text("No kit").tag("none") }.pickerStyle(.segmented)
                    label("How long have you been lifting?")
                    Picker("Experience", selection: $experience) { Text("New to it").tag("new"); Text("A year or two").tag("some"); Text("Years").tag("lots") }.pickerStyle(.segmented)
                    label("Want more of")
                    Flow {
                        ForEach(WorkoutPlanner.focusOptions, id: \.self) { f in
                            Chip(text: f, on: focus.contains(f)) { if focus.contains(f) { focus.remove(f) } else { focus.insert(f) } }
                        }
                    }
                    let mine = store.routines.filter { !list($0["exercises"]).isEmpty }
                    if !mine.isEmpty {
                        label("Start from what you already do")
                        VStack(spacing: 0) {
                            ForEach(mine.indices, id: \.self) { i in
                                let r = mine[i], id = str(r["id"])
                                Toggle(isOn: Binding(get: { keep.contains(id) }, set: { if $0 { keep.insert(id) } else { keep.remove(id) } })) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(str(r["name"]))
                                        Text("\(list(r["exercises"]).count) exercises").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 8)
                                if i < mine.count - 1 { Divider() }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        if !keep.isEmpty {
                            Text(keep.count >= days ? "Your routines fill every day." : "Your routines stay as they are. The other \(days - keep.count) day\(days - keep.count == 1 ? "" : "s") get filled with what they're missing.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if store.workoutPlan != nil {
                        Text("This replaces your current plan.").font(.footnote).foregroundStyle(Theme.warn).padding(.top, 6)
                    }
                    Button { build() } label: {
                        Text("Build my plan").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).foregroundStyle(.black).padding(.top, 10)
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("New workout plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if !loaded { prefill(); loaded = true } }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    }

    private func prefill() {
        let p = dict(store.doc["prefs"])
        if let plan = store.workoutPlan {
            goal = plan.goal; experience = plan.experience; kit = plan.kit; minutes = plan.minutes; focus = Set(plan.focus); days = plan.sessions.count
        } else {
            if let e = p["experience"] as? String { experience = e }
            if let k = p["kit"] as? String { kit = k }
            if let g = num(p["gymDays"]), g > 0 { days = Int(g) }
        }
    }

    private func build() {
        let kept = store.routines.filter { keep.contains(str($0["id"])) }
        let plan = WorkoutPlanner.build(goal: goal, days: days, experience: experience, kit: kit, minutes: minutes, focus: focus.sorted(), keep: kept, start: store.today)
        store.saveWorkoutPlan(plan)
        dismiss()
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
                Text(Training.note(plan.experience))
            }
            Section {
                Stepper("Block: \(plan.weeks) weeks", value: $plan.weeks, in: 4...12)
                Button("Start again from week 1") { plan.start = WorkoutPlan.monday(store.today) }
            } footer: {
                Text("You're in week \(plan.week(on: store.today)). The last week of each block is easier: about half the sets at 90% of the weight, so you recover and come back stronger.")
            }
            Section {
                Button { building = true } label: { Label("Build a new plan", systemImage: "wand.and.stars") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Stop using a plan", systemImage: "trash") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Your week")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onChange(of: plan) { _, now in if !now.sessions.isEmpty { store.saveWorkoutPlan(now) } }
        .sheet(isPresented: $building, onDismiss: { if let p = store.workoutPlan { plan = p } }) { PlanBuilder() }
        .confirmationDialog("Stop using this plan? Your logged workouts stay.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Stop using it", role: .destructive) { store.saveWorkoutPlan(nil); dismiss() }
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
