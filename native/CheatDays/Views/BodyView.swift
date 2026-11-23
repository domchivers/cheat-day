import Charts
import PhotosUI
import SwiftUI

/// Weigh-ins, behind "See all" on Progress: your goal, every reading by month (tap to change, swipe to delete), and
/// your scale. The chart lives on Progress alone.
struct BodyView: View {
    @State private var entry: JSON?
    @State private var editing: GoalKind?   // the goal weight or body fat being typed
    private var store: Store { Store.shared }
    /// A tab of PlanTabs (which gives the title), and whether its tab is the one showing.
    var embedded = false
    var active = true
    init(embedded: Bool = false, active: Bool = true) { self.embedded = embedded; self.active = active }
    static let metrics: [(key: String, name: String, unit: String)] = [
        // Apple Health's four first (what a scale sends every weigh-in), then what only a screenshot or typing brings
        ("weight", "Weight", "kg"), ("fat", "Body fat", "%"), ("lean", "Lean mass", "kg"), ("bmi", "BMI", ""),
        ("muscle", "Muscle", "kg"), ("water", "Water", "%"),
        ("visceral", "Visceral fat", ""), ("bone", "Bone", "kg"), ("age", "Body age", "yrs")
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
        // the plain grey, as Your plan's headings: .secondary in a List header came out dimmer still (24 Nov)
        Text(t).font(.headline.weight(.heavy)).foregroundStyle(Color(.secondaryLabel)).textCase(nil)
    }

    var body: some View {
        let all = months
        List {
            Section { goalCard } header: { head("Your goal") }
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
        // as a tab it runs on behind the tab bar (PlanTabs), so its last rows need room to come up above it
        .contentMargins(.bottom, embedded ? 100 : 0, for: .scrollContent)
        .titled("Weigh-ins", unless: embedded)
        .toolbar {
            // as a tab of PlanTabs, only while its tab is showing
            if !embedded || active {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { entry = ["new": true, "day": "new"] } label: { Image(systemName: "plus") }.accessibilityLabel("Weigh in")
                }
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
        // One goal, said two ways (18 Nov): the goal weight, and the body fat it comes to. Either is typed; the other
        // follows. It was a − and + for the weight only, with the body-fat goal a row underneath, missing altogether
        // without readings, so it wasn't clear where either was set.
        let trend = store.trendWeight ?? now ?? 0
        let bf = store.fatTrend, fat = store.goalFatShown(now: trend)
        return VStack(alignment: .leading, spacing: 10) {
            goalRow("Goal weight", goal.map { Fmt.one($0) }, "kg") { editing = .weight }
            Divider()
            if bf != nil { goalRow("Body fat", fat.map { Fmt.dec($0) }, "%") { editing = .fat } }
            else {
                HStack { Text("Body fat").font(.headline); Spacer(); Text("Needs 2 readings").font(.subheadline).foregroundStyle(.secondary) }
                    .padding(.vertical, 6)
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
                Text(goalLine(goal: goal, now: now, fat: fat)).font(.footnote).foregroundStyle(.secondary)
            }
            if let bf {
                Text("Body fat now \(Fmt.dec(bf.pct))%, averaged over your last \(bf.n) readings: scales read body fat roughly, so one reading means little.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Weigh in on a scale that measures body fat (or type it in a weigh-in) twice, and your goal shows as body fat too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // as tall as the number and its line (19 Nov: 320 left a band of empty sheet above the keyboard); a goal weight
        // already set has Remove goal under it too
        .sheet(item: $editing) { k in GoalSheet(kind: k, now: trend).presentationDetents([.height(k == .weight && pos(store.doc["goalWeight"]) != nil ? 215 : 175)]) }
    }

    /// A goal's name and its number in a box: tap to type it.
    private func goalRow(_ title: String, _ value: String?, _ unit: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Text(title).font(.headline).foregroundStyle(.primary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value ?? "Set").font(.title3.weight(.heavy)).monospacedDigit().foregroundStyle(value == nil ? Theme.accent : Color.primary)
                    if value != nil { Text(unit).font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.map { "\(title), \($0) \(unit). Change" } ?? "\(title). Set")
    }

    private func goalLine(goal: Double, now: Double, fat: Double?) -> String {
        let left = now - goal
        if abs(left) < 0.25 { return "You're there. Nice work." }
        var s = "\(Fmt.one(abs(left))) kg to go"
        if let fat { s += ", about \(Fmt.dec(fat))% body fat at the muscle you have now" }
        // the same date as Me: the trend weight at the 4-week pace
        if let d = store.reachDate(goal) { s += ". At your current pace, around \(d.formatted(.dateTime.day().month(.wide)))" }
        return s + "."
    }
}

enum GoalKind: String, Identifiable { case weight, fat; var id: String { rawValue } }

/// Type the goal weight or the body fat %: as it's typed, what it comes to in the other.
struct GoalSheet: View {
    let kind: GoalKind
    /// The trend weight now, which both are worked out from.
    let now: Double
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }
    private var value: Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
    private var ok: Bool {
        guard let v = value else { return false }
        return kind == .weight ? (35...250).contains(v) : (3...50).contains(v)
    }
    /// What it means in the other: the body fat a weight comes to, or the weight a body fat does.
    private var hint: String {
        guard let v = value, ok, let bf = store.fatTrend, now > 0 else { return kind == .weight ? " " : "Your goal weight changes to match." }
        if kind == .weight { return "That's about \(Fmt.dec((Store.fatAt(weight: now, fatPct: bf.pct, goal: v) * 10).rounded() / 10))% body fat" }
        return "That's about \(Fmt.kg(Store.fatGoal(weight: now, fatPct: bf.pct, target: v).weight)) kg"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField(kind == .weight ? "76" : "13", text: $text).keyboardType(.decimalPad).focused($typing)
                        .font(.system(size: 46, weight: .heavy, design: .rounded)).multilineTextAlignment(.center).fixedSize()
                    Text(kind == .weight ? "kg" : "%").font(.title2.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.top, 18)
                Text(hint).font(.subheadline).foregroundStyle(.secondary)
                if kind == .weight, pos(store.doc["goalWeight"]) != nil {
                    Button("Remove goal", role: .destructive) {
                        store.perform(["type": "set", "key": "goalWeight", "value": NSNull()])
                        store.perform(["type": "set", "key": "goalFat", "value": NSNull()])
                        dismiss()
                    }
                    .font(.subheadline).padding(.top, 8)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationTitle(kind == .weight ? "Goal weight" : "Body-fat goal").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = value, ok else { return }
                        if kind == .weight { store.setGoalWeight(v) } else { store.setGoalFat(v, now: now) }
                        dismiss()
                    }
                    .fontWeight(.bold).disabled(!ok)
                }
            }
            .onAppear {
                let shown: Double? = kind == .weight ? pos(store.doc["goalWeight"]) : store.goalFatShown(now: now)
                text = shown.map { kind == .weight ? Fmt.one($0) : Fmt.dec($0) } ?? ""
                typing = true
            }
        }
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
        perform(["type": "set", "key": "goalWeight", "value": (kg * 10).rounded() / 10], syncAfter: 2)   // typed to a tenth (18 Nov); the steppers go in halves
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

