import SwiftUI

extension Store {
    /// A fair size for one meal: what's left today, shared across the meals still to come (snacks always keep a
    /// little), so a lunch idea leaves room for dinner. Never more than about a third over that meal's usual share.
    func mealTarget(_ meal: String) -> (kcal: Double, protein: Double?) {
        let share = ["Breakfast": 0.25, "Lunch": 0.30, "Dinner": 0.35, "Snacks": 0.10]
        let at = Meals.all.firstIndex(of: meal) ?? 0
        let upcoming = Meals.all.enumerated().filter { i, m in
            i >= at && (m == meal || m == "Snacks" || !todayItems.contains { Meals.of($0) == m })
        }.map(\.element)
        let part = (share[meal] ?? 0.3) / max(0.1, upcoming.reduce(0) { $0 + (share[$1] ?? 0) })
        let left = max(0, budgetToday - eaten)
        let kcal = min(left * part, budgetToday * (share[meal] ?? 0.3) * 1.3)
        let protein = proteinGoal.map { max(0, $0 - macros(todayItems).p) * part }
        return ((kcal / 10).rounded() * 10, protein.map { $0.rounded() })
    }

    /// What you've had at a meal over the last four weeks, most often first: the planner's sense of your style
    /// (Asian dinners, toast breakfasts) and the ingredients you already buy.
    func mealHistory(_ meal: String, days: Int = 28) -> [(name: String, days: Int, kcal: Double)] {
        let since = DayKey.shift(today, days: -days)
        let all: [(String, [JSON])] = [(today, todayItems)] + list(doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < today }.map { (str($0["date"]), list($0["items"])) }
        var seen: [String: (name: String, days: Set<String>, kcal: Double)] = [:]
        for (date, items) in all {
            for it in items where Meals.of(it) == meal {
                let n = str(it["name"]).trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { continue }
                var e = seen[n.lowercased(), default: (n, [], 0)]
                e.days.insert(date); e.kcal = max(e.kcal, num(it["kcal"]) ?? 0)
                seen[n.lowercased()] = e
            }
        }
        return seen.values.sorted { ($0.days.count, $1.name) > ($1.days.count, $0.name) }.map { ($0.name, $0.days.count, $0.kcal) }
    }
}

/// The Plan button on a normal day: the meal it's time for, what you usually have then (with a lighter pick where
/// there is one), how much cooking you fancy and what's in the fridge, then ideas in your usual style to log or cook.
struct MealPlannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var meal = Meals.byTime(Calendar.current.component(.hour, from: Date())) == "Snacks" ? "Dinner" : Meals.byTime(Calendar.current.component(.hour, from: Date()))
    @State private var cooking = ""
    @AppStorage("pantry") private var pantry = ""
    @AppStorage("pantry.scans") private var scansJSON = "[]"   // foods scanned in, with their label numbers
    @State private var scanning: PantryScanSheet.Mode?
    @State private var ideas: [JSON] = []
    @State private var busy = false
    @State private var problem: String?
    @State private var added: Set<String> = []
    @State private var open: IdeaRef?
    @State private var cheat = false
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }

    private static let cookChoices = ["No cooking", "Quick, 15 min", "Happy to cook"]
    private var left: Double { max(0, store.budgetToday - store.eaten) }
    private var proteinLeft: Double? { store.proteinGoal.map { max(0, $0 - store.macros(store.todayItems).p) } }
    private var history: [(name: String, days: Int, kcal: Double)] { store.mealHistory(meal) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Meal", selection: $meal) { ForEach(["Breakfast", "Lunch", "Dinner"], id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.segmented)
                        .onChange(of: meal) { _, _ in ideas = []; problem = nil }
                    let t = store.mealTarget(meal)
                    Text("Aim for about \(Fmt.int(t.kcal)) kcal\(t.protein.map { " · \(Int($0)) g protein" } ?? "") · \(Fmt.int(left)) left today")
                        .font(.subheadline).foregroundStyle(.secondary)
                    usual
                    Eyebrow(text: "How much cooking?", color: Theme.heroLabel).padding(.top, 4)
                    Flow { ForEach(Self.cookChoices, id: \.self) { c in Chip(text: c, on: cooking == c) { cooking = c } } }
                    Eyebrow(text: "In your fridge and cupboard", color: Theme.heroLabel).padding(.top, 4)
                    TextField("chicken, rice, peppers, eggs, feta", text: $pantry, axis: .vertical)
                        .lineLimit(2...4).focused($typing)
                        .padding(12).background(Theme.hero, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    cupboard
                    Button { typing = false; Task { await suggest() } } label: {
                        Label(busy ? "Thinking…" : pantry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give me ideas" : "What can I make?", systemImage: "sparkles")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(busy)
                    .id("go")
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
                    ForEach(ideas.indices, id: \.self) { i in idea(ideas[i]) }
                    Button { cheat = true } label: { Label("Plan your cheat day", systemImage: "arrow.right").font(.subheadline.weight(.semibold)) }
                        .frame(maxWidth: .infinity).padding(.top, 10)
                        .id("link")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: typing) { _, t in
                guard t else { return }
                // the keyboard would cover the button under the box: bring it up with the box
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { proxy.scrollTo(ideas.isEmpty ? "link" : "go", anchor: .bottom) } }
            }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Plan \(meal.lowercased())").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $open) { r in RecipeSheet(idea: r.idea) }
            .sheet(item: $scanning) { m in
                PantryScanSheet(mode: m) { items in
                    // newest first; scanning the same food again replaces the old one
                    let names = Set(items.map { $0.name.lowercased() })
                    withAnimation { scansJSON = PantryItem.Saved.save(items + scans.filter { !names.contains($0.name.lowercased()) }) }
                }
            }
            .sheet(isPresented: $cheat) { CheatDayView().presentationDragIndicator(.visible) }
            .onAppear {
                if cooking.isEmpty {
                    switch str(store.habits["cook"]) { case "love": cooking = Self.cookChoices[2]; case "hate": cooking = Self.cookChoices[0]; default: cooking = Self.cookChoices[1] }
                }
            }
        }
    }

    private var scans: [PantryItem] { PantryItem.Saved.load(scansJSON) }

    /// Scan a barcode or snap a label to add a food with its real numbers; the ones you've added, to remove.
    @ViewBuilder private var cupboard: some View {
        HStack(spacing: 8) {
            Button { typing = false; scanning = .barcode } label: {
                Label("Scan a barcode", systemImage: "barcode.viewfinder").font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.hero, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button { typing = false; scanning = .photo } label: {
                Label("Photo of a label", systemImage: "camera.fill").font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.hero, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .buttonStyle(.plain).foregroundStyle(Theme.accent)
        ForEach(scans) { s in
            HStack(spacing: 10) {
                FoodDot(name: s.name, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    // tap the name to change it (a label photo often doesn't say what it is)
                    TextField("Name it", text: Binding(get: { s.name }, set: { v in
                        scansJSON = PantryItem.Saved.save(scans.map { x in
                            var y = x
                            if y.id == s.id { y.name = v }
                            return y
                        })
                    }))
                    .font(.subheadline.weight(.semibold))
                    Text(s.line).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { withAnimation { scansJSON = PantryItem.Saved.save(scans.filter { $0.id != s.id }) } } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Remove \(s.name)")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// What you usually have at this meal, each with a lighter pick from the food list when there's a real saving.
    @ViewBuilder private var usual: some View {
        let top = history.filter { $0.days >= 2 }.prefix(3)
        if !top.isEmpty {
            Eyebrow(text: "You usually have", color: Theme.heroLabel).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.offset) { i, h in
                    let pick = Swaps.pick(for: h.name, kcal: h.kcal)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            FoodDot(name: h.name, size: 26)
                            Text(h.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text("\(h.days)× in 4 weeks").font(.caption).foregroundStyle(.secondary)
                        }
                        if let p = pick {
                            Label("Try \(p.name): saves \(Fmt.int(p.saves)) kcal. \(p.why).", systemImage: "arrow.triangle.swap")
                                .font(.caption).foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(12)
                    if i < top.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func idea(_ m: JSON) -> some View {
        let name = str(m["name"]), kcal = (num(m["kcal"]) ?? 0).rounded()
        return HStack(spacing: 12) {
            Button { open = IdeaRef(id: name, idea: m) } label: {
                HStack(spacing: 12) {
                    FoodDot(name: name, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        Text("\(Fmt.int(kcal)) kcal · \(Int(num(m["protein"]) ?? 0)) g protein\(num(m["minutes"]).map { " · \(Int($0)) min" } ?? "") · recipe")
                            .font(.caption).foregroundStyle(.secondary)
                        if !str(m["why"]).isEmpty { Text(str(m["why"])).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                        if !str(m["uses"]).isEmpty { Text(str(m["uses"])).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                        if m["fromLabels"] as? Bool == true {
                            Text("FROM YOUR LABELS").font(.caption2.weight(.heavy)).foregroundStyle(Color(red: 0.36, green: 0.82, blue: 0.56))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(red: 0.36, green: 0.82, blue: 0.56).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                store.add(Assistant.basis(name: name, kcal: kcal, grams: nil, p: num(m["protein"]) ?? 0, c: num(m["carbs"]) ?? 0, f: num(m["fat"]) ?? 0), kcal: kcal, meal: meal)
                withAnimation { _ = added.insert(name) }
            } label: {
                Image(systemName: added.contains(name) ? "checkmark.circle.fill" : "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless).disabled(added.contains(name))
            .accessibilityLabel("Add \(name) to \(meal.lowercased())")
        }
        .padding(12)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The scanned foods' parts worked out from their labels (grams × the printed numbers), not the AI's sums, and the
    /// idea's totals added up from its ingredients; with the grams of each scanned food listed under the idea.
    static func withLabels(_ idea: JSON, _ scanned: [PantryItem]) -> JSON {
        let parts = list(idea["ingredients"])
        guard !parts.isEmpty else { return idea }
        var m = idea, k = 0.0, p = 0.0, c = 0.0, f = 0.0, used: [String] = []
        for x in parts {
            let g = num(x["grams"]) ?? 0, i = Int(num(x["label"]) ?? 0)
            if i >= 1, i <= scanned.count, g > 0 {
                let s = scanned[i - 1]
                k += s.kcal100 * g / 100; p += (s.p100 ?? 0) * g / 100; c += (s.c100 ?? 0) * g / 100; f += (s.f100 ?? 0) * g / 100
                used.append("\(Fmt.int(g)) g \(s.name)")
            } else {
                k += num(x["kcal"]) ?? 0; p += num(x["protein"]) ?? 0; c += num(x["carbs"]) ?? 0; f += num(x["fat"]) ?? 0
            }
        }
        guard k > 0 else { return idea }
        m["kcal"] = k.rounded(); m["protein"] = p.rounded(); m["carbs"] = c.rounded(); m["fat"] = f.rounded()
        if !used.isEmpty { m["uses"] = used.joined(separator: ", "); m["fromLabels"] = true }
        return m
    }

    private func suggest() async {
        busy = true; problem = nil
        defer { busy = false }
        let target = store.mealTarget(meal)
        let had = history.prefix(20).map { "\($0.name) (\($0.days)×)" }.joined(separator: ", ")
        let cuisines = (store.habits["cuisines"] as? [String] ?? []).joined(separator: ", ")
        let cook = cooking == Self.cookChoices[0] ? "No cooking: assembling, shop-bought or a microwave only."
                 : cooking == Self.cookChoices[2] ? "Happy to cook properly." : "Quick: 15 minutes or so."
        let have = pantry.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanned = scans
        let ingredient: JSON = ["type": "object", "properties": [
            "name": ["type": "string"] as JSON, "grams": ["type": "number"] as JSON,
            "label": ["type": "integer", "description": "The number of the scanned food this is (1, 2…), or 0 if it isn't one"] as JSON,
            "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON, "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON
        ] as JSON, "required": ["name", "grams", "label", "kcal", "protein", "carbs", "fat"]]
        let schema: JSON = ["type": "object", "properties": [
            "ideas": ["type": "array", "items": ["type": "object", "properties": [
                "name": ["type": "string"] as JSON, "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON,
                "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON, "minutes": ["type": "number"] as JSON,
                "why": ["type": "string", "description": "Under 14 words: why it suits them"] as JSON,
                "ingredients": ["type": "array", "items": ingredient] as JSON
            ] as JSON, "required": ["name", "kcal", "protein", "carbs", "fat", "minutes", "why", "ingredients"]] as JSON] as JSON
        ] as JSON, "required": ["ideas"]]
        let labels = scanned.enumerated().map { "\($0.offset + 1). \($0.element.prompt)" }.joined(separator: "\n")
        let prompt = """
        Suggest 3 \(meal.lowercased()) ideas for someone in \(Plan.country), one portion each.
        Size each idea for this one meal: about \(Int(target.kcal)) kcal (between \(Int(target.kcal - 120)) and \(Int(target.kcal + 60))), not the whole day's \(Int(left)) kcal left: they still have other meals and snacks to come.\(target.protein.map { " Aim for around \(Int($0)) g protein each." } ?? " Lean high in protein.")
        What they've actually had for \(meal.lowercased()) over the last 4 weeks: \(had.isEmpty ? "nothing logged yet" : had).
        Match that style: if it's mostly one cuisine (Asian dinners, say), stay in it and use the ingredients and dishes they clearly buy, just lighter or better balanced. One idea can be a healthier take on something they have often.
        Cuisines they like: \(cuisines.isEmpty ? "not said" : cuisines). \(cook)
        \(have.isEmpty ? "" : "They have in: \(have). Make the ideas mostly from that, plus staples like oil, salt, sauces and spices.")
        \(labels.isEmpty ? "" : "They scanned these foods, with the numbers printed on their packs:\n\(labels)\nBuild the ideas around them where they fit, and for these use exactly those numbers.")
        List every ingredient with its grams and its own kcal, protein, carbs and fat; set label to the scanned food's number when it is one.
        Real dish names, numbers from standard reference values.
        """
        do {
            let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true, tries: 3)
            let got = list(a["ideas"]).map { i -> JSON in
                var c = i; c["meal"] = meal
                return Self.withLabels(c, scanned)
            }
            withAnimation(.snappy) { ideas = got }
            if got.isEmpty { problem = "No ideas came back. Try again." }
        } catch { problem = error.localizedDescription }
    }
}
