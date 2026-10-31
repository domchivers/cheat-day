import SwiftUI
import UserNotifications

/// A live gym session: tick sets as you go, the rest timer starts on its own, drag exercises into any order.
struct SessionView: View {
    @State private var s: LiveSession
    @State private var reordering = false
    @State private var picking = false
    @State private var confirmDiscard = false
    @State private var finishing = false
    @State private var minutesText = ""
    @State private var banner: String?
    @State private var restOver = 0
    @State private var finished = false
    @State private var routineOffer: JSON?
    @State private var askShare: JSON?
    @State private var routineUpdate: RoutineUpdate?
    /// A session started from a routine that came out different: what changed, to ask whether the routine follows.
    struct RoutineUpdate { let routine: JSON; let name: String; let exercises: [JSON]; let changes: [String]; let workout: JSON }
    @State private var forgotten = false
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    init(sample: LiveSession? = nil) {
        _s = State(initialValue: sample ?? Store.shared.session ?? LiveSession(startedAt: Double(nowMs()), name: "", routineId: nil, exercises: []))
    }

    private var nextSetId: UUID? { s.next.map { s.exercises[$0.ex].sets[$0.set].id } }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Gym session", text: $s.name).font(.title3.bold())
                    Text(Date(timeIntervalSince1970: s.startedAt / 1000), style: .timer)
                        .font(.title3.weight(.heavy)).monospacedDigit().foregroundStyle(Theme.accent)
                }
                restRow
            }
            if reordering {
                Section {
                    ForEach(s.exercises) { e in Label(e.name.isEmpty ? "Exercise" : e.name, systemImage: "dumbbell") }
                        .onMove { s.exercises.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { s.exercises.remove(atOffsets: $0) }
                } header: { Text("Drag to reorder, then tap Done") }
            } else {
                ForEach($s.exercises) { $e in exerciseSection($e) }
            }
            Section {
                Button { picking = true } label: { Label("Add an exercise", systemImage: "plus.circle.fill") }
            } footer: {
                Text(s.setsDone == 0 ? "Tick each set as you finish it; the rest timer starts on its own. Change a weight and the sets after it follow."
                                     : "\(s.setsDone) set\(s.setsDone == 1 ? "" : "s") done\(s.volume > 0 ? " · \(Fmt.int(s.volume)) kg lifted" : "")")
            }
        }
        .environment(\.editMode, .constant(reordering ? .active : .inactive))
        // pinned to the bottom whatever the keyboard does: the list ignores the keyboard and makes its own room, as
        // after a lock with the keyboard up the keyboard's safe area could be left behind with the bar mid-screen
        .accessibilityIdentifier("sessionList")
        .overlay(alignment: .bottom) { timerBar }
        .keyboardRoom(76)
        .scrollDismissesKeyboard(.interactively)
        .keyboardDone()
        .cursorAtEnd()
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // while reordering the only button is Done, so Finish can't be pressed by mistake to end the reorder
            if reordering {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { withAnimation { reordering = false } }.fontWeight(.bold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { withAnimation { reordering = true } } label: { Label("Reorder exercises", systemImage: "arrow.up.arrow.down") }
                        Button(role: .destructive) { confirmDiscard = true } label: { Label("Discard session", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Finish") { prepareFinish() }.fontWeight(.bold)
                }
            }
        }
        .sheet(isPresented: $picking) {
            ExercisePicker(inSession: Set(s.exercises.map { $0.name.lowercased() })) { picked in s.exercises.append(contentsOf: picked) }
        }
        .onChange(of: s) { _, now in if !finished { store.saveSession(now) } }
        .sensoryFeedback(.success, trigger: s.setsDone)
        .sensoryFeedback(.warning, trigger: restOver)
        .overlay(alignment: .top) {
            if let banner {
                Text(banner).font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            // the rest ending: a tap you feel and a note; the lock screen already counts it down
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let r = s.restUntil, Double(nowMs()) >= r {
                    s.restUntil = nil
                    restOver += 1
                    show("Rest's over: next set")
                }
            }
        }
        .alert("Finish the workout", isPresented: $finishing) {
            TextField("Minutes", text: $minutesText).keyboardType(.numberPad)
            Button("Finish") { finish() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("How many minutes did it take? Change it if the timer ran on.\(s.startedDay < store.today ? " It'll be saved to \(DayKey.date(s.startedDay).formatted(.dateTime.weekday(.wide))), the day you started." : "")")
        }
        .confirmationDialog("Discard this session? Nothing will be logged.", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { finished = true; Self.cancelIdleReminder(); store.saveSession(nil); dismiss() }
        }
        .confirmationDialog("Save this as a routine, to start it again next time?", isPresented: Binding(get: { routineOffer != nil }, set: { if !$0, let w = routineOffer { routineOffer = nil; offerShare(w) } }), titleVisibility: .visible) {
            Button("Save as a routine") {
                if let w = routineOffer {
                    store.saveRoutine(name: str(w["name"]), exercises: list(w["lifts"]).map { ["exercise": $0["exercise"] ?? "", "sets": $0["sets"] ?? 3, "reps": $0["reps"] ?? 8, "kg": $0["kg"] ?? 0] as JSON })
                }
                let w = routineOffer; routineOffer = nil; offerShare(w)
            }
            Button("Not now", role: .cancel) { let w = routineOffer; routineOffer = nil; offerShare(w) }
        }
        .confirmationDialog("You changed \(str(routineUpdate?.routine["name"])) today", isPresented: Binding(get: { routineUpdate != nil }, set: { if !$0, let u = routineUpdate { routineUpdate = nil; offerShare(u.workout) } }), titleVisibility: .visible) {
            Button("Update the routine") {
                if let u = routineUpdate { store.updateRoutine(u.routine, name: u.name, exercises: u.exercises) }
                let w = routineUpdate?.workout; routineUpdate = nil; offerShare(w)
            }
            Button("Save as a new routine") {
                if let u = routineUpdate {
                    let old = str(u.routine["name"])
                    store.saveRoutine(name: u.name.lowercased() == old.lowercased() ? "\(old) 2" : u.name, exercises: u.exercises)
                }
                let w = routineUpdate?.workout; routineUpdate = nil; offerShare(w)
            }
            Button("Keep it as it was", role: .cancel) { let w = routineUpdate?.workout; routineUpdate = nil; offerShare(w) }
        } message: { Text((routineUpdate?.changes ?? []).joined(separator: "\n")) }
        .confirmationDialog("Show your workouts on the feed?", isPresented: Binding(get: { askShare != nil }, set: { if !$0 && askShare != nil { answerShare(false) } }), titleVisibility: .visible) {
            Button("Yes, show them") { answerShare(true) }
            Button("No, keep them to myself", role: .cancel) { answerShare(false) }
        } message: { Text("Friends would see each workout you finish and can react or do the same one. You can change this in Settings.") }
        .sheet(isPresented: $forgotten) {
            ForgotToFinish(session: $s) { minutes in
                forgotten = false
                minutesText = String(minutes)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { finish() }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear { if s.looksForgotten && s.setsDone > 0 { forgotten = true } }
    }

    // MARK: the bar that stays on screen

    private var timerBar: some View {
        HStack(spacing: 12) {
            Text(Date(timeIntervalSince1970: s.startedAt / 1000), style: .timer)
                .font(.headline.weight(.heavy)).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            if let r = s.restUntil, r > Double(nowMs()) {
                Text("Rest").font(.subheadline.weight(.bold))
                Text(timerInterval: Date()...Date(timeIntervalSince1970: r / 1000), countsDown: true)
                    .font(.title2.weight(.heavy)).monospacedDigit().foregroundStyle(Theme.accent)
                Button("+15") { nudge(15) }.buttonStyle(.bordered).controlSize(.small)
                Button("Skip") { s.restUntil = nil }.buttonStyle(.borderedProminent).controlSize(.small).foregroundStyle(Theme.onAccent)
            } else if let n = s.next {
                Text("Next: \(s.exercises[n.ex].name.isEmpty ? "Exercise" : s.exercises[n.ex].name) · set \(n.set + 1)")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
            } else {
                Text("All sets done").font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain).accessibilityIdentifier("timerBar")
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    // MARK: rest

    @ViewBuilder private var restRow: some View {
        if let r = s.restUntil, r > Double(nowMs()) {
            HStack(spacing: 8) {
                Text("Rest").font(.headline)
                Text(timerInterval: Date()...Date(timeIntervalSince1970: r / 1000), countsDown: true)
                    .font(.title2.weight(.heavy)).monospacedDigit().foregroundStyle(Theme.accent)
                Spacer()
                Button("−15") { nudge(-15) }
                Button("+15") { nudge(15) }
                Button("Skip") { s.restUntil = nil }
            }
            .buttonStyle(.bordered)
            .listRowBackground(Theme.hero)
        } else {
            Stepper("Rest between sets \(mmss(store.restSeconds))", onIncrement: { store.setRest(store.restSeconds + 15) }, onDecrement: { store.setRest(store.restSeconds - 15) })
        }
    }

    private func nudge(_ seconds: Double) {
        guard let r = s.restUntil else { return }
        s.restUntil = max(Double(nowMs()) + 1000, r + seconds * 1000)
    }

    private func mmss(_ sec: Int) -> String { "\(sec / 60):\(String(format: "%02d", sec % 60))" }

    // MARK: exercises

    @ViewBuilder
    private func exerciseSection(_ e: Binding<LiveExercise>) -> some View {
        let ex = e.wrappedValue
        Section {
            if let t = planTarget(ex.name) {
                Label(t.hint, systemImage: t.up ? "arrow.up.right.circle.fill" : "target")
                    .font(.footnote).foregroundStyle(t.up ? Color.green : .secondary).opacity(ex.complete ? 0.55 : 1)
            } else {
                Text(store.lastLine(ex.name)).font(.footnote).foregroundStyle(.secondary).opacity(ex.complete ? 0.55 : 1)
            }
            ForEach(e.sets) { $set in
                let j = ex.sets.firstIndex { $0.id == set.id } ?? 0
                SetRow(set: $set, label: "Set \(j + 1)", isNext: set.id == nextSetId,
                       onTick: { tick(ex.id, set.id) },
                       onEdit: { field, old, new in flowDown(ex.id, after: j, field: field, old: old, new: new) })
            }
            HStack(spacing: 22) {
                Button { addSet(ex.id) } label: { Label("Set", systemImage: "plus") }.buttonStyle(.borderless)
                if ex.sets.count > 1 {
                    Button { removeSet(ex.id) } label: { Label("Set", systemImage: "minus") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.semibold))
        } header: {
            HStack(spacing: 8) {
                TextField("Exercise", text: e.name).font(.headline).foregroundStyle(.primary).textCase(nil)
                    .strikethrough(ex.complete)
                if ex.complete {
                    Text("✓ Done").font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.hero, in: Capsule()).foregroundStyle(Theme.accent).textCase(nil)
                }
                Menu {
                    Button(role: .destructive) { s.exercises.removeAll { $0.id == ex.id } } label: { Label("Remove exercise", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis").font(.headline).padding(6) }
            }
        }
    }

    /// In a session from the plan: this exercise's target and why.
    private func planTarget(_ name: String) -> Target? {
        guard let rid = s.routineId, rid.hasPrefix("plan:"), let plan = store.workoutPlan,
              let ps = plan.sessions.first(where: { "plan:\($0.id)" == rid }),
              let m = ps.moves.first(where: { $0.exercise.lowercased() == name.lowercased() }) else { return nil }
        return Progression.target(m, last: store.lastSets(m.exercise), deload: plan.isDeload(on: store.today))
    }

    /// A reminder 35 minutes after the last ticked set, replaced with each tick; gone once the session ends.
    static func remindIfIdle() {
        let c = UNMutableNotificationContent()
        c.title = "Still training?"
        c.body = "Nothing's been ticked for a while. Open Cheat Days to finish your workout with the right time."
        let req = UNNotificationRequest(identifier: "workout.idle", content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 35 * 60, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }
    static func cancelIdleReminder() { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["workout.idle"]) }

    private func index(_ id: UUID) -> Int? { s.exercises.firstIndex { $0.id == id } }

    private func tick(_ exId: UUID, _ setId: UUID) {
        guard let i = index(exId), let j = s.exercises[i].sets.firstIndex(where: { $0.id == setId }) else { return }
        var set = s.exercises[i].sets[j]
        set.done.toggle(); set.pb = false
        if set.done {
            s.lastAt = Double(nowMs())
            Self.remindIfIdle()
            if set.reps <= 0 { set.reps = 1 }
            s.restUntil = Double(nowMs() + store.restSeconds * 1000)
            let name = s.exercises[i].name
            let prev = num(store.exercise(name)?["best1rm"]) ?? 0
            let e1 = Store.est(kg: set.kg, reps: set.reps)
            let sessionBest = s.exercises.filter { $0.name.lowercased() == name.lowercased() }.flatMap(\.sets)
                .filter { $0.pb && $0.id != setId }.map { Store.est(kg: $0.kg, reps: $0.reps) }.max() ?? 0
            if prev > 0, e1 > max(prev, sessionBest) {
                set.pb = true
                show("New best for \(name): \(Fmt.kg(set.kg)) kg × \(Fmt.one(set.reps))")
            }
        }
        withAnimation(.snappy) { s.exercises[i].sets[j] = set }
    }

    /// A changed weight or rep count carries on to the later sets that still had the old number.
    private func flowDown(_ exId: UUID, after j: Int, field: String, old: Double, new: Double) {
        guard let i = index(exId) else { return }
        for k in s.exercises[i].sets.indices where k > j && !s.exercises[i].sets[k].done {
            if field == "reps", s.exercises[i].sets[k].reps == old { s.exercises[i].sets[k].reps = new }
            if field == "kg", s.exercises[i].sets[k].kg == old { s.exercises[i].sets[k].kg = new }
        }
    }

    private func addSet(_ exId: UUID) {
        guard let i = index(exId) else { return }
        let last = s.exercises[i].sets.last ?? LiveSet(reps: 8, kg: 0)
        withAnimation { s.exercises[i].sets.append(LiveSet(reps: last.reps, kg: last.kg)) }
    }

    private func removeSet(_ exId: UUID) {
        guard let i = index(exId), s.exercises[i].sets.count > 1 else { return }
        _ = withAnimation { s.exercises[i].sets.removeLast() }
    }

    private func show(_ text: String) {
        withAnimation(.snappy) { banner = text }
        Task { try? await Task.sleep(nanoseconds: 2_600_000_000); withAnimation { if banner == text { banner = nil } } }
    }

    // MARK: finish

    /// Done with the session: friends see the workout on the feed (unless that's turned off in Settings).
    private func offerShare(_ w: JSON?) {
        guard let w else { dismiss(); return }
        if store.shareWorkoutsUnset { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { askShare = w }; return }   // the first time only
        if store.shareWorkouts { Task { try? await Feed.shared.post(ComposeSheet.workoutPost(w), photo: nil) } }
        dismiss()
    }

    private func answerShare(_ yes: Bool) {
        store.perform(["type": "set", "key": "shareWorkouts", "value": yes])
        if yes, let w = askShare { Task { try? await Feed.shared.post(ComposeSheet.workoutPost(w), photo: nil) } }
        askShare = nil
        dismiss()
    }

    private func prepareFinish() {
        // left running: the timer's figure means nothing, so go by the last ticked set
        let end = s.looksForgotten ? (s.lastAt ?? s.startedAt) : Double(nowMs())
        minutesText = String(max(1, Int((end - s.startedAt) / 60000)))
        finishing = true
    }

    private func finish() {
        Self.cancelIdleReminder()
        let minutes = max(1, Int(minutesText) ?? Int((Double(nowMs()) - s.startedAt) / 60000))
        let routineName = s.routineId.flatMap { id in store.routines.first { str($0["id"]) == id }.map { str($0["name"]) } }
        let name = s.name.trimmingCharacters(in: .whitespaces).isEmpty ? (routineName ?? "Gym session") : s.name.trimmingCharacters(in: .whitespaces)
        finished = true
        let w = store.finish(s, minutes: minutes, name: name)
        if let id = s.routineId, let r = store.routines.first(where: { str($0["id"]) == id }) {
            // the routine keeps up with what you do: new weights and reps quietly, bigger changes when you say so
            let exercises = Store.routineExercises(s)
            let changes = Store.routineChanges(from: r, to: exercises, name: name)
            if exercises.isEmpty { offerShare(w) }
            else if changes.isEmpty { store.updateRoutine(r, name: str(r["name"]), exercises: exercises); offerShare(w) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { routineUpdate = RoutineUpdate(routine: r, name: name, exercises: exercises, changes: changes, workout: w) } }
        } else if !list(w["lifts"]).isEmpty { routineOffer = w } else { offerShare(w) }
    }
}

/// One set: reps, weight and a tick. The next set to do stands out; done sets go dark.
struct SetRow: View {
    @Binding var set: LiveSet
    let label: String
    let isNext: Bool
    let onTick: () -> Void
    let onEdit: (_ field: String, _ old: Double, _ new: Double) -> Void
    @State private var repsText = ""
    @State private var kgText = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(set.pb ? "PB" : label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(set.pb ? Color.yellow : (isNext ? Theme.accent : Color.secondary))
                .frame(width: 46, alignment: .leading)
            box($repsText, "reps", field: "reps")
            box($kgText, "kg", field: "kg")
            Button(action: onTick) {
                Image(systemName: set.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 32))
                    .foregroundStyle(set.done ? Theme.accent : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(set.done ? "Done, tap to untick" : "Tick this set")
        }
        .opacity(set.done ? 0.45 : 1)
        .listRowBackground(isNext ? Theme.hero : Color(.secondarySystemGroupedBackground))
        .onAppear { repsText = Fmt.one(set.reps); kgText = set.kg > 0 ? Fmt.kg(set.kg) : "" }
        .onChange(of: set.reps) { _, v in if Double(repsText.replacingOccurrences(of: ",", with: ".")) != v { repsText = Fmt.one(v) } }
        .onChange(of: set.kg) { _, v in if Double(kgText.replacingOccurrences(of: ",", with: ".")) ?? 0 != v { kgText = v > 0 ? Fmt.kg(v) : "" } }
    }

    private func box(_ text: Binding<String>, _ placeholder: String, field: String) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("box-" + field)
                .multilineTextAlignment(.trailing)
                .font(.body.weight(.semibold).monospacedDigit())
            Text(placeholder).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onChange(of: text.wrappedValue) { _, t in
            let v = Double(t.replacingOccurrences(of: ",", with: ".")) ?? 0
            if field == "reps" { let old = set.reps; if v != old { set.reps = v; onEdit("reps", old, v) } }
            else { let old = set.kg; if v != old { set.kg = v; onEdit("kg", old, v) } }
        }
    }
}


/// Left the gym without finishing: last set's time, the set you might not have ticked, and finish with the real time.
private struct ForgotToFinish: View {
    @Binding var session: LiveSession
    var finish: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var didIt = false
    @State private var reps = ""
    @State private var kg = ""

    /// The set after the last ticked one, in an exercise you'd started.
    private var nextSet: (ex: Int, set: Int)? {
        guard let n = session.next, session.exercises[n.ex].sets.contains(where: \.done) else { return nil }
        return n
    }
    private var lastAt: Double { session.lastAt ?? session.startedAt }
    private var minutes: Int { max(1, Int(((lastAt - session.startedAt) / 60000).rounded()) + (didIt ? 3 : 1)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your last set was ticked at \(Date(timeIntervalSince1970: lastAt / 1000).formatted(date: .omitted, time: .shortened)), \(Date(timeIntervalSince1970: lastAt / 1000).formatted(.relative(presentation: .named))).")
                }
                if let n = nextSet {
                    let e = session.exercises[n.ex]
                    Section {
                        Toggle("I did set \(n.set + 1) of \(e.name.isEmpty ? "this exercise" : e.name)", isOn: $didIt.animation())
                        if didIt {
                            HStack {
                                TextField("Reps", text: $reps).keyboardType(.decimalPad)
                                Text("reps").foregroundStyle(.secondary)
                                TextField("kg", text: $kg).keyboardType(.decimalPad)
                                Text("kg").foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("Forgot to tick the last set?") }
                }
                Section {
                    Button { save(); finish(minutes) } label: { Text("Finish: \(minutes) min").font(.headline).frame(maxWidth: .infinity) }
                    Button("I'm still going") { dismiss() }.frame(maxWidth: .infinity)
                } footer: {
                    if session.startedDay < DayKey.string(Date()) { Text("It'll be saved to \(DayKey.date(session.startedDay).formatted(.dateTime.weekday(.wide))), the day you started.") }
                }
            }
            .keyboardDone()
            .navigationTitle("Forgot to finish?")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let n = nextSet { let set = session.exercises[n.ex].sets[n.set]; reps = Fmt.one(set.reps); kg = set.kg > 0 ? Fmt.kg(set.kg) : "" }
            }
        }
    }

    private func save() {
        guard didIt, let n = nextSet else { return }
        session.exercises[n.ex].sets[n.set].reps = Double(reps.replacingOccurrences(of: ",", with: ".")) ?? session.exercises[n.ex].sets[n.set].reps
        session.exercises[n.ex].sets[n.set].kg = Double(kg.replacingOccurrences(of: ",", with: ".")) ?? session.exercises[n.ex].sets[n.set].kg
        session.exercises[n.ex].sets[n.set].done = true
    }
}
