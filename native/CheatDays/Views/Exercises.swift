import Charts
import SwiftUI

/// Add exercises to a session: from past workouts and routines (with their sets), yours, or the library.
struct ExercisePicker: View {
    enum Tab: String, CaseIterable { case past = "Past workouts", yours = "Yours", library = "Library" }
    let inSession: Set<String>
    let onAdd: ([LiveExercise]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .past
    @State private var query = ""
    @State private var added: Set<String> = []
    private var store: Store { Store.shared }

    private struct Group: Identifiable { let id: String; let title: String; let sub: String; let lifts: [JSON] }

    var body: some View {
        NavigationStack {
            List {
                Section { Picker("Where from", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented) }
                let q = query.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty && !allNames.contains(where: { $0.lowercased() == q.lowercased() }) {
                    Section {
                        Button { add(q.prefix(1).uppercased() + q.dropFirst(), detail: nil) } label: { Label("Add \"\(q)\" as a new exercise", systemImage: "plus.circle") }
                    }
                }
                switch tab {
                case .past: pastList
                case .yours: yoursList
                case .library: libraryList
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle("Add an exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.bold) } }
            .onAppear { if store.pastWorkouts.isEmpty && store.routines.isEmpty { tab = .library } }
        }
    }

    private func hit(_ name: String) -> Bool { query.isEmpty || name.lowercased().contains(query.lowercased()) }
    private var allNames: [String] { ExerciseLibrary.groups.flatMap { $0.1 } + dict(store.doc["exercises"]).values.compactMap { ($0 as? JSON).map { str($0["name"]) } } }

    private var groups: [Group] {
        var out: [Group] = []
        for r in store.routines {
            let lifts = list(r["exercises"]).filter { hit(str($0["exercise"])) }
            if !lifts.isEmpty { out.append(Group(id: "r-" + str(r["id"]), title: str(r["name"]), sub: "Routine", lifts: lifts)) }
        }
        var seen = Set<String>()
        var days: [(String, [JSON])] = [(store.today, store.todayWorkouts)]
        days += store.pastWorkouts.map { ($0.date, [$0.workout]) }
        for (date, ws) in days {
            for w in ws {
                let lifts = list(w["lifts"]).filter { hit(str($0["exercise"])) }
                let key = str(w["name"]) + list(w["lifts"]).map { str($0["exercise"]) }.joined()
                guard !lifts.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(Group(id: date + str(w["id"]) + key, title: str(w["name"]), sub: Store.when(date).capitalizedFirst, lifts: lifts))
                if out.count >= 14 { return out }
            }
        }
        return out
    }

    @ViewBuilder private var pastList: some View {
        let gs = groups
        if gs.isEmpty { Section { Text("Finished workouts and routines show up here.").foregroundStyle(.secondary) } }
        ForEach(gs) { g in
            Section {
                ForEach(g.lifts.indices, id: \.self) { i in
                    let l = g.lifts[i]
                    row(str(l["exercise"]), detail: liftText(l)) { add(str(l["exercise"]), detail: list(l["detail"]), template: l) }
                }
            } header: {
                HStack {
                    VStack(alignment: .leading) { Text(g.title).font(.headline).foregroundStyle(.primary); Text(g.sub).font(.caption) }.textCase(nil)
                    Spacer()
                    Button("Add all") { for l in g.lifts { add(str(l["exercise"]), detail: list(l["detail"]), template: l) } }
                        .font(.caption.weight(.bold)).buttonStyle(.bordered).buttonBorderShape(.capsule).textCase(nil)
                }
            }
        }
    }

    @ViewBuilder private var yoursList: some View {
        let mine = dict(store.doc["exercises"]).values.compactMap { $0 as? JSON }.filter { hit(str($0["name"])) }
            .sorted { str($0["lastUsed"]) > str($1["lastUsed"]) }
        if mine.isEmpty { Section { Text("Exercises you log show up here, with your best.").foregroundStyle(.secondary) } }
        else { Section { ForEach(mine.indices, id: \.self) { i in let n = str(mine[i]["name"]); row(n, detail: store.lastLine(n).replacingOccurrences(of: "Last time ", with: "Last ")) { add(n, detail: nil) } } } }
    }

    @ViewBuilder private var libraryList: some View {
        ForEach(ExerciseLibrary.groups, id: \.0) { g in
            let ns = g.1.filter(hit)
            if !ns.isEmpty { Section(g.0) { ForEach(ns, id: \.self) { n in row(n, detail: store.exercise(n) == nil ? nil : store.lastLine(n).replacingOccurrences(of: "Last time ", with: "Last ")) { add(n, detail: nil) } } } }
        }
    }

    private func row(_ name: String, detail: String?, action: @escaping () -> Void) -> some View {
        let isIn = inSession.contains(name.lowercased()) || added.contains(name.lowercased())
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                if let detail, !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button(action: action) {
                Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle.fill").font(.system(size: 28))
                    .foregroundStyle(isIn ? Color.secondary : Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless).disabled(isIn)
        }
    }

    private func add(_ name: String, detail: [JSON]?, template: JSON? = nil) {
        guard !added.contains(name.lowercased()) else { return }
        added.insert(name.lowercased())
        let e = store.liveExercise(name, sets: num(template?["sets"]), reps: num(template?["reps"]), kg: num(template?["kg"]), detail: detail)
        onAdd([e])
    }
}

/// "Lat pulldown 93×10, 93×9" or "3×8 @ 60 kg".
func liftText(_ l: JSON) -> String {
    let d = list(l["detail"])
    if !d.isEmpty {
        let anyKg = d.contains { (num($0["kg"]) ?? 0) > 0 }
        return d.map { s in ((num(s["kg"]) ?? 0) > 0 ? "\(Fmt.one(num(s["kg"]) ?? 0))×" : "") + Fmt.one(num(s["reps"]) ?? 0) }.joined(separator: ", ") + (anyKg ? " kg" : "")
    }
    let kg = num(l["kg"]) ?? 0
    return "\(Fmt.one(num(l["sets"]) ?? 0))×\(Fmt.one(num(l["reps"]) ?? 0))" + (kg > 0 ? " @ \(Fmt.one(kg)) kg" : "")
}

/// Every exercise you've done, then the library. Tap one for its progress.
struct ExerciseBrowser: View {
    @State private var query = ""
    private var store: Store { Store.shared }
    var body: some View {
        let mine = dict(store.doc["exercises"]).values.compactMap { $0 as? JSON }
            .filter { query.isEmpty || str($0["name"]).lowercased().contains(query.lowercased()) }
            .sorted { str($0["lastUsed"]) > str($1["lastUsed"]) }
        List {
            if !mine.isEmpty {
                Section("Yours") {
                    ForEach(mine.indices, id: \.self) { i in
                        let n = str(mine[i]["name"])
                        NavigationLink { ExerciseDetail(name: n) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n).font(.body.weight(.semibold))
                                Text(store.lastLine(n).replacingOccurrences(of: "Last time ", with: "Last ")).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            ForEach(ExerciseLibrary.groups, id: \.0) { g in
                let ns = g.1.filter { query.isEmpty || $0.lowercased().contains(query.lowercased()) }
                if !ns.isEmpty { Section(g.0) { ForEach(ns, id: \.self) { n in NavigationLink(n) { ExerciseDetail(name: n) } } } }
            }
        }
        .searchable(text: $query, prompt: "Search exercises")
        .navigationTitle("Exercises")
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }
}

private struct OneRM: Identifiable { let id = UUID(); let date: Date; let kg: Double }

/// One exercise: best set, estimated one-rep max over time, and every session.
struct ExerciseDetail: View {
    let name: String
    private var store: Store { Store.shared }
    var body: some View {
        let ses = store.sessions(of: name)
        let rec = store.exercise(name)
        let top = max(num(rec?["best1rm"]) ?? 0, ses.map(\.est).max() ?? 0)
        let best = rec.flatMap { $0["bestSet"] as? JSON }
        let points = ses.prefix(12).reversed().filter { $0.est > 0 }.map { OneRM(date: DayKey.date($0.date), kg: $0.est) }
        List {
            Section {
                HStack {
                    stat(best.map { "\(Fmt.one(num($0["kg"]) ?? 0)) × \(Fmt.one(num($0["reps"]) ?? 0))" } ?? "–", "best set (kg × reps)")
                    stat(top > 0 ? "\(Fmt.int(top)) kg" : "–", "est. one-rep max")
                    stat("\(ses.count)", "sessions")
                }
            }
            if points.count > 1 {
                Section("Estimated one-rep max") {
                    Chart(points) { p in
                        LineMark(x: .value("Day", p.date), y: .value("kg", p.kg)).interpolationMethod(.catmullRom).foregroundStyle(Theme.accent)
                        PointMark(x: .value("Day", p.date), y: .value("kg", p.kg)).foregroundStyle(Theme.accent)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 160)
                }
            }
            Section("Sessions") {
                if ses.isEmpty { Text("Not done yet. Add it to a session and it shows up here.").foregroundStyle(.secondary) }
                ForEach(ses.indices, id: \.self) { i in
                    let x = ses[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Store.when(x.date).capitalizedFirst) · \(x.workout)").font(.subheadline.weight(.semibold))
                        Text(liftText(x.lift)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(spacing: 2) { Text(v).font(.headline.weight(.heavy)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1); Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            .frame(maxWidth: .infinity)
    }
}
