import SwiftUI

/// Your meals: saved meals to add in one tap, build new ones, or save one of today's meals.
struct MealsView: View {
    @State private var editing: JSON?
    @State private var added: String?
    private var store: Store { Store.shared }

    private var meals: [JSON] {
        let favs = dict(store.doc["favs"])
        let all = list(store.doc["meals"])
        let fav = { (m: JSON) in (dict(favs["meal:" + str(m["id"])])["on"] as? Bool) == true }
        return all.filter(fav) + all.filter { !fav($0) }
    }

    var body: some View {
        List {
            let today = Meals.all.filter { m in store.todayItems.contains { Meals.of($0) == m } }
            Section {
                Button { editing = Self.blank() } label: { Label("Build a meal", systemImage: "plus.circle.fill") }
                ForEach(today, id: \.self) { m in
                    Button {
                        let items = store.todayItems.filter { Meals.of($0) == m }.map { it -> JSON in
                            var c = it; c["id"] = uid(); c.removeValue(forKey: "meal")
                            if pos(c["grams"]) == nil, let g = MealEditor.grams(it) { c["grams"] = g.rounded() }
                            return c
                        }
                        var meal = Self.blank(); meal["name"] = "My \(m.lowercased())"; meal["items"] = items
                        editing = meal
                    } label: { Label("Save today's \(m.lowercased()) as a meal", systemImage: "square.and.arrow.down") }
                }
            } footer: { Text("Saved meals show in Quick add, so a whole meal goes in with one tap.") }
            if meals.isEmpty {
                Section { Text("No saved meals yet. Build one, or save one of today's meals.").foregroundStyle(.secondary) }
            } else {
                Section("Your meals") {
                    ForEach(meals.indices, id: \.self) { i in
                        let m = meals[i], basis = store.mealBasis(m), per = num(basis["kcalPerServing"]) ?? 0
                        Button { editing = m } label: {
                            HStack(spacing: 12) {
                                FoodDot(name: str(m["name"]), size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(str(m["name"])).font(.body.weight(.semibold))
                                    Text("\(num(basis["servingSize"]).map { "\(Fmt.int($0)) g a portion · " } ?? "")\(Fmt.int(per)) kcal · \(Int(num(basis["pServ"]) ?? 0))g protein").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    store.add(basis, kcal: per, meal: Meals.now)
                                    withAnimation { added = str(m["name"]) }
                                    Task { try? await Task.sleep(nanoseconds: 1_800_000_000); withAnimation { added = nil } }
                                } label: { Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Theme.accent) }
                                .buttonStyle(.borderless)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions { Button(role: .destructive) { store.perform(["type": "deleteMeal", "id": str(m["id"]), "at": nowMs()]) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Your meals")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let added {
                Text("Added \(added) to today").font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 20).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: Binding(get: { editing.map { MealBox(meal: $0) } }, set: { editing = $0?.meal })) { box in
            MealEditor(meal: box.meal) { editing = nil }
        }
    }

    static func blank() -> JSON {
        ["id": uid(), "name": "", "portions": 1, "items": [Any](), "steps": [Any](), "saved": true, "updatedAt": ISO.now()]
    }
}

private struct MealBox: Identifiable { let meal: JSON; var id: String { str(meal["id"]) } }

/// One meal: its name, how many portions it makes, its foods and method; add a portion to today from here.
struct MealEditor: View {
    @State var meal: JSON
    var done: () -> Void
    @State private var picking = false
    @State private var portionsToAdd = 1.0
    @State private var gramsToAdd: Double?
    @State private var newStep = ""
    private var store: Store { Store.shared }

    var body: some View {
        let items = list(meal["items"]), steps = meal["steps"] as? [String] ?? []
        let basis = store.mealBasis(meal), per = num(basis["kcalPerServing"]) ?? 0
        let portions = num(meal["portions"]) ?? 1
        NavigationStack {
            List {
                Section {
                    TextField("Meal name, like Chicken stir fry", text: Binding(get: { str(meal["name"]) }, set: { meal["name"] = $0 })).font(.headline)
                    Stepper("Makes \(Fmt.one(portions)) portion\(portions == 1 ? "" : "s")", value: Binding(get: { portions }, set: { meal["portions"] = $0 }), in: 1...20, step: 1)
                }
                Section {
                    ForEach(items.indices, id: \.self) { i in
                        let it = items[i]
                        HStack(spacing: 12) {
                            FoodDot(name: str(it["name"]), size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(str(it["name"])).font(.subheadline.weight(.semibold))
                                Text("\(Fmt.int(num(it["kcal"]) ?? 0)) kcal").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                TextField("–", text: Binding(get: { Self.grams(it).map { Fmt.int($0) } ?? "" }, set: { setGrams(i, $0) }))
                                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 64)
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                Text("g").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .onDelete { idx in var its = items; its.remove(atOffsets: idx); meal["items"] = its }
                    Button { picking = true } label: { Label("Add a food", systemImage: "plus.circle.fill") }
                } header: { Text("Foods") } footer: {
                    if !items.isEmpty {
                        let total = items.compactMap { Self.grams($0) }.reduce(0, +)
                        Text("Whole meal \(Fmt.int(total)) g, \(Fmt.int(per * portions)) kcal. A portion is \(Fmt.int(total / portions)) g: \(Fmt.int(per)) kcal, \(Int(num(basis["pServ"]) ?? 0))g protein. Type the grams to change an amount.")
                    }
                }
                Section("Method (optional)") {
                    ForEach(steps.indices, id: \.self) { i in
                        HStack(alignment: .top) { Text("\(i + 1).").foregroundStyle(.secondary); Text(steps[i]) }
                    }
                    .onDelete { idx in var s = steps; s.remove(atOffsets: idx); meal["steps"] = s }
                    TextField("Add a step", text: $newStep).submitLabel(.done)
                        .onSubmit { let t = newStep.trimmingCharacters(in: .whitespaces); if !t.isEmpty { meal["steps"] = steps + [t] }; newStep = "" }
                }
                if !items.isEmpty {
                    Section {
                        let k100 = num(basis["kcalPer100"]), portionG = num(basis["servingSize"])
                        if let k100, let portionG {
                            // in grams: start at one portion, change it in 10 g steps or type it
                            let g = gramsToAdd ?? portionG.rounded()
                            HStack {
                                Text("How much")
                                Spacer()
                                Stepper(value: Binding(get: { g }, set: { gramsToAdd = max(10, $0) }), in: 10...3000, step: 10) { EmptyView() }.labelsHidden()
                                TextField("g", text: Binding(get: { Fmt.int(g) }, set: { if let v = Double($0), v > 0 { gramsToAdd = v } }))
                                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 60).font(.headline.monospacedDigit())
                                Text("g").foregroundStyle(.secondary)
                            }
                            Button {
                                save()
                                store.add(store.mealBasis(meal), kcal: k100 * g / 100, meal: Meals.now)
                                done()
                            } label: { Label("Add \(Fmt.int(g)) g to today · \(Fmt.int(k100 * g / 100)) kcal", systemImage: "plus.circle.fill").font(.headline) }
                        } else {
                            Stepper("\(Fmt.one(portionsToAdd)) portion\(portionsToAdd == 1 ? "" : "s"): \(Fmt.int(per * portionsToAdd)) kcal", value: $portionsToAdd, in: 0.5...10, step: 0.5)
                            Button {
                                save()
                                store.add(store.mealBasis(meal), kcal: per * portionsToAdd, meal: Meals.now)
                                done()
                            } label: { Label("Add to today", systemImage: "plus.circle.fill").font(.headline) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .keyboardDone()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(str(meal["name"]).isEmpty ? "New meal" : str(meal["name"]))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); done() }.fontWeight(.bold)
                        .disabled(str(meal["name"]).trimmingCharacters(in: .whitespaces).isEmpty || items.isEmpty)
                }
            }
            .sheet(isPresented: $picking) {
                FoodPicker { item in var its = list(meal["items"]); its.append(item); meal["items"] = its }
            }
        }
    }

    /// An ingredient's weight: kept on it, or worked out from its calories.
    static func grams(_ it: JSON) -> Double? {
        if let g = pos(it["grams"]) { return g }
        return FoodMath.amounts(it, kcal: num(it["kcal"]) ?? 0).grams
    }

    /// Typing grams: the calories follow, from the food's kcal per 100 g (or in proportion, if that isn't known).
    private func setGrams(_ i: Int, _ text: String) {
        var its = list(meal["items"]); guard i < its.count else { return }
        var it = its[i]
        guard let g = Double(text.filter { $0.isNumber || $0 == "." }), g > 0 else { return }
        if let k100 = FoodMath.kcalPer100(it) { it["kcal"] = Int((k100 * g / 100).rounded()) }
        else if let old = Self.grams(it), old > 0 { it["kcal"] = Int(((num(it["kcal"]) ?? 0) * g / old).rounded()) }
        else { it["kcalPer100"] = (num(it["kcal"]) ?? 0) / g * 100 }   // first weight for a portion-only food: its calories stay
        it["grams"] = g
        its[i] = it; meal["items"] = its
    }

    private func scale(_ i: Int, _ f: Double) {
        var its = list(meal["items"]); var it = its[i]
        it["kcal"] = Int(((num(it["kcal"]) ?? 0) * f).rounded())
        if let g = num(it["grams"]) { it["grams"] = (g * f).rounded() }
        its[i] = it; meal["items"] = its
    }

    private func save() {
        var m = meal
        m["name"] = str(m["name"]).trimmingCharacters(in: .whitespaces)
        m["saved"] = true; m["updatedAt"] = ISO.now()
        store.perform(["type": "saveMeal", "meal": m])
    }
}

/// Pick a food for a meal: your foods first, then the food list, at the amount you usually have.
struct FoodPicker: View {
    var add: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Section("Your foods") {
                        ForEach(store.quickEntries.filter { $0.kind == .recent }.prefix(30)) { e in row(e.name, e.detail, e.kcal) { pick(e.basis, kcal: e.kcal) } }
                    }
                } else {
                    let r = store.search(query)
                    if !r.mine.isEmpty { Section("Yours") { ForEach(r.mine) { e in row(e.name, e.detail, e.kcal) { pick(e.basis, kcal: e.kcal) } } } }
                    if !r.foods.isEmpty {
                        Section("Foods") {
                            ForEach(r.foods.indices, id: \.self) { i in
                                let b = r.foods[i], k = num(b["kcalPerServing"]) ?? num(b["kcalPer100"]) ?? 0
                                row(str(b["name"]), FoodMath.amountText(b, kcal: k), k) { pick(b, kcal: k) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle("Add a food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ name: String, _ detail: String, _ kcal: Double, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                FoodDot(name: name, size: 30)
                VStack(alignment: .leading, spacing: 1) { Text(name).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(Fmt.int(kcal)).font(.subheadline.weight(.bold)).monospacedDigit()
            }
        }
        .buttonStyle(.plain)
    }

    private func pick(_ basis: JSON, kcal: Double) {
        var item = FoodMath.basisOf(basis)
        item["id"] = uid(); item["kcal"] = Int(kcal.rounded())
        if let g = FoodMath.amounts(basis, kcal: kcal).grams { item["grams"] = g.rounded() }
        add(item); dismiss()
    }
}
