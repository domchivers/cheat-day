import PhotosUI
import SwiftUI

/// Weigh in, the one sheet for adding a reading (and changing one): type it, read it from a screenshot of your
/// scale's app, or let Apple Health bring it in. Weight, when it was taken, body fat and the rest.
struct WeighInSheet: View {
    enum Way: String, CaseIterable, Identifiable { case type = "Type it", screenshot = "Screenshot", health = "Apple Health"; var id: String { rawValue } }
    @Environment(\.dismiss) private var dismiss
    @State private var way = Way.type
    @State private var kg: Double
    @State private var text: String
    @State private var others: [String: String] = [:]   // body fat, muscle, water and the rest, as typed
    @State private var more = false
    @State private var picked: PhotosPickerItem?
    @State private var reading = false
    @State private var problem: String?
    @State private var note: String?
    @State private var when: Date   // when the scale took it: now, or the screenshot's date and time
    @State private var checking = false
    private let editing: String?    // the day of a reading being changed
    private var store: Store { Store.shared }

    static let extras: [(key: String, name: String, unit: String)] = [
        ("muscle", "Muscle", "kg"), ("water", "Water", "%"), ("bone", "Bone", "kg"), ("visceral", "Visceral fat", "level"), ("age", "Body age", "years")
    ]

    /// A new weigh-in, or (with a row) changing that day's reading.
    init(row: JSON? = nil) {
        let start = row.flatMap { pos($0["weight"]) } ?? Store.shared.latestWeight?.kg ?? 75
        _kg = State(initialValue: start)
        _text = State(initialValue: Fmt.kg(start))
        let day = row.map { str($0["day"]) } ?? ""
        editing = day.isEmpty ? nil : day
        let at = row.flatMap { ISO.date(str($0["takenAt"])) } ?? (day.isEmpty ? nil : DayKey.date(day).addingTimeInterval(8 * 3600))
        _when = State(initialValue: at ?? Date())
        var o: [String: String] = [:]
        if let row { for k in ["fat"] + Self.extras.map(\.key) { if let v = pos(row[k]) { o[k] = Fmt.kg(v) } } }
        _others = State(initialValue: o)
        _more = State(initialValue: Self.extras.contains { o[$0.key] != nil })
    }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Section {
                        Picker("How", selection: $way) { ForEach(Way.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.clear)
                }
                switch way {
                case .type: typeIt
                case .screenshot: screenshot
                case .health: health
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .sensoryFeedback(.selection, trigger: kg)
            .onChange(of: picked) { _, item in Task { await read(item) } }
            .keyboardDone()
            .navigationTitle(editing == nil ? "Weigh in" : "Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if way == .type { ToolbarItem(placement: .topBarTrailing) { Button("Save") { save(); dismiss() }.fontWeight(.bold) } }
            }
        }
    }

    @ViewBuilder private var typeIt: some View {
        Section {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("kg", text: $text)
                        .keyboardType(.decimalPad).multilineTextAlignment(.center)
                        .font(.system(size: 60, weight: .heavy, design: .rounded)).fixedSize()   // sized to the number, so "kg" sits beside it
                        .onChange(of: text) { _, t in if let v = Double(t.replacingOccurrences(of: ",", with: ".")), v > 20, v < 400 { kg = v } }
                    Text("kg").font(.title2.weight(.bold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ForEach([-0.5, -0.1, 0.1, 0.5], id: \.self) { step in
                        Button(step > 0 ? "+\(String(format: "%.1f", step))" : String(format: "%.1f", step).replacingOccurrences(of: "-", with: "−")) {
                            kg = Fmt.kg2(kg + step); text = Fmt.kg(kg)
                        }
                        .font(.headline).buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                }
                if let note { Label(note, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.accent) }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
        Section {
            DatePicker("When", selection: $when, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            field("fat", "Body fat (optional)", "%")
            if more {
                ForEach(Self.extras, id: \.key) { f in field(f.key, f.name, f.unit) }
            } else {
                Button { withAnimation { more = true } } label: { Label("Muscle, water and more", systemImage: "plus") }
            }
        } footer: {
            if editing == nil, let last = store.latestWeight { Text("Last: \(Fmt.kg(last.kg)) kg, \(Store.when(last.day)).") }
        }
    }

    private func field(_ key: String, _ name: String, _ unit: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            TextField("0.0", text: Binding(get: { others[key] ?? "" }, set: { others[key] = $0 }))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80).font(.body.weight(.semibold))
            Text(unit).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
        }
    }

    @ViewBuilder private var screenshot: some View {
        Section {
            PhotosPicker(selection: $picked, matching: .images) {
                Label(reading ? "Reading the screenshot…" : "Choose a screenshot of your scale's app", systemImage: "photo.on.rectangle")
                    .font(.headline)
            }
            .disabled(reading)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
        } footer: { Text("It reads the weight, body fat and the rest, and the date and time the scale took it. You check it before saving.") }
    }

    @ViewBuilder private var health: some View {
        if HealthSync.on {
            Section {
                Label("Connected", systemImage: "heart.fill").foregroundStyle(.pink)
                if let w = store.lastWeighIn { LabeledContent("Latest", value: "\(Fmt.kg(w.kg)) kg, \(Store.whenTaken(day: w.day, at: w.at))") }
                Button(checking ? "Checking…" : "Check for new weigh-ins") {
                    checking = true
                    Task {
                        let n = await HealthSync.pull(force: true)
                        checking = false
                        problem = n == 0 ? "Nothing new in Apple Health yet." : "\(n) new weigh-in\(n == 1 ? "" : "s") brought in."
                    }
                }
                .disabled(checking)
                if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("Weigh-ins your scale's app saves to Apple Health come in by themselves. If one's missing, open your scale's app once so it passes it on.") }
        } else {
            Section {
                ScaleConnectRow()
            } footer: { Text("VeSync, Withings, Eufy, Renpho, Fitbit, Garmin and others save to Apple Health: connect it and every weigh-in arrives on its own.") }
        }
    }
}

extension WeighInSheet {
    /// Saved on the day it was taken, with the time the scale took it (not when it was added here).
    fileprivate func save() {
        var row = JSON()
        row["weight"] = Fmt.kg2(kg)
        for (k, v) in others { if let n = Double(v.replacingOccurrences(of: ",", with: ".")), n > 0 { row[k] = Fmt.kg2(n) } }
        let day = DayKey.string(when)
        if let editing, editing != day { store.deleteBody(editing) }   // moved to another day
        row["day"] = day
        row["takenAt"] = ISO8601DateFormatter().string(from: when)
        row["updatedAt"] = ISO.now()
        store.saveBody(row)
    }

    /// A screenshot fills in the reading, then it's back to checking it before saving.
    fileprivate func read(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
        reading = true; problem = nil
        defer { reading = false }
        do {
            let a = try await BodyReader.read(img)
            if let w = pos(a["weight"]) { kg = w; text = Fmt.kg(w) }
            if let t = ISO.date(str(a["takenAt"])) { when = t }
            else if let d = a["day"] as? String, d != store.today { when = DayKey.date(d).addingTimeInterval(8 * 3600) }   // the morning, when no time's shown
            for k in ["fat"] + Self.extras.map(\.key) { if let v = pos(a[k]) { others[k] = Fmt.kg(v) } }
            if Self.extras.contains(where: { others[$0.key] != nil }) { more = true }
            note = "Read from your screenshot: check it and Save."
            withAnimation { way = .type }
        } catch { problem = error.localizedDescription }
    }
}
