import SwiftUI

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
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    init() {
        _s = State(initialValue: Store.shared.session ?? LiveSession(startedAt: Double(nowMs()), name: "", routineId: nil, exercises: []))
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
                } header: { Text("Drag to reorder") }
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
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { withAnimation { reordering.toggle() } } label: { Label(reordering ? "Done reordering" : "Reorder exercises", systemImage: "arrow.up.arrow.down") }
                    Button(role: .destructive) { confirmDiscard = true } label: { Label("Discard session", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Finish") { prepareFinish() }.fontWeight(.bold)
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
            Text("How many minutes did it take? Change it if the timer ran on.")
        }
        .confirmationDialog("Discard this session? Nothing will be logged.", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { finished = true; store.saveSession(nil); dismiss() }
        }
        .confirmationDialog("Save this as a routine, to start it again next time?", isPresented: Binding(get: { routineOffer != nil }, set: { if !$0 { routineOffer = nil; dismiss() } }), titleVisibility: .visible) {
            Button("Save as a routine") {
                if let w = routineOffer {
                    store.saveRoutine(name: str(w["name"]), exercises: list(w["lifts"]).map { ["exercise": $0["exercise"] ?? "", "sets": $0["sets"] ?? 3, "reps": $0["reps"] ?? 8, "kg": $0["kg"] ?? 0] as JSON })
                }
                routineOffer = nil; dismiss()
            }
            Button("Not now", role: .cancel) { routineOffer = nil; dismiss() }
        }
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
            Text(store.lastLine(ex.name)).font(.footnote).foregroundStyle(.secondary).opacity(ex.complete ? 0.55 : 1)
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

    private func index(_ id: UUID) -> Int? { s.exercises.firstIndex { $0.id == id } }

    private func tick(_ exId: UUID, _ setId: UUID) {
        guard let i = index(exId), let j = s.exercises[i].sets.firstIndex(where: { $0.id == setId }) else { return }
        var set = s.exercises[i].sets[j]
        set.done.toggle(); set.pb = false
        if set.done {
            if set.reps <= 0 { set.reps = 1 }
            s.restUntil = Double(nowMs() + store.restSeconds * 1000)
            let name = s.exercises[i].name
            let prev = num(store.exercise(name)?["best1rm"]) ?? 0
            let e1 = Store.est(kg: set.kg, reps: set.reps)
            let sessionBest = s.exercises.filter { $0.name.lowercased() == name.lowercased() }.flatMap(\.sets)
                .filter { $0.pb && $0.id != setId }.map { Store.est(kg: $0.kg, reps: $0.reps) }.max() ?? 0
            if prev > 0, e1 > max(prev, sessionBest) {
                set.pb = true
                show("New best for \(name): \(Fmt.one(set.kg)) kg × \(Fmt.one(set.reps))")
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

    private func prepareFinish() {
        minutesText = String(max(1, Int((Double(nowMs()) - s.startedAt) / 60000)))
        finishing = true
    }

    private func finish() {
        let minutes = max(1, Int(minutesText) ?? Int((Double(nowMs()) - s.startedAt) / 60000))
        let routineName = s.routineId.flatMap { id in store.routines.first { str($0["id"]) == id }.map { str($0["name"]) } }
        let name = s.name.trimmingCharacters(in: .whitespaces).isEmpty ? (routineName ?? "Gym session") : s.name.trimmingCharacters(in: .whitespaces)
        finished = true
        let w = store.finish(s, minutes: minutes, name: name)
        if s.routineId == nil && !list(w["lifts"]).isEmpty { routineOffer = w } else { dismiss() }
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
        .onAppear { repsText = Fmt.one(set.reps); kgText = set.kg > 0 ? Fmt.one(set.kg) : "" }
        .onChange(of: set.reps) { _, v in if Double(repsText.replacingOccurrences(of: ",", with: ".")) != v { repsText = Fmt.one(v) } }
        .onChange(of: set.kg) { _, v in if Double(kgText.replacingOccurrences(of: ",", with: ".")) ?? 0 != v { kgText = v > 0 ? Fmt.one(v) : "" } }
    }

    private func box(_ text: Binding<String>, _ placeholder: String, field: String) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
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
