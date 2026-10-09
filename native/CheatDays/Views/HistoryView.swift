import SwiftUI

/// Weigh in: a big number you nudge, or type.
struct WeighInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kg: Double
    @State private var text: String
    private var store: Store { Store.shared }

    init() {
        let start = Store.shared.latestWeight?.kg ?? 75
        _kg = State(initialValue: start)
        _text = State(initialValue: String(format: "%.1f", start))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("kg", text: $text)
                        .keyboardType(.decimalPad).multilineTextAlignment(.center)
                        .font(.system(size: 64, weight: .heavy, design: .rounded)).frame(maxWidth: 220)
                        .onChange(of: text) { _, t in if let v = Double(t.replacingOccurrences(of: ",", with: ".")), v > 20, v < 400 { kg = v } }
                    Text("kg").font(.title2.weight(.bold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ForEach([-0.5, -0.1, 0.1, 0.5], id: \.self) { step in
                        Button(step > 0 ? "+\(String(format: "%.1f", step))" : String(format: "%.1f", step).replacingOccurrences(of: "-", with: "−")) {
                            kg = ((kg + step) * 10).rounded() / 10; text = String(format: "%.1f", kg)
                        }
                        .font(.headline).buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                }
                if let last = store.latestWeight {
                    Text("Last: \(String(format: "%.1f", last.kg)) kg, \(Store.when(last.day))").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.top, 30)
            .sensoryFeedback(.selection, trigger: kg)
            .navigationTitle("Weigh in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.weighIn(kg); dismiss() }.fontWeight(.bold) }
            }
        }
    }
}

private struct PastDay: Identifiable { let id: String; let items: [JSON]; let kcal: Double; let budget: Double }

/// Every day you've logged: a month calendar coloured by how it went, then each day with what you had.
struct HistoryView: View {
    @State private var month = DayKey.string(Date()).prefix(7).description
    @State private var openDay: String?
    @State private var added: String?
    private var store: Store { Store.shared }

    private var days: [PastDay] {
        var out: [PastDay] = []
        let d = store.day
        if str(d["date"]) != store.today, !list(d["items"]).isEmpty, let p = store.pastDay(str(d["date"])) { out.append(PastDay(id: str(d["date"]), items: p.items, kcal: p.kcal, budget: p.budget)) }
        for h in list(store.doc["history"]) where !list(h["items"]).isEmpty || (num(h["kcal"]) ?? 0) > 0 {
            out.append(PastDay(id: str(h["date"]), items: list(h["items"]), kcal: num(h["kcal"]) ?? 0, budget: num(h["budget"]) ?? store.baseBudget(str(h["date"]))))
        }
        return out.sorted { $0.id > $1.id }
    }

    var body: some View {
        let all = days
        let byDate = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ScrollViewReader { proxy in
            List {
                Section { calendar(byDate) { date in withAnimation { openDay = date; proxy.scrollTo(date, anchor: .top) } } }
                ForEach(all.prefix(90)) { day in
                    Section {
                        DisclosureGroup(isExpanded: Binding(get: { openDay == day.id }, set: { open in openDay = open ? day.id : (openDay == day.id ? nil : openDay) })) {
                            ForEach(Meals.all, id: \.self) { meal in
                                let its = day.items.filter { Meals.of($0) == meal }
                                if !its.isEmpty {
                                    HStack {
                                        Text(meal.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Copy to today") { copy(its, keepMeal: true, label: "\(Store.when(day.id))'s \(meal.lowercased())") }.font(.caption.weight(.bold)).buttonStyle(.borderless)
                                    }
                                    ForEach(its.indices, id: \.self) { i in
                                        Button { copy([its[i]], keepMeal: false, label: str(its[i]["name"])) } label: { FoodRow(item: its[i], hint: .add) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                            Button { copy(day.items, keepMeal: true, label: "the whole day") } label: { Label("Copy the whole day to today", systemImage: "doc.on.doc") }
                        } label: { dayHeader(day) }
                        .tint(.secondary)
                    }
                    .id(day.id)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .overlay(alignment: .bottom) {
                if let added {
                    Text("Added \(added) to today").font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 20).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dayHeader(_ day: PastDay) -> some View {
        let over = day.kcal > day.budget * 1.1, near = !over && day.kcal > day.budget
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Store.when(day.id) == "yesterday" ? "Yesterday" : DayKey.date(day.id).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.headline)
                Spacer()
                Text("\(Fmt.int(day.kcal)) / \(Fmt.int(day.budget))").font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(over || near ? Theme.warn : Theme.accent)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(over || near ? Theme.warn : Theme.accent).frame(width: g.size.width * min(1, day.budget > 0 ? day.kcal / day.budget : 0))
                }
            }
            .frame(height: 6)
            if openDay != day.id { Text(day.items.map { str($0["name"]) }.prefix(4).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            else { Text("Tap a food to add it to today").font(.footnote).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func calendar(_ byDate: [String: PastDay], pick: @escaping (String) -> Void) -> some View {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        let first = Calendar.current.date(from: DateComponents(year: parts.first ?? 2026, month: parts.last ?? 1, day: 1)) ?? Date()
        let count = Calendar.current.range(of: .day, in: .month, for: first)?.count ?? 30
        let lead = (Calendar.current.component(.weekday, from: first) + 5) % 7   // Monday first
        let todayKey = DayKey.string(Date())
        return VStack(spacing: 10) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(first.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.disabled(month >= String(todayKey.prefix(7)))
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 38) }
                ForEach(1...count, id: \.self) { n in
                    let date = "\(month)-\(String(format: "%02d", n))"
                    let rec = byDate[date]
                    let tone: Color = rec.map { $0.kcal <= $0.budget ? Theme.accent.opacity(0.35) : ($0.kcal <= $0.budget * 1.1 ? Theme.warn.opacity(0.35) : Color.red.opacity(0.3)) } ?? Color(.tertiarySystemFill).opacity(date > todayKey ? 0.3 : 1)
                    Button { if rec != nil { pick(date) } } label: {
                        Text("\(n)").font(.subheadline.weight(date == todayKey ? .heavy : .semibold)).frame(maxWidth: .infinity, minHeight: 38)
                            .background(tone, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(date == todayKey ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain).disabled(rec == nil)
                }
            }
        }
    }

    private func shift(_ by: Int) {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let d = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1] + by, day: 1)) else { return }
        month = String(DayKey.string(d).prefix(7))
    }

    private func copy(_ items: [JSON], keepMeal: Bool, label: String) {
        for it in items { store.add(FoodMath.basisOf(it), kcal: num(it["kcal"]) ?? 0, meal: keepMeal ? Meals.of(it) : Meals.now) }
        withAnimation { added = label }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { if added == label { added = nil } } }
    }
}
