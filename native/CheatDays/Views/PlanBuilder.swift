import SwiftUI

/// Build a plan around whatever they do (25 Nov, design/plan-any-workout-mockup.html): what's in your week (any mix of
/// tiles, weights only one of them), a card for each asking only what fits it, then the week laid out with a coach's
/// word on clashes. It was weights-only: what it's for, days, time, kit, experience; those are now behind Set up weights.
struct PlanBuilder: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var picked: [String] = []           // PlanKinds ids
    @State private var acts: [PlanActivity] = []        // the non-weights ones, with their days
    @State private var liftDays: Set<Int> = []          // weights or Strong and steady days
    @State private var goal = "muscle"
    @State private var minutes = 45
    @State private var kit = "gym"
    @State private var experience = "some"
    @State private var focus: Set<String> = []
    @State private var keep: Set<String> = []
    @State private var settingUp = false
    @State private var loaded = false
    private var store: Store { Store.shared }

    private var lifting: Bool { picked.contains(PlanKinds.weights) }
    private var steady: Bool { picked.contains(PlanKinds.steady) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch step {
                    case 0: pickStep
                    case 1: setupStep
                    default: weekStep
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 30)
            }
            .background(Theme.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { bottomButton }
            .navigationTitle(step == 2 ? "Your week" : "New plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == 0 { Button("Cancel") { dismiss() } }
                    else { Button { withAnimation(.snappy) { step -= 1 } } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back") }
                }
            }
            .sheet(isPresented: $settingUp) { weightsSheet }
            .onAppear { if !loaded { prefill(); loaded = true } }
        }
    }

    // MARK: 1 what's in your week

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What's in your week?").font(.title2.weight(.heavy))
                Text("Pick everything you do, or want to start.").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(PlanKinds.all, id: \.id) { k in tile(k) }
            }
            Text("Not there? Add your own on the next screen.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 2)
        }
    }

    private func tile(_ k: PlanKinds.Kind) -> some View {
        let on: Bool = picked.contains(k.id)
        return Button { withAnimation(.snappy) { toggle(k.id) } } label: {
            VStack(spacing: 6) {
                Image(systemName: k.symbol).font(.title2).foregroundStyle(on ? Theme.accent : Color.primary).frame(height: 28)
                Text(k.id).font(.footnote.weight(.bold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 82).padding(.horizontal, 4)
            .background(on ? Theme.hero : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(k.id)
        .accessibilityAddTraits(on ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: on)
    }

    private func toggle(_ id: String) {
        if let i = picked.firstIndex(of: id) {
            picked.remove(at: i)
            acts.removeAll { $0.name.isEmpty && PlanKinds.kind(type: $0.type)?.id == id }
            if id == PlanKinds.weights || id == PlanKinds.steady { liftDays = [] }
            return
        }
        if id == PlanKinds.steady {
            picked.removeAll { $0 == PlanKinds.weights }
            liftDays = Set(Training.weekdays(2)); minutes = 30
            if kit == "gym" { kit = "none" }
        } else if id == PlanKinds.weights {
            picked.removeAll { $0 == PlanKinds.steady }
            if liftDays.isEmpty { liftDays = Set(Training.weekdays(3)) }
            if minutes == 30 { minutes = 45 }
            if kit == "band" { kit = "none" }
        }
        picked.append(id)
        if let k = PlanKinds.kind(id), let t = k.type {
            let taken: Set<Int> = liftDays.union(acts.flatMap(\.days))
            acts.append(PlanActivity(type: t, days: PlanKinds.freeDays(1, taken: taken), minutes: k.minutes, effort: k.effort))
        }
    }

    // MARK: 2 a card each

    private var setupStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lifting { liftCard(PlanKinds.weights) }
            if steady { liftCard(PlanKinds.steady) }
            ForEach($acts) { $a in ActivityCard(act: $a) { remove(a.id) } }
            Button {
                let taken: Set<Int> = liftDays.union(acts.flatMap(\.days))
                withAnimation(.snappy) { acts.append(PlanActivity(type: "Other", days: PlanKinds.freeDays(1, taken: taken), minutes: 45, effort: "moderate")) }
            } label: {
                Label("Add something else", systemImage: "plus.circle.fill").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        .padding(.top, 8)
    }

    private func remove(_ id: String) {
        withAnimation(.snappy) {
            if let a = acts.first(where: { $0.id == id }), a.name.isEmpty, let k = PlanKinds.kind(type: a.type),
               acts.filter({ $0.type == a.type }).count == 1 { picked.removeAll { $0 == k.id } }
            acts.removeAll { $0.id == id }
        }
    }

    /// Weights, or Strong and steady: its days, and the rest of its questions.
    private func liftCard(_ id: String) -> some View {
        let isSteady: Bool = id == PlanKinds.steady
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(id, systemImage: PlanKinds.kind(id)?.symbol ?? "dumbbell.fill").font(.headline)
                Spacer()
                Button { withAnimation(.snappy) { toggle(id) } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(id)")
            }
            DayChips(days: Binding(get: { liftDays }, set: { liftDays = $0 }), most: isSteady ? 3 : 6)
            if isSteady {
                Text("Any weights at home?").font(.subheadline.weight(.semibold))
                Picker("Weights", selection: $kit) { Text("None").tag("none"); Text("Light dumbbells").tag("dumbbells"); Text("A band").tag("band") }.pickerStyle(.segmented)
                Text(Training.steadyNote).font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Minutes", selection: $minutes) { ForEach([30, 45, 60, 75], id: \.self) { Text("\($0) min").tag($0) } }.pickerStyle(.segmented)
                Text(liftSummary).font(.footnote).foregroundStyle(.secondary)
                Button("Set up weights") { settingUp = true }.font(.subheadline.weight(.bold))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var liftSummary: String {
        let g: String = goal == "strength" ? "Get stronger" : goal == "fitness" ? "General fitness" : "Build muscle"
        let w: String = kit == "gym" ? "a full gym" : kit == "dumbbells" ? "dumbbells" : "no kit"
        let e: String = experience == "new" ? "new to it" : experience == "lots" ? "years of lifting" : "a year or two in"
        return "\(g) · \(w) · \(e)"
    }

    /// The weights questions, as they were: what it's for, where, how long lifting, muscles to bring up, routines to keep.
    private var weightsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    label("What's it for?")
                    ChoiceCard(title: "Build muscle", sub: "Moderate weights, 6–15 reps", symbol: "figure.strengthtraining.traditional", on: goal == "muscle") { goal = "muscle" }
                    ChoiceCard(title: "Get stronger", sub: "Heavier on the big lifts, 3–6 reps", symbol: "scalemass.fill", on: goal == "strength") { goal = "strength" }
                    ChoiceCard(title: "General fitness", sub: "Lighter, more reps, keeps you moving well", symbol: "heart.fill", on: goal == "fitness") { goal = "fitness" }
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
                    routinesToKeep
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Weights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingUp = false }.fontWeight(.bold) } }
        }
    }

    @ViewBuilder private var routinesToKeep: some View {
        let mine: [JSON] = store.routines.filter { !list($0["exercises"]).isEmpty }
        if !mine.isEmpty {
            label("Start from what you already do")
            VStack(spacing: 0) {
                ForEach(mine.indices, id: \.self) { i in
                    let r: JSON = mine[i], id: String = str(r["id"])
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
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    }

    // MARK: 3 your week

    private var plan: WorkoutPlan {
        var sessions: [PlanSession] = []
        if (lifting || steady) && !liftDays.isEmpty {
            let g: String = steady ? "steady" : goal
            let kept: [JSON] = steady ? [] : store.routines.filter { keep.contains(str($0["id"])) }
            sessions = WorkoutPlanner.build(goal: g, days: liftDays.count, experience: experience, kit: kit, minutes: steady ? 30 : minutes,
                                            focus: focus.sorted(), keep: kept, start: store.today, weekdays: Array(liftDays)).sessions
        }
        let named: [PlanActivity] = acts.filter { !$0.days.isEmpty && ($0.type != "Other" || !$0.name.trimmingCharacters(in: .whitespaces).isEmpty) }
        return WorkoutPlan(goal: steady ? "steady" : goal, experience: steady ? "new" : experience, kit: kit, minutes: steady ? 30 : minutes,
                           focus: steady ? [] : focus.sorted(), start: WorkoutPlan.monday(store.today), sessions: sessions, activities: named)
    }

    private var weekStep: some View {
        let p: WorkoutPlan = plan
        let tips: [String] = PlanKinds.tips(sessions: p.sessions, activities: p.activities)
        let fromActs: Double = p.activities.reduce(0) { (t: Double, a: PlanActivity) -> Double in t + store.burn(a.type, minutes: Double(a.minutes), effort: a.effort) * Double(a.days.count) }
        let fromLifts: Double = p.sessions.reduce(0) { (t: Double, s: PlanSession) -> Double in t + store.burn("Gym weights", minutes: Double(s.minutes), effort: "moderate") }
        let kcal: Double = fromActs + fromLifts
        let busy: Int = p.activeDays.count
        return VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { wd in
                    dayRow(wd, p)
                    if wd != 0 { Divider().padding(.leading, 58) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 8)
            ForEach(tips, id: \.self) { t in
                Label(t, systemImage: "lightbulb.fill").font(.footnote).foregroundStyle(Theme.warn)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text("\(busy) active day\(busy == 1 ? "" : "s"), \(7 - busy) rest. About \(Fmt.int(kcal)) kcal a week from it. To move something, go back and change its days.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 2)
            if store.workoutPlan != nil {
                Text("This replaces your current plan.").font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 2)
            }
        }
    }

    private func dayRow(_ wd: Int, _ p: WorkoutPlan) -> some View {
        let s: PlanSession? = p.sessions.first { $0.weekday == wd }
        let a: [PlanActivity] = p.activities.filter { $0.days.contains(wd) }
        return HStack(alignment: .top, spacing: 12) {
            Text(Calendar.current.shortWeekdaySymbols[wd]).font(.subheadline.weight(.heavy)).foregroundStyle(Theme.accent).frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if s == nil && a.isEmpty { Text("Rest").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                if let s {
                    item(p.goal == "steady" ? "chair.fill" : "dumbbell.fill", "\(p.goal == "steady" ? "Strong and steady" : "Weights") · \(s.name)",
                         "\(s.minutes) min · \(s.moves.count) exercises")
                }
                ForEach(a) { x in item(x.symbol, x.label, x.line) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func item(_ symbol: String, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.bold))
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: the button

    private var bottomButton: some View {
        let ready: Bool = step == 0 ? !picked.isEmpty : !(plan.sessions.isEmpty && plan.activities.isEmpty)
        let title: String = step == 0 ? "Next" : step == 1 ? "See my week" : "Start this plan"
        return Button {
            if step < 2 { withAnimation(.snappy) { step += 1 } } else { save() }
        } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).foregroundStyle(Theme.onAccent)
        .disabled(!ready)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Theme.bg)
    }

    private func save() {
        let p: WorkoutPlan = plan
        store.saveWorkoutPlan(p)
        // runs and classes a watch saves to Apple Health tick themselves off: ask to read workouts (once)
        if !p.activities.isEmpty && HealthSync.available {
            Task { await HealthSync.askWorkouts(); await HealthSync.tickPlan() }
        }
        dismiss()
    }

    // MARK: starting from what they have

    private func prefill() {
        let p: JSON = dict(store.doc["prefs"])
        if let old = store.workoutPlan {
            goal = old.goal == "steady" ? "muscle" : old.goal; experience = old.experience; kit = old.kit; minutes = old.minutes; focus = Set(old.focus)
            if !old.sessions.isEmpty {
                picked.append(old.goal == "steady" ? PlanKinds.steady : PlanKinds.weights)
                liftDays = Set(old.sessions.map(\.weekday))
            }
            acts = old.activities
            for a in old.activities { if let k = PlanKinds.kind(type: a.type), !picked.contains(k.id) { picked.append(k.id) } }
            return
        }
        if let e = p["experience"] as? String { experience = e }
        if let k = p["kit"] as? String { kit = k }
        let days: Int = Int(num(p["gymDays"]) ?? 0)
        if p["steady"] as? Bool == true, days > 0 { toggle(PlanKinds.steady) }
        else if days > 0 { toggle(PlanKinds.weights); liftDays = Set(Training.weekdays(min(6, days))) }
        // sign-up's other picks (old names too: Running, Yoga, Sport…)
        let old: [String: String] = ["Running": "Running", "Cycling": "Cycling", "Swimming": "Swimming", "Classes": "Classes / HIIT", "Sport": "Team sport", "Yoga": "Yoga / Pilates"]
        for e in (p["extras"] as? [String] ?? []) {
            let id: String = old[e] ?? e
            if id != "Walking", PlanKinds.kind(id) != nil, !picked.contains(id) { toggle(id) }
        }
        if !steady && kit == "band" { kit = "none" }
    }
}

/// One non-weights thing in the plan: what (named, for Other), its days, how long and how hard.
private struct ActivityCard: View {
    @Binding var act: PlanActivity
    var remove: () -> Void
    private var store: Store { Store.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: act.symbol).font(.headline).foregroundStyle(Theme.accent)
                if act.type == "Other" {
                    TextField("What is it?", text: $act.name).font(.headline)
                } else {
                    Text(PlanKinds.kind(type: act.type)?.id ?? act.type).font(.headline)
                }
                Spacer()
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(act.label)")
            }
            DayChips(days: Binding(get: { Set(act.days) }, set: { act.days = Array($0).sorted() }), most: 7)
            if act.type == "Run" {
                // what it's for (25 Nov, design/start-running-mockup.html)
                HStack(spacing: 6) {
                    aimChip("Keep it up", "")
                    aimChip("Start running", "start")
                }
            }
            if act.startRunning {
                startWeeks
            } else {
                Stepper("\(act.minutes) min", value: $act.minutes, in: 10...240, step: 5).font(.subheadline.weight(.semibold))
                Picker("Effort", selection: $act.effort) { Text("Easy").tag("easy"); Text("Moderate").tag("moderate"); Text("Hard").tag("hard") }.pickerStyle(.segmented)
                Text("About \(Fmt.int(store.burn(act.type, minutes: Double(act.minutes), effort: act.effort))) kcal each time."
                     + (HealthSync.ticks(act.type) ? " One your watch saves to Apple Health ticks it off on its own." : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func aimChip(_ title: String, _ aim: String) -> some View {
        let on: Bool = act.aim == aim
        return Button {
            withAnimation(.snappy) {
                act.aim = aim
                if aim == "start" {
                    act.effort = "easy"; act.minutes = RunStart.minutes(week: store.startRun.week)
                    if act.days.count < 3 { act.days = [2, 4, 6] }   // three a week, a day apart
                }
            }
        } label: {
            Text(title).font(.footnote.weight(.bold)).padding(.horizontal, 11).padding(.vertical, 6)
                .background(on ? Theme.accent : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? Theme.onAccent : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The 8 weeks Start running builds through, the one they're on marked.
    private var startWeeks: some View {
        let now: Int = store.startRun.week
        return VStack(alignment: .leading, spacing: 6) {
            Text("Run and walk, building to 30 minutes without stopping over 8 weeks. Each run starts and ends with 5 minutes' walking, and the app times every switch for you.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(1...RunStart.lastWeek, id: \.self) { w in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Week \(w)").font(.caption.weight(.heavy)).foregroundStyle(Theme.accent).frame(width: 52, alignment: .leading)
                    Text(RunStart.middle(week: w)).font(.caption).foregroundStyle(w == now ? Color.primary : .secondary)
                    if w == now && store.startRunsDone > 0 { Text("you're here").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent) }
                }
            }
            Text("Too hard? Repeat a week: the app only moves on when you've done three runs of it.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The week's days as chips, Monday first; at least one stays on, and no more than `most`.
struct DayChips: View {
    @Binding var days: Set<Int>
    var most: Int = 7

    var body: some View {
        HStack(spacing: 5) {
            ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                let on: Bool = days.contains(d)
                Button {
                    if on { if days.count > 1 { days.remove(d) } } else if days.count < most { days.insert(d) }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[d]).font(.footnote.weight(.bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(on ? Theme.accent : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(on ? Theme.onAccent : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[d])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
