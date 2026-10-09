import SwiftUI

/// What the amount screen works on: a food, maybe a starting amount, maybe the line being changed.
struct EditTarget: Identifiable, Hashable {
    let id = UUID()
    let basis: JSON
    let kcal: Double?
    let editId: String?
    let meal: String
    static func == (a: EditTarget, b: EditTarget) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A web screen opened in a sheet (scanning, typing numbers, the assistant) until those are native too.
struct WebFlow: Identifiable {
    let id = UUID()
    let view: String
    let opts: JSON
    let title: String
}

private struct MealChoice: Identifiable { let id: String }
private struct Line: Identifiable { let id: String; let item: JSON }

struct TodayView: View {
    @State private var offset = 0
    @State private var addChoice: MealChoice?
    @State private var editing: EditTarget?
    @State private var flow: WebFlow?
    @State private var pastItem: JSON?
    @State private var showPast = false
    private var store: Store { Store.shared }

    private var date: String { DayKey.shift(store.today, days: offset) }
    private var items: [JSON] { offset == 0 ? store.todayItems : (store.pastDay(date)?.items ?? []) }
    private var budget: Double { offset == 0 ? store.budgetToday : (store.pastDay(date)?.budget ?? store.baseBudget(date)) }

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
                Section { hero }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                ForEach(Meals.all, id: \.self) { meal in mealSection(meal) }
                if let e = store.syncError {
                    Section { Label("Not synced: \(e)", systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.secondary) }
                }
                Color.clear.frame(height: 70).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .refreshable { await store.sync() }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) { if offset == 0 { addButton } }
            .sensoryFeedback(.success, trigger: store.todayItems.count)
            .sheet(item: $addChoice) { c in
                AddSheet(meal: c.id) { f in
                    addChoice = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { flow = f }
                }
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $editing) { t in
                NavigationStack { AmountView(target: t) { editing = nil } }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $flow) { f in WebFlowSheet(flow: f) }
            .onReceive(NotificationCenter.default.publisher(for: .webDone)) { _ in
                guard flow != nil else { return }
                flow = nil
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await store.sync() }
            }
            .confirmationDialog(str(pastItem?["name"]), isPresented: $showPast, titleVisibility: .visible) {
                Button("Add to today") {
                    if let it = pastItem { store.add(FoodMath.basisOf(it), kcal: num(it["kcal"]) ?? 0, meal: Meals.now) }
                    withAnimation(.snappy) { offset = 0 }
                }
            } message: { Text("\(Fmt.int(num(pastItem?["kcal"]) ?? 0)) kcal, the same amount as that day") }
        }
    }

    // MARK: header and hero

    private var header: some View {
        HStack {
            Button { withAnimation(.snappy) { offset -= 1 } } label: {
                Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 40).background(Color(.secondarySystemBackground), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.title.bold()).contentTransition(.opacity)
                Text(DayKey.date(date).formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
            }
            Spacer()
            Button { withAnimation(.snappy) { offset = min(0, offset + 1) } } label: {
                Image(systemName: "chevron.right").font(.headline).frame(width: 40, height: 40).background(Color(.secondarySystemBackground), in: Circle())
            }
            .opacity(offset == 0 ? 0.3 : 1).disabled(offset == 0)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch offset {
        case 0: return "Today"
        case -1: return "Yesterday"
        default: return DayKey.date(date).formatted(.dateTime.weekday(.wide))
        }
    }

    private var hero: some View {
        let eaten = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let left = budget - eaten
        let protein = store.macros(items).p
        let lit = budget > 0 ? min(12, Int((eaten / budget * 12).rounded())) : 0
        return VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: left >= 0 ? "Left to eat" : "Over today", color: Theme.heroLabel)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.int(abs(left)))
                    .font(.system(size: 62, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: abs(left)))
                Text("kcal").font(.headline).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(i < lit ? (eaten > budget ? Theme.warn : Theme.accent) : Theme.track).frame(height: 7)
                }
            }
            HStack {
                stat(Fmt.int(eaten), "eaten")
                Spacer()
                stat(store.proteinGoal.map { "\(Int(protein.rounded())) / \(Int($0))g" } ?? "\(Int(protein.rounded()))g", "protein")
                Spacer()
                stat(Fmt.int(budget), "budget")
            }
        }
        .padding(20)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 16)
        .animation(.snappy, value: eaten)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            withAnimation(.snappy) { offset = v.translation.width > 0 ? offset - 1 : min(0, offset + 1) }
        })
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.weight(.heavy)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: meals

    @ViewBuilder
    private func mealSection(_ meal: String) -> some View {
        let lines = items.filter { Meals.of($0) == meal }.map { Line(id: str($0["id"]).isEmpty ? UUID().uuidString : str($0["id"]), item: $0) }
        let total = lines.reduce(0) { $0 + (num($1.item["kcal"]) ?? 0) }
        let again = offset == 0 && lines.isEmpty ? (store.pastDay(DayKey.shift(store.today, days: -1))?.items.filter { Meals.of($0) == meal } ?? []) : []
        if offset == 0 || !lines.isEmpty {
            Section {
                ForEach(lines) { line in
                    Button { tap(line.item, meal: meal) } label: { FoodRow(item: line.item) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if offset == 0 {
                                Button(role: .destructive) { withAnimation { store.delete(line.id) } } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if offset == 0 {
                    Button { addChoice = MealChoice(id: meal) } label: {
                        Label("Add \(meal.lowercased())", systemImage: "plus.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
            } header: {
                HStack {
                    Text(meal).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                    Spacer()
                    if total > 0 {
                        Text("\(Fmt.int(total)) kcal").font(.subheadline.weight(.bold)).foregroundStyle(.secondary).textCase(nil)
                    } else if let first = again.first {
                        Button {
                            for it in again { store.add(FoodMath.basisOf(it), kcal: num(it["kcal"]) ?? 0, meal: meal) }
                        } label: {
                            Label("\(str(first["name"])) again?", systemImage: "arrow.counterclockwise").font(.caption.weight(.bold)).lineLimit(1)
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).textCase(nil)
                    }
                }
            }
        }
    }

    private func tap(_ item: JSON, meal: String) {
        if offset == 0 {
            editing = EditTarget(basis: FoodMath.basisOf(item), kcal: num(item["kcal"]), editId: str(item["id"]), meal: meal)
        } else {
            pastItem = item; showPast = true
        }
    }

    private var addButton: some View {
        Button { addChoice = MealChoice(id: Meals.now) } label: {
            Image(systemName: "plus").font(.title2.weight(.bold)).foregroundStyle(.black)
                .frame(width: 62, height: 62).background(Theme.accent, in: Circle())
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        }
        .padding(.trailing, 22).padding(.bottom, 16)
        .accessibilityLabel("Add food")
    }
}

struct FoodRow: View {
    let item: JSON
    var body: some View {
        let kcal = num(item["kcal"]) ?? 0
        HStack(spacing: 12) {
            FoodDot(name: str(item["name"]))
            VStack(alignment: .leading, spacing: 2) {
                Text(str(item["name"])).font(.body.weight(.semibold)).lineLimit(2)
                let detail = FoodMath.amountText(item, kcal: kcal)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Text(Fmt.int(kcal)).font(.body.weight(.bold)).monospacedDigit()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// How much: count, weigh or calories, with the meal, then add (or save a change).
struct AmountView: View {
    enum Mode: String, CaseIterable, Identifiable { case count = "Count", grams = "Weigh", kcal = "Calories"; var id: String { rawValue } }

    let target: EditTarget
    let finish: () -> Void
    @State private var meal: String
    @State private var mode: Mode
    @State private var kcal: Double
    @State private var gramsText = ""
    @State private var kcalText = ""
    private var store: Store { Store.shared }
    private let conv: FoodMath.Conv

    init(target: EditTarget, finish: @escaping () -> Void) {
        self.target = target
        self.finish = finish
        let c = FoodMath.conv(target.basis)
        conv = c
        _meal = State(initialValue: target.meal)
        let start: Mode = c.countKcal != nil && (c.countLabel != "serving" || c.kcalPer100 == nil) ? .count : (c.kcalPer100 != nil ? .grams : .kcal)
        _mode = State(initialValue: start)
        let fallback = c.countKcal ?? c.kcalPer100.map { k in k * (pos(target.basis["servingSize"]) ?? 100) / 100 } ?? 0
        _kcal = State(initialValue: target.kcal ?? fallback)
    }

    private var name: String { str(target.basis["name"]) }
    private var modes: [Mode] { [conv.countKcal != nil ? Mode.count : nil, conv.kcalPer100 != nil ? Mode.grams : nil, Mode.kcal].compactMap { $0 } }
    private var unit: String { str(target.basis["unit"]).isEmpty ? "g" : str(target.basis["unit"]) }
    private var leftAfter: Double {
        let others = store.todayItems.filter { str($0["id"]) != (target.editId ?? "") }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return store.budgetToday - others - kcal
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        FoodDot(name: name, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.title3.bold()).lineLimit(2)
                            if let per = perText { Text(per).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    Text(Fmt.int(kcal))
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText(value: kcal))
                        .padding(.top, 10)
                    Text(leftAfter >= 0 ? "kcal · \(Fmt.int(leftAfter)) left after this" : "kcal · \(Fmt.int(-leftAfter)) over your day")
                        .font(.footnote.weight(.semibold)).foregroundStyle(leftAfter >= 0 ? Color.secondary : Theme.warn)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                if modes.count > 1 {
                    Picker("How", selection: $mode) { ForEach(modes) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                }
                switch mode {
                case .count: countControls
                case .grams: gramControls
                case .kcal: kcalControls
                }
            }
            Section("Meal") {
                Picker("Meal", selection: $meal) { ForEach(Meals.all, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            }
            Section {
                Button { save() } label: {
                    Text(target.editId == nil ? "Add to \(meal)" : "Save").font(.headline).frame(maxWidth: .infinity)
                }
                .disabled(kcal <= 0)
                if let id = target.editId {
                    Button(role: .destructive) { store.delete(id); finish() } label: { Text("Remove from today").frame(maxWidth: .infinity) }
                }
            }
        }
        .navigationTitle(target.editId == nil ? "How much?" : "Change amount")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: kcal)
        .sensoryFeedback(.selection, trigger: kcal)
        .onAppear { syncTexts() }
    }

    private var perText: String? {
        if let c = conv.countKcal, let label = conv.countLabel { return "\(Fmt.int(c)) kcal per \(label)" }
        if let k = conv.kcalPer100 { return "\(Fmt.int(k)) kcal per 100 \(unit)" }
        return nil
    }

    @ViewBuilder private var countControls: some View {
        if let each = conv.countKcal, each > 0 {
            let count = kcal / each
            let label = conv.countLabel ?? "piece"
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([0.5, 1, 2, 3, 4, 5, 6], id: \.self) { n in
                        chip(n == 0.5 ? "½" : Fmt.one(n), on: abs(count - n) < 0.05) { kcal = n * each; syncTexts() }
                    }
                }
            }
            Stepper("\(Fmt.one(count)) \(FoodMath.plural(count, label))", onIncrement: { kcal = (count + 0.5) * each; syncTexts() },
                    onDecrement: { kcal = max(0.5, count - 0.5) * each; syncTexts() })
        }
    }

    @ViewBuilder private var gramControls: some View {
        if let k100 = conv.kcalPer100, k100 > 0 {
            let grams = kcal / k100 * 100
            let serving = pos(target.basis["servingSize"])
            let options: [Double] = serving.map { s in [s / 2, s, s * 1.5, s * 2].map { nice($0) } } ?? (unit == "ml" ? [100, 250, 330, 500] : [50, 100, 150, 200])
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(Set(options)).sorted(), id: \.self) { g in
                        chip("\(Fmt.one(g)) \(unit)", on: abs(grams - g) < 0.6) { kcal = g * k100 / 100; syncTexts() }
                    }
                }
            }
            HStack {
                TextField("Amount", text: $gramsText).keyboardType(.decimalPad)
                    .onChange(of: gramsText) { _, t in if let g = Double(t.replacingOccurrences(of: ",", with: ".")), abs(g - grams) > 0.05 { kcal = g * k100 / 100 } }
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private var kcalControls: some View {
        HStack {
            TextField("Calories", text: $kcalText).keyboardType(.numberPad)
                .onChange(of: kcalText) { _, t in if let k = Double(t), abs(k - kcal) > 0.5 { kcal = k } }
            Text("kcal").foregroundStyle(.secondary)
        }
    }

    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.subheadline.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 9)
                .background(on ? Theme.accent : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func nice(_ g: Double) -> Double { g < 50 ? (g / 5).rounded() * 5 : g < 200 ? (g / 10).rounded() * 10 : (g / 25).rounded() * 25 }

    private func syncTexts() {
        if let k100 = conv.kcalPer100, k100 > 0 { gramsText = Fmt.one(kcal / k100 * 100) }
        kcalText = String(Int(kcal.rounded()))
    }

    private func save() {
        if let id = target.editId { store.edit(id, kcal: kcal, meal: meal) } else { store.add(target.basis, kcal: kcal, meal: meal) }
        finish()
    }
}
