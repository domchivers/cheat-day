import Charts
import PhotosUI
import SwiftUI

/// Weigh-ins, behind "See all" on Progress: your goal, every reading by month (tap to change, swipe to delete), and
/// your scale. The chart lives on Progress alone.
struct BodyView: View {
    @State private var entry: JSON?
    private var store: Store { Store.shared }
    static let metrics: [(key: String, name: String, unit: String)] = [
        ("weight", "Weight", "kg"), ("fat", "Body fat", "%"), ("muscle", "Muscle", "kg"), ("water", "Water", "%"),
        ("visceral", "Visceral fat", ""), ("bone", "Bone", "kg"), ("bmi", "BMI", ""), ("age", "Body age", "yrs")
    ]

    private struct Month: Identifiable { let id: String; let rows: [JSON] }
    /// Readings newest first, a section a month.
    private var months: [Month] {
        let rows = store.bodyRows.filter { pos($0["weight"]) != nil || pos($0["fat"]) != nil }.sorted { str($0["day"]) > str($1["day"]) }
        var out: [Month] = []
        for r in rows {
            let key = String(str(r["day"]).prefix(7))
            if out.last?.id == key { out[out.count - 1] = Month(id: key, rows: out[out.count - 1].rows + [r]) } else { out.append(Month(id: key, rows: [r])) }
        }
        return out
    }
    private func monthName(_ key: String) -> String {
        let d = DayKey.date(key + "-01")
        return key.prefix(4) == store.today.prefix(4) ? d.formatted(.dateTime.month(.wide)) : d.formatted(.dateTime.month(.wide).year())
    }
    private func head(_ t: String) -> some View {
        Text(t).font(.headline.weight(.heavy)).foregroundStyle(.secondary).textCase(nil)
    }

    var body: some View {
        let all = months
        List {
            Section { goalCard } header: { head("Goal") }
            if all.isEmpty {
                Section { Button { entry = ["new": true, "day": "new"] } label: { Label("Weigh in", systemImage: "plus.circle.fill").font(.headline) } }
            }
            ForEach(all) { m in
                Section {
                    ForEach(keyed(m.rows, by: "day")) { reading in
                        let r = reading.item
                        Button { entry = r } label: {
                            HStack {
                                Text(DayKey.date(str(r["day"])).formatted(.dateTime.weekday(.abbreviated).day())).font(.body.weight(.semibold))
                                Spacer()
                                Text(([pos(r["weight"]).map { "\(Fmt.kgRow($0)) kg" }, pos(r["fat"]).map { "\(Fmt.dec($0))%" }].compactMap { $0 }).joined(separator: " · "))
                                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions { Button(role: .destructive) { store.deleteBody(str(r["day"])) } label: { Label("Delete", systemImage: "trash") } }
                    }
                } header: { head(monthName(m.id)) }
            }
            Section {
                ScaleConnectRow()
            } header: { head("Your scale") } footer: { Text("Smart scale apps (VeSync, Withings, Eufy, Renpho, Fitbit, Garmin and more) save to Apple Health. Connect it and every weigh-in arrives on its own.") }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Weigh-ins")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { entry = ["new": true, "day": "new"] } label: { Image(systemName: "plus") }.accessibilityLabel("Weigh in")
            }
        }
        .refreshable { await store.pullBody(); await HealthSync.pull(force: true) }
        .task { await HealthSync.pull() }
        .sheet(item: Binding(get: { entry.map { EntryBox(row: $0) } }, set: { entry = $0?.row })) { b in
            if b.row["new"] as? Bool == true { WeighInSheet() } else { WeighInSheet(row: b.row) }
        }
    }

    private var goalCard: some View {
        // where the goal started: saved with it, or else the earliest reading of the last four months
        let since = DayKey.shift(store.today, days: -120)
        let earliest = store.bodyRows.first { str($0["day"]) >= since && pos($0["weight"]) != nil }.flatMap { pos($0["weight"]) }
        let goal = pos(store.doc["goalWeight"]), start = pos(dict(store.doc["goalStart"])["weight"]) ?? earliest
        let now = store.latestWeight?.kg
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Goal weight").font(.headline)
                Spacer()
                Stepper(value: Binding(get: { goal ?? (now.map { ($0 - 3).rounded() } ?? 75) }, set: { store.setGoalWeight($0) }), in: 35...250, step: 0.5) { EmptyView() }.labelsHidden()
                Text(goal.map { "\(Fmt.one($0)) kg" } ?? "None").font(.headline.weight(.heavy)).monospacedDigit()
            }
            if let goal, let now {
                let total = abs((start ?? now) - goal), done = max(0, total - abs(now - goal))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(Theme.accent).frame(width: g.size.width * (total > 0 ? min(1, done / total) : 1))
                    }
                }
                .frame(height: 8)
                Text(goalLine(goal: goal, now: now)).font(.footnote).foregroundStyle(.secondary)
            }
            BodyFatSummary(now: store.trendWeight ?? now ?? 0)
        }
        .padding(.vertical, 4)
    }

    private func goalLine(goal: Double, now: Double) -> String {
        let left = now - goal
        if abs(left) < 0.25 { return "You're there. Nice work." }
        var s = "\(Fmt.one(abs(left))) kg to go"
        // the same date as Me: the trend weight at the 4-week pace
        if let d = store.reachDate(goal) { s += ". At your current pace, around \(d.formatted(.dateTime.day().month(.wide)))." }
        return s
    }
}

private struct EntryBox: Identifiable { let row: JSON; var id: String { str(row["day"]) } }

/// A screenshot of a scale's app: the measurements on it, and its date if it shows one.
enum BodyReader {
    static let fields: [(String, String, String)] = [
        ("weight", "Weight", "kg"), ("fat", "Body fat", "%"), ("muscle", "Muscle", "kg"), ("water", "Water", "%"),
        ("bone", "Bone", "kg"), ("visceral", "Visceral fat", "level"), ("age", "Body age", "years"), ("bmi", "BMI", "")
    ]

    static func read(_ img: UIImage) async throws -> JSON {
        guard let part = Gemini.imagePart(img) else { throw Gemini.Failure(message: "Couldn't read that picture.") }
        var props = JSON()
        for f in fields { props[f.0] = ["type": "number", "nullable": true, "description": "\(f.1)\(f.2.isEmpty ? "" : " in \(f.2)"), if shown, with its decimals"] as JSON }
        props["date"] = ["type": "string", "nullable": true, "description": "The reading's date as YYYY-MM-DD, if shown"] as JSON
        props["time"] = ["type": "string", "nullable": true, "description": "The reading's time as HH:MM in 24-hour time, if shown"] as JSON
        let schema: JSON = ["type": "object", "properties": props, "required": Array(props.keys)]
        let a = try await Gemini.ask(schema: schema, parts: [part, ["text": "This is a screenshot from a smart scale's app. Read the body measurements shown, exactly as printed, decimals included. Leave anything not shown as null."]], quick: true, job: "labels")
        var out = JSON()
        for f in fields { if let v = pos(a[f.0]) { out[f.0] = Fmt.kg2(v) } }
        if let d = a["date"] as? String, DayKey.string(DayKey.date(d)) == d, DayKey.date(d) <= Date() { out["day"] = d }   // only a real date, never a guess
        // and the time the scale took it, so it isn't shown as when the screenshot was added
        if let day = out["day"] as? String, let t = a["time"] as? String {
            let hm = t.split(separator: ":").compactMap { Int($0) }
            if hm.count >= 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]),
               let at = Calendar.current.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: DayKey.date(day)), at <= Date() {
                out["takenAt"] = ISO8601DateFormatter().string(from: at)
            }
        }
        if fields.allSatisfy({ out[$0.0] == nil }) { throw Gemini.Failure(message: "Couldn't find any readings in that picture.") }
        return out
    }
}

extension Store {
    /// Any reading: into the record and the body_metrics table.
    func saveBody(_ row: JSON) {
        perform(["type": "body", "row": row])
        Task {
            guard let me = Supabase.shared.userId else { return }
            var cloud = row; for k in ["updatedAt", "usual", "why"] { cloud.removeValue(forKey: k) }; cloud["user_id"] = me; cloud["updated_at"] = ISO.now()
            _ = try? await Supabase.shared.rest("/rest/v1/body_metrics?on_conflict=user_id,day", method: "POST", body: [cloud], prefer: "resolution=merge-duplicates")
        }
    }

    func deleteBody(_ day: String) {
        perform(["type": "deleteBody", "day": day, "at": nowMs()])
        Task {
            guard let me = Supabase.shared.userId else { return }
            _ = try? await Supabase.shared.rest("/rest/v1/body_metrics?user_id=eq.\(me)&day=eq.\(day)", method: "DELETE")
        }
    }

    func setGoalWeight(_ kg: Double) {
        perform(["type": "set", "key": "goalWeight", "value": (kg * 2).rounded() / 2], syncAfter: 2)
        if dict(doc["goalStart"]).isEmpty, let w = latestWeight?.kg { perform(["type": "set", "key": "goalStart", "value": ["weight": w, "day": today] as JSON], syncAfter: 2) }
    }
}

/// Connect a smart scale through Apple Health: one tap, then readings come in by themselves.
struct ScaleConnectRow: View {
    @State private var on = HealthSync.on
    @State private var busy = false
    @State private var note: String?
    @State private var confirmOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "heart.text.square.fill").font(.title2).foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(on ? "Connected to Apple Health" : "Connect your scale").font(.subheadline.weight(.semibold))
                    Text(on ? (HealthSync.lastPull.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Waiting for a reading") : "Through Apple Health, any brand").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView() }
                else if on { Button("Turn off") { confirmOff = true }.font(.caption.weight(.semibold)).buttonStyle(.borderless).foregroundStyle(.secondary) }
                else { Button("Connect") { Task { await connect() } }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(Theme.onAccent) }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Stop reading weigh-ins from Apple Health?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { HealthSync.disconnect(); on = false; note = nil }
        } message: { Text("Readings already in Cheat Days stay.") }
    }

    private func connect() async {
        busy = true; defer { busy = false }
        do {
            let n = try await HealthSync.connect()
            on = true
            note = n > 0 ? "\(n) day\(n == 1 ? "" : "s") of readings came in." : "Connected. In your scale's app (in VeSync: Me, then Third-party services) turn on Apple Health, and weigh-ins arrive here."
        } catch { note = error.localizedDescription }
    }
}

/// Body fat with the goal in Weigh-ins: the averaged %, and a body-fat goal with the weight it
/// means and when the trend gets there (the same date maths as the weight goal).
struct BodyFatSummary: View {
    let now: Double
    @State private var setting = false
    @State private var text = ""
    private var store: Store { Store.shared }

    var body: some View {
        if let bf = store.fatTrend, now > 0 {
            let fatKg = now * bf.pct / 100
            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.vertical, 2)
                Button {
                    text = store.goalFat.map { Fmt.one($0) } ?? ""; setting = true
                } label: {
                    HStack {
                        Text("Body-fat goal")
                        Spacer()
                        Text(store.goalFat.map { "\(Fmt.dec($0))%" } ?? "Set").fontWeight(.semibold)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if let t = store.goalFat {
                    let g = Store.fatGoal(weight: now, fatPct: bf.pct, target: t)
                    Text(abs(g.weight - now) < 0.3 ? "You're about there."
                         : "\(Fmt.dec(t))% body fat ≈ \(Fmt.kg(g.weight)) kg\(store.reachDate(g.weight).map { ", around \($0.formatted(.dateTime.day().month(.wide)))" } ?? "").")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Now \(Fmt.dec(bf.pct))%, averaged over your last \(bf.n) readings: scales read body fat roughly, so one reading means little.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .alert("Body-fat goal", isPresented: $setting) {
                TextField("%", text: $text).keyboardType(.decimalPad)
                Button("Save") {
                    if let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 3, v < 50 {
                        store.perform(["type": "set", "key": "goalFat", "value": v])
                    }
                }
                if store.goalFat != nil { Button("Remove", role: .destructive) { store.perform(["type": "set", "key": "goalFat", "value": NSNull()]) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The body fat % you're aiming for. It works out the weight that means, counting a little lean loss on the way.") }
        }
    }
}
