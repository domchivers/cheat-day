import Charts
import PhotosUI
import SwiftUI

private struct BodyPoint: Identifiable { let id: String; let date: Date; let value: Double; let trend: Double?; let odd: Bool }

/// Body: any measure over time with a trend line, your goal, every reading, and adding one by hand or from a scale screenshot.
struct BodyView: View {
    @State private var metric = "weight"
    @State private var range = 90
    @State private var entry: JSON?
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
                    ForEach(recent.indices, id: \.self) { i in
                        let r = recent[i]
                        Button { entry = r } label: {
                            HStack {
                                Text(DayKey.date(str(r["day"])).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.subheadline)
                                Spacer()
                                Text(Self.metrics.compactMap { x in pos(r[x.key]).map { "\(Fmt.one($0))\(x.unit == "%" ? "%" : x.unit.isEmpty ? "" : " \(x.unit)")" } }.prefix(3).joined(separator: " · "))
                                    .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions { Button(role: .destructive) { store.deleteBody(str(r["day"])) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
            Section {
                NavigationLink { WebScreen(view: "body", pushed: true).navigationTitle("Scale imports").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Scale imports and connections", systemImage: "link")
                }
            } footer: { Text("Import a CSV from your scale's app, or connect a Shortcut so readings arrive on their own.") }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Body")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.pullBody() }
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
        let now = last?.trend ?? last?.value
        let change = (now != nil && first != nil) ? now! - (first!.trend ?? first!.value) : nil
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: m.key == "weight" && last?.trend != nil ? "Trend weight" : m.name, color: Theme.heroLabel)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(now.map { Fmt.one($0) } ?? "–").font(.system(size: 44, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text(m.unit).font(.headline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let change, pts.count > 1 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(change > 0 ? "+" : change < 0 ? "−" : "")\(Fmt.one(abs(change)))\(m.unit.isEmpty || m.unit == "%" ? m.unit : " \(m.unit)")")
                        .font(.title3.weight(.heavy)).foregroundStyle(m.key == "muscle" ? (change >= 0 ? Color.green : Theme.warn) : (change <= 0 ? Color.green : Theme.warn))
                    Text(range > 400 ? "since you started" : "in \(rangeText)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rangeText: String { [30: "a month", 90: "3 months", 180: "6 months", 365: "a year"][range] ?? "" }

    private func chart(_ pts: [BodyPoint], _ m: (key: String, name: String, unit: String)) -> some View {
        let goal = m.key == "weight" ? pos(store.doc["goalWeight"]) : nil
        let vals = pts.map(\.value) + (goal.map { [$0] } ?? [])
        let lo = (vals.min() ?? 0), hi = (vals.max() ?? 1), pad = max(0.5, (hi - lo) * 0.15)
        return Chart {
            ForEach(pts) { p in
                PointMark(x: .value("Day", p.date), y: .value(m.name, p.value))
                    .foregroundStyle(p.odd ? Color.secondary.opacity(0.4) : Theme.accent.opacity(0.55)).symbolSize(p.odd ? 18 : 26)
            }
            ForEach(pts.filter { $0.trend != nil }) { p in
                LineMark(x: .value("Day", p.date), y: .value("Trend", p.trend ?? 0)).foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round)).interpolationMethod(.catmullRom)
            }
            if let goal { RuleMark(y: .value("Goal", goal)).foregroundStyle(Color.green.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4])).annotation(position: .top, alignment: .leading) { Text("Goal").font(.caption2.weight(.bold)).foregroundStyle(.green) } }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .frame(height: 210)
        .overlay { if pts.isEmpty { Text("No readings in this range").font(.footnote).foregroundStyle(.secondary) } }
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
                for f in fields { if let v = pos(row[f.0]) { values[f.0] = Fmt.one(v) } }
            }
            .onChange(of: picked) { _, item in Task { await read(item) } }
        }
    }

    private var parsed: JSON {
        var out = JSON()
        for f in fields { if let v = Double((values[f.0] ?? "").replacingOccurrences(of: ",", with: ".")), v > 0 { out[f.0] = (v * 10).rounded() / 10 } }
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
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data), let part = Gemini.imagePart(img) else { return }
        reading = true; problem = nil
        defer { reading = false }
        var props = JSON()
        for f in fields { props[f.0] = ["type": "number", "nullable": true, "description": "\(f.1) in \(f.2), if shown"] as JSON }
        props["date"] = ["type": "string", "nullable": true, "description": "The reading's date as YYYY-MM-DD, if shown"] as JSON
        let schema: JSON = ["type": "object", "properties": props, "required": Array(props.keys)]
        do {
            let a = try await Gemini.ask(schema: schema, parts: [part, ["text": "This is a screenshot from a smart scale's app. Read the body measurements shown. Leave anything not shown as null."]], quick: true)
            for f in fields { if let v = pos(a[f.0]) { values[f.0] = Fmt.one(v) } }
            if let d = a["date"] as? String, DayKey.string(DayKey.date(d)) == d, DayKey.date(d) <= Date() { date = DayKey.date(d) }   // only a real date, never a guess
            if fields.allSatisfy({ pos(a[$0.0]) == nil }) { problem = "Couldn't find any readings in that picture." }
        } catch { problem = error.localizedDescription }
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
