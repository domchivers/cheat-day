import Charts
import PhotosUI
import SwiftUI

private struct BodyPoint: Identifiable { let id: String; let date: Date; let value: Double; let trend: Double?; let odd: Bool }

/// Body: any measure over time with a trend line, your goal, every reading, and adding one by hand or from a scale screenshot.
struct BodyView: View {
    @State private var metric = "weight"
    @State private var range = 90
    @State private var entry: JSON?
    @State private var picked: Date?
    private var store: Store { Store.shared }

    static let metrics: [(key: String, name: String, unit: String)] = [
        ("weight", "Weight", "kg"), ("fat", "Body fat", "%"), ("muscle", "Muscle", "kg"), ("water", "Water", "%"),
        ("visceral", "Visceral fat", ""), ("bone", "Bone", "kg"), ("bmi", "BMI", ""), ("age", "Body age", "yrs")
    ]

    var body: some View {
        let rows = store.bodyRows
        let have = Self.metrics.filter { m in rows.contains { pos($0[m.key]) != nil } }
        let m = Self.metrics.first { $0.key == metric } ?? Self.metrics[0]
        let points = series(rows, key: metric)
        List {
            if !have.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(have, id: \.key) { x in Chip(text: x.name, on: metric == x.key) { withAnimation(.snappy) { metric = x.key } } } }
                    }
                    Picker("Range", selection: $range.animation(.snappy)) {
                        Text("1M").tag(30); Text("3M").tag(90); Text("6M").tag(180); Text("1Y").tag(365); Text("All").tag(4000)
                    }
                    .pickerStyle(.segmented)
                    hero(points, m)
                    chart(points, m)
                        .onChange(of: metric) { _, _ in picked = nil }
                        .onChange(of: range) { _, _ in picked = nil }
                }
                .listRowSeparator(.hidden)
            }
            if metric == "weight" { Section { goalCard } }
            Section {
                Button { entry = ["day": store.today] } label: { Label("Add a reading", systemImage: "plus.circle.fill").font(.headline) }
            }
            if !rows.isEmpty {
                let recent = Array(rows.reversed().prefix(60))
                Section("Readings") {
                    ForEach(keyed(recent, by: "day")) { reading in
                        let r = reading.item
                        Button { entry = r } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(DayKey.date(str(r["day"])).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.subheadline)
                                    if let t = ISO.date(str(r["takenAt"])) { Text(t.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(Self.metrics.compactMap { x in pos(r[x.key]).map { "\(Fmt.kg($0))\(x.unit == "%" ? "%" : x.unit.isEmpty ? "" : " \(x.unit)")" } }.prefix(3).joined(separator: " · "))
                                    .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions { Button(role: .destructive) { store.deleteBody(str(r["day"])) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
            Section {
                ScaleConnectRow()
                NavigationLink { WebScreen(view: "body", pushed: true).navigationTitle("Other imports").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Other imports (CSV, Shortcut)", systemImage: "link")
                }
            } header: { Text("Your scale") } footer: { Text("Smart scale apps (VeSync, Withings, Eufy, Renpho, Fitbit, Garmin and more) save to Apple Health. Connect it and every weigh-in arrives on its own.") }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Body")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.pullBody(); await HealthSync.pull(force: true) }
        .task { await HealthSync.pull() }
        .sheet(item: Binding(get: { entry.map { EntryBox(row: $0) } }, set: { entry = $0?.row })) { b in
            BodyEntrySheet(row: b.row) { entry = nil }.presentationDetents([.large])
        }
    }

    private func series(_ rows: [JSON], key: String) -> [BodyPoint] {
        let since = DayKey.shift(store.today, days: -range)
        let all = rows.compactMap { r -> (String, Double)? in pos(r[key]).map { (str(r["day"]), $0) } }
        let t = all.count >= 4 ? Trend.fit(days: all.map(\.0), values: all.map(\.1)) : (fit: all.map(\.1), odd: all.map { _ in false })
        return all.indices.filter { all[$0].0 >= since }.map { i in
            BodyPoint(id: all[i].0, date: DayKey.date(all[i].0), value: all[i].1, trend: all.count >= 4 ? t.fit[i] : nil, odd: t.odd[i])
        }
    }

    private func hero(_ pts: [BodyPoint], _ m: (key: String, name: String, unit: String)) -> some View {
        let last = pts.last, first = pts.first { !$0.odd }
        let sel = nearest(pts)
        let now = sel?.value ?? last?.value   // the latest reading as measured, or the one under your finger
        let change = (now != nil && first != nil) ? now! - (first!.trend ?? first!.value) : nil
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: sel.map { $0.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) } ?? (m.key == "weight" ? "Last weigh-in" : m.name), color: Theme.heroLabel)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(now.map { Fmt.kg($0) } ?? "–").font(.system(size: 44, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text(m.unit).font(.headline).foregroundStyle(.secondary)
                }
                if let sel {
                    Text(sel.trend.map { "Trend that day \(Fmt.kg($0))" } ?? "A single reading").font(.caption).foregroundStyle(.secondary)
                } else if m.key == "weight", let w = store.lastWeighIn {
                    let trend = store.trendWeight.flatMap { abs($0 - w.kg) >= 0.2 ? " · trend \(Fmt.kg($0)) kg" : nil } ?? ""
                    Text("\(Store.whenTaken(day: w.day, at: w.at).capitalizedFirst)\(trend)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let change, pts.count > 1, sel == nil {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(change > 0 ? "+" : change < 0 ? "−" : "")\(Fmt.one(abs(change)))\(m.unit.isEmpty || m.unit == "%" ? m.unit : " \(m.unit)")")
                        .font(.title3.weight(.heavy)).foregroundStyle(m.key == "muscle" ? (change >= 0 ? Color.green : Theme.warn) : (change <= 0 ? Color.green : Theme.warn))
                    Text(range > 400 ? "since you started" : "in \(rangeText)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rangeText: String { [30: "a month", 90: "3 months", 180: "6 months", 365: "a year"][range] ?? "" }

    /// The reading nearest to where your finger is on the chart.
    private func nearest(_ pts: [BodyPoint]) -> BodyPoint? {
        guard let picked else { return nil }
        return pts.min { abs($0.date.timeIntervalSince(picked)) < abs($1.date.timeIntervalSince(picked)) }
    }

    /// Readings as soft dots, the trend as a smooth line with a fade under it, the goal dashed. Touch and drag along it
    /// and the big number above shows that day's reading.
    private func chart(_ pts: [BodyPoint], _ m: (key: String, name: String, unit: String)) -> some View {
        let goal = m.key == "weight" ? pos(store.doc["goalWeight"]) : nil
        let vals = pts.map(\.value) + pts.compactMap(\.trend) + (goal.map { [$0] } ?? [])
        let lo = (vals.min() ?? 0), hi = (vals.max() ?? 1), pad = max(0.4, (hi - lo) * 0.12)
        let floor = lo - pad
        let line = pts.filter { $0.trend != nil }
        let sel = nearest(pts)
        return Chart {
            ForEach(line) { p in
                AreaMark(x: .value("Day", p.date), yStart: .value("Base", floor), yEnd: .value("Trend", p.trend ?? p.value))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            ForEach(line) { p in
                LineMark(x: .value("Day", p.date), y: .value("Trend", p.trend ?? p.value))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(pts) { p in
                PointMark(x: .value("Day", p.date), y: .value(m.name, p.value))
                    .foregroundStyle(p.odd ? Color.secondary.opacity(0.35) : Color.white.opacity(0.55))
                    .symbolSize(p.odd ? 14 : 20)
            }
            if let goal {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(Color.green.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) { Text("Goal \(Fmt.kg(goal))").font(.caption2.weight(.bold)).foregroundStyle(.green) }
            }
            if let sel {
                RuleMark(x: .value("Picked", sel.date)).foregroundStyle(Color.white.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Day", sel.date), y: .value(m.name, sel.value)).foregroundStyle(Theme.accent).symbolSize(90)
            }
        }
        .chartYScale(domain: floor...(hi + pad))
        .chartXSelection(value: $picked)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.white.opacity(0.12))
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.one(d)).font(.caption2).foregroundStyle(.secondary) } }
            }
        }
        .chartXAxis {
            // one label per week (1M), per month (3M), or every few months, so none repeat
            if range <= 30 {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2).foregroundStyle(.secondary) }
            } else if range <= 365 {
                AxisMarks(values: .stride(by: .month, count: range <= 90 ? 1 : range <= 180 ? 2 : 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.caption2).foregroundStyle(.secondary) }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(height: 220)
        .overlay { if pts.isEmpty { Text("No readings in this range").font(.footnote).foregroundStyle(.secondary) } }
        .sensoryFeedback(.selection, trigger: sel?.id)
    }

    private var goalCard: some View {
        let goal = pos(store.doc["goalWeight"]), start = pos(dict(store.doc["goalStart"])["weight"])
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
                        Capsule().fill(Color.green).frame(width: g.size.width * (total > 0 ? min(1, done / total) : 1))
                    }
                }
                .frame(height: 8)
                Text(goalLine(goal: goal, now: now)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func goalLine(goal: Double, now: Double) -> String {
        let left = now - goal
        if abs(left) < 0.25 { return "You're there. Nice work." }
        var s = "\(Fmt.one(abs(left))) kg to go"
        if let t = store.weightTrend(), t.perDay != 0, (t.perDay < 0) == (left > 0) {
            let days = Int(abs(left / t.perDay))
            if let d = Calendar.current.date(byAdding: .day, value: days, to: Date()), days < 1500 { s += ". At your current pace, around \(d.formatted(.dateTime.month(.wide).year()))." }
        }
        return s
    }
}

private struct EntryBox: Identifiable { let row: JSON; var id: String { str(row["day"]) } }

/// Add or change a day's reading. A screenshot of the scale's app can fill it in.
struct BodyEntrySheet: View {
    @State var row: JSON
    var done: () -> Void
    @State private var date = Date()
    @State private var values: [String: String] = [:]
    @State private var picked: PhotosPickerItem?
    @State private var reading = false
    @State private var problem: String?
    private var store: Store { Store.shared }
    private let fields: [(String, String, String)] = [
        ("weight", "Weight", "kg"), ("fat", "Body fat", "%"), ("muscle", "Muscle", "kg"), ("water", "Water", "%"),
        ("bone", "Bone", "kg"), ("visceral", "Visceral fat", "level"), ("age", "Body age", "years")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $date, in: ...Date(), displayedComponents: .date)
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label(reading ? "Reading the screenshot…" : "Fill in from a scale screenshot", systemImage: "sparkles")
                    }
                    .disabled(reading)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
                }
                Section {
                    ForEach(fields, id: \.0) { f in
                        HStack {
                            Text(f.1)
                            Spacer()
                            TextField("–", text: Binding(get: { values[f.0] ?? "" }, set: { values[f.0] = $0 }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90).font(.body.weight(.semibold))
                            Text(f.2).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                        }
                    }
                } footer: { Text("Only weight is needed. Fill in whatever your scale shows.") }
            }
            .keyboardDone()
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.bold).disabled(parsed.isEmpty) }
            }
            .onAppear {
                date = DayKey.date(str(row["day"]).isEmpty ? store.today : str(row["day"]))
                for f in fields { if let v = pos(row[f.0]) { values[f.0] = Fmt.kg(v) } }
            }
            .onChange(of: picked) { _, item in Task { await read(item) } }
        }
    }

    private var parsed: JSON {
        var out = JSON()
        for f in fields { if let v = Double((values[f.0] ?? "").replacingOccurrences(of: ",", with: ".")), v > 0 { out[f.0] = Fmt.kg2(v) } }
        return out
    }

    private func save() {
        let day = DayKey.string(date)
        if !str(row["day"]).isEmpty && str(row["day"]) != day { store.deleteBody(str(row["day"])) }   // moved to another day
        var r = parsed; r["day"] = day; r["updatedAt"] = ISO.now()
        store.saveBody(r)
        done()
    }

    private func read(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
        reading = true; problem = nil
        defer { reading = false }
        do {
            let a = try await BodyReader.read(img)
            for f in fields { if let v = pos(a[f.0]) { values[f.0] = Fmt.kg(v) } }
            if let d = a["day"] as? String { date = DayKey.date(d) }
        } catch { problem = error.localizedDescription }
    }
}

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
        let a = try await Gemini.ask(schema: schema, parts: [part, ["text": "This is a screenshot from a smart scale's app. Read the body measurements shown, exactly as printed, decimals included. Leave anything not shown as null."]], quick: true)
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
            var cloud = row; cloud.removeValue(forKey: "updatedAt"); cloud["user_id"] = me; cloud["updated_at"] = ISO.now()
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
                else { Button("Connect") { Task { await connect() } }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(.black) }
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
