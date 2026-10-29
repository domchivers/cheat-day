import PhotosUI
import SwiftUI

/// Your meals: saved meals to add in one tap, build new ones, or save one of today's meals.
struct MealsView: View {
    @State private var editing: JSON?
    @State private var added: String?
    @State private var sending: JSON?
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
                                Button { sending = m } label: { Image(systemName: "paperplane").font(.title3).foregroundStyle(Theme.accent) }
                                    .buttonStyle(.borderless).accessibilityLabel("Send \(str(m["name"])) to a friend")
                                Button {
                                    store.add(basis, kcal: per, meal: Meals.now)
                                    flash("Added \(str(m["name"])) to today")
                                } label: { Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Theme.accent) }
                                .buttonStyle(.borderless)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions { Button(role: .destructive) { store.perform(["type": "deleteMeal", "id": str(m["id"]), "at": nowMs()]) } label: { Label("Delete", systemImage: "trash") } }
                        .swipeActions(edge: .leading) { Button { sending = m } label: { Label("Send", systemImage: "paperplane.fill") }.tint(Theme.accent) }
                        .contextMenu { Button { sending = m } label: { Label("Send to a friend", systemImage: "paperplane") } }
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
                Text(added).font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 20).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog("Send \(str(sending?["name"])) to…", isPresented: Binding(get: { sending != nil }, set: { if !$0 { sending = nil } }), titleVisibility: .visible) {
            ForEach(Friends.shared.people) { p in
                Button(p.name) {
                    guard let m = sending else { return }
                    Task {
                        do { try await Friends.shared.sendMeal(m, to: p); flash("Sent \(str(m["name"])) to \(p.name)") }
                        catch { flash("Couldn't send: \(error.localizedDescription)") }
                    }
                }
            }
        } message: { Text(Friends.shared.people.isEmpty ? "Add a friend first, in the Friends tab." : "They get the whole recipe on their Today, to save or have a portion.") }
        .task { if Friends.shared.people.isEmpty { await Friends.shared.load() } }
        .sheet(item: Binding(get: { editing.map { MealBox(meal: $0) } }, set: { editing = $0?.meal })) { box in
            MealEditor(meal: box.meal) { editing = nil }
        }
    }

    private func flash(_ text: String) {
        withAnimation { added = text }
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); withAnimation { if added == text { added = nil } } }
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
    @State private var swapping: SwapRef?
    @State private var scanFor: Int?
    @State private var scanMode: PantryScanSheet.Mode?
    @AppStorage("pantry.scans") private var scansJSON = "[]"
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
                } footer: {
                    if !items.isEmpty {
                        // the stepper splits the same food differently; these change every amount instead
                        HStack(spacing: 14) {
                            Text("Scale every amount:")
                            if portions > 1 { Button("For 1 portion") { scaleAll(1 / portions) } }
                            Button("Halve") { scaleAll(0.5) }
                            Button("Double") { scaleAll(2) }
                        }
                        .font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                    }
                }
                Section {
                    ForEach(items.indices, id: \.self) { i in
                        let it = items[i]
                        HStack(spacing: 12) {
                            FoodDot(name: str(it["name"]), size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(str(it["name"])).font(.subheadline.weight(.semibold))
                                Text("\(Fmt.int(num(it["kcal"]) ?? 0)) kcal\(it["side"] as? Bool == true ? " · served separately" : "")")
                                    .font(.caption).foregroundStyle(it["side"] as? Bool == true ? Theme.heroLabel : .secondary).monospacedDigit()
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
                            // the same as a recipe's ingredients: swap in your own food, or take it out
                            Menu {
                                Button { swapping = SwapRef(index: i, name: str(it["name"]), grams: Self.grams(it) ?? 0, portions: portions) } label: {
                                    Label("Swap for my own", systemImage: "arrow.left.arrow.right")
                                }
                                // rice and other sides: kept with the meal but out of its numbers, logged on their own
                                Button { toggleSide(i) } label: {
                                    Label(it["side"] as? Bool == true ? "Back in the pot" : "Served separately", systemImage: "square.split.2x1")
                                }
                                Button(role: .destructive) { remove(i) } label: { Label("Remove from meal", systemImage: "minus.circle") }
                            } label: {
                                Image(systemName: "ellipsis").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                                    .frame(width: 30, height: 30).background(Theme.accent.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Change \(str(it["name"]))")
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { remove(i) } label: { Label("Remove", systemImage: "trash") }
                            Button { swapping = SwapRef(index: i, name: str(it["name"]), grams: Self.grams(it) ?? 0, portions: portions) } label: {
                                Label("Swap", systemImage: "arrow.left.arrow.right")
                            }
                            .tint(Theme.accent)
                        }
                    }
                    Button { picking = true } label: { Label("Add a food", systemImage: "plus.circle.fill") }
                } header: { Text("Foods") } footer: {
                    if !items.isEmpty {
                        let total = pos(meal["cookedGrams"]) ?? items.filter { $0["side"] as? Bool != true }.compactMap { Self.grams($0) }.reduce(0, +)
                        Text("Whole meal \(Fmt.int(total)) g\(meal["cookedGrams"] == nil ? "" : " cooked"), \(Fmt.int(per * portions)) kcal. A portion is \(Fmt.int(total / portions)) g: \(Fmt.int(per)) kcal, \(Int(num(basis["pServ"]) ?? 0))g protein. Type the grams to change an amount.")
                    }
                }
                if !items.isEmpty {
                    // cooked in bulk: weigh the finished pot and portions are weighed against it, not the raw weights
                    let raw = items.filter { $0["side"] as? Bool != true }.map { (str($0["name"]), Self.grams($0) ?? 0) }
                    Section {
                        HStack {
                            Text("Finished pot")
                            Spacer()
                            TextField(CookedWeight.estimate(raw).map { "≈ \(Fmt.int($0))" } ?? "grams",
                                      text: Binding(get: { pos(meal["cookedGrams"]).map { Fmt.int($0) } ?? "" },
                                                    set: { let v = Double($0.filter(\.isNumber)) ?? 0; meal["cookedGrams"] = v > 0 ? v : nil }))
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                                .font(.subheadline.weight(.bold).monospacedDigit())
                            Text("g").foregroundStyle(.secondary)
                        }
                    } header: { Text("Cooked weight") } footer: {
                        if let w = pos(meal["cookedGrams"]), let est = CookedWeight.estimate(raw), CookedWeight.looksOff(weighed: w, estimate: est) {
                            // way off what goes in: usually a side (rice) that's in the list but not in the pot
                            Label("That's a long way from the \(Fmt.int(est)) g this list would make. Is everything here in the pot? Rice or sides you serve separately should come out of the list (••• → Remove), or the calories per gram come out wrong.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warn)
                        }
                        // calories per 100 g that don't make sense for the dish (a curry is usually 80 to 200)
                        if let w = pos(meal["cookedGrams"]) {
                            let per100 = per * portions / w * 100, r = CookedWeightCard.dishRange(str(meal["name"]))
                            if per100 < r.lo * 0.8 || per100 > r.hi * 1.2 {
                                Label("That makes \(Fmt.int(per100)) kcal per 100 g, \(per100 > r.hi ? "high" : "low") for \(r.label) (usually \(Fmt.int(r.lo))–\(Fmt.int(r.hi))). Check the weight: was it the whole pot, without the dish? Adding by the portion still counts right.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.warn)
                            }
                        }
                        Text(meal["cookedGrams"] == nil
                             ? "Cooked it in bulk? Weigh it all once it's done (without the dish) and type it here, and the grams you put on your plate count right. About \(CookedWeight.estimate(raw).map { Fmt.int($0) } ?? "?") g is a guess from what goes in."
                             : "Portions and grams you add now come from the cooked weight: cooking changes the water, not the calories.")
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
            .sheet(item: $swapping) { s in
                SwapPicker(original: s.name, grams: s.grams, portions: s.portions, foods: PantryItem.yourFoods,
                           cupboard: PantryItem.Saved.load(scansJSON)) { item in
                    swap(s.index, item); swapping = nil
                } scan: { mode in
                    swapping = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { scanFor = s.index; scanMode = mode }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $scanMode) { m in
                PantryScanSheet(mode: m) { scanned in
                    let names = Set(scanned.map { $0.name.lowercased() })
                    scansJSON = PantryItem.Saved.save(scanned + PantryItem.Saved.load(scansJSON).filter { !names.contains($0.name.lowercased()) })
                    if let i = scanFor, let first = scanned.first { swap(i, first) }
                    scanFor = nil
                }
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

    /// Your own food in place of an ingredient: same grams with its numbers per 100 g, or your portion per portion.
    private func swap(_ i: Int, _ item: PantryItem) {
        var its = list(meal["items"]); guard i < its.count else { return }
        its[i] = item.ingredient(grams: Self.grams(its[i]), portions: num(meal["portions"]) ?? 1)
        withAnimation { meal["items"] = its }
    }

    private func toggleSide(_ i: Int) {
        var its = list(meal["items"]); guard i < its.count else { return }
        its[i]["side"] = its[i]["side"] as? Bool == true ? nil : true
        withAnimation { meal["items"] = its }
    }

    private func remove(_ i: Int) {
        var its = list(meal["items"]); guard i < its.count else { return }
        its.remove(at: i)
        withAnimation { meal["items"] = its }
    }

    /// Every amount times f, with the portions and the cooked weight following (a curry for 4 made for 1).
    private func scaleAll(_ f: Double) {
        let its = list(meal["items"]).map { it -> JSON in
            var x = it
            x["kcal"] = Int(((num(it["kcal"]) ?? 0) * f).rounded())
            if let g = Self.grams(it) { x["grams"] = (g * f).rounded() }
            return x
        }
        withAnimation {
            meal["items"] = its
            meal["portions"] = max(1, ((num(meal["portions"]) ?? 1) * f).rounded())
            if let c = pos(meal["cookedGrams"]) { meal["cookedGrams"] = (c * f).rounded() }
        }
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
private struct PickedFood: Identifiable, Hashable {
    let id = UUID()
    let basis: JSON
    let kcal: Double
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct FoodPicker: View {
    var add: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var choosing: PickedFood?
    @State private var scanning = false
    @State private var camera = false
    @State private var photo: PhotosPickerItem?
    @State private var describing = false
    @State private var busy: String?
    @State private var problem: String?
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            List {
                // the same ways in as adding food to your day
                Section {
                    HStack(spacing: 8) {
                        way("barcode.viewfinder", "Scan") { scanning = true }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { way("camera.fill", "Label") { camera = true } }
                        PhotosPicker(selection: $photo, matching: .images) { wayLabel("photo.on.rectangle", "Photo") }.buttonStyle(.plain)
                        way("sparkles", "Describe") { describing = true }
                    }
                    .buttonStyle(.plain)
                    if let busy { HStack(spacing: 8) { ProgressView(); Text(busy).font(.footnote).foregroundStyle(.secondary) } }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
                }
                // your scanned foods (their own labels) come before any generic match
                let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                let cupboard = PantryItem.Saved.load(UserDefaults.standard.string(forKey: "pantry.scans") ?? "[]")
                    .filter { q.count < 2 || $0.name.lowercased().contains(q) || q.split(separator: " ").allSatisfy { w in $0.name.lowercased().contains(w) } }
                if !cupboard.isEmpty {
                    Section("Your cupboard") {
                        ForEach(cupboard) { s in
                            let b: JSON = ["name": s.name, "source": "label", "unit": "g", "kcalPer100": s.kcal100,
                                           "p100": s.p100 ?? 0, "c100": s.c100 ?? 0, "f100": s.f100 ?? 0, "servingSize": 100.0]
                            row(s.name, s.line, s.kcal100) { pick(b, kcal: s.kcal100) }
                        }
                    }
                }
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
            .keyboardDone()
            .navigationDestination(item: $choosing) { p in GramsStep(basis: p.basis, kcal: p.kcal) { item in add(item); dismiss() } }
            .navigationTitle("Add a food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $scanning) { IngredientScan { basis in scanning = false; use(basis) } }
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { read(img) } }.ignoresSafeArea() }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { read(img) }
                    photo = nil
                }
            }
            .sheet(isPresented: $describing) {
                IngredientAsk { items in describing = false; items.forEach(add); dismiss() }.presentationDetents([.medium])
            }
        }
    }

    private func way(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { wayLabel(symbol, label) }
    }
    private func wayLabel(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent)
            Text(label).font(.caption.weight(.bold))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A food from a scan or a label photo: on to how much.
    private func use(_ basis: JSON) {
        problem = nil
        let k = pos(basis["kcalPerServing"]) ?? pos(basis["kcalPer100"]) ?? 0
        pick(basis, kcal: k)
    }

    private func read(_ img: UIImage) {
        busy = "Reading the label…"; problem = nil
        Task {
            do {
                let r = try await LabelReader.read(img) { step in busy = step }
                busy = nil
                use(r.item)
            } catch {
                busy = nil
                problem = error.localizedDescription
            }
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
        if FoodMath.kcalPer100(basis) != nil { choosing = PickedFood(basis: basis, kcal: kcal); return }   // grams next
        var item = FoodMath.basisOf(basis)
        item["id"] = uid(); item["kcal"] = Int(kcal.rounded())
        add(item); dismiss()
    }
}

/// How many grams of an ingredient: type it or pick a size; the calories follow.
private struct GramsStep: View {
    let basis: JSON
    let kcal: Double
    var done: (JSON) -> Void
    @State private var text = ""
    private var k100: Double { FoodMath.kcalPer100(basis) ?? 0 }
    private var grams: Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Grams", text: $text).keyboardType(.decimalPad).font(.title2.weight(.bold))
                    Text("g").foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([25.0, 50, 100, 150, 200, 250], id: \.self) { g in Chip(text: "\(Fmt.int(g)) g", on: grams == g) { text = Fmt.int(g) } }
                    }
                }
            } header: { Text(str(basis["name"])) } footer: {
                Text("\(Fmt.int(k100 * grams / 100)) kcal\(num(basis["p100"]).map { " · \(Fmt.one($0 * grams / 100))g protein" } ?? "")")
            }
            Section {
                Button("Add to the meal") {
                    var item = FoodMath.basisOf(basis)
                    item["id"] = uid(); item["grams"] = grams; item["kcal"] = Int((k100 * grams / 100).rounded())
                    done(item)
                }
                .font(.headline).disabled(grams <= 0)
            }
        }
        .keyboardDone()
        .navigationTitle("How much?")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if text.isEmpty { text = Fmt.int((FoodMath.amounts(basis, kcal: kcal).grams ?? 100).rounded()) } }
    }
}

/// Scan an ingredient's barcode for a meal: looks it up and hands the food back (nothing goes on today).
private struct IngredientScan: View {
    var found: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Point at a barcode"
    @State private var looking = false
    @State private var key = 0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BarcodeScanner { code in look(code) }.id(key).ignoresSafeArea(edges: .bottom)
                HStack(spacing: 8) {
                    if looking { ProgressView() }
                    Text(status).font(.subheadline.weight(.bold))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 30)
            }
            .navigationTitle("Scan an ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func look(_ code: String) {
        looking = true; status = "Looking up \(code)…"
        Task {
            switch await OpenFoodFacts.lookup(code) {
            case .found(let item) where pos(item["kcalPer100"]) != nil || pos(item["kcalPerServing"]) != nil:
                found(item)
            default:
                looking = false; status = "Not found. Try another, or use Label or Describe."
                key += 1   // start the camera again
            }
        }
    }
}

/// Say what goes in ("2 tbsp olive oil and 200 g chicken thigh"): the AI lists each ingredient with its weight and
/// numbers, checked against the food databases, and they go into the meal.
private struct IngredientAsk: View {
    var done: ([JSON]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var problem: String?

    private static let schema: JSON = ["type": "object", "properties": [
        "items": ["type": "array", "items": ["type": "object", "properties": [
            "name": ["type": "string"] as JSON,
            "usda_name": ["type": "string", "description": "the closest USDA FoodData Central description"] as JSON,
            "grams": ["type": "number", "description": "weight as used in the recipe"] as JSON,
            "kcal": ["type": "number"] as JSON, "protein_g": ["type": "number"] as JSON, "carbs_g": ["type": "number"] as JSON, "fat_g": ["type": "number"] as JSON
        ] as JSON, "required": ["name", "usda_name", "grams", "kcal", "protein_g", "carbs_g", "fat_g"]] as JSON] as JSON
    ] as JSON, "required": ["items"]]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("2 tbsp olive oil, 200 g chicken thigh…", text: $text, axis: .vertical).lineLimit(2...5)
                } footer: { Text("Say each ingredient and roughly how much. The AI works out the weights and numbers, checked against the food databases.") }
                if let problem { Section { Text(problem).foregroundStyle(Theme.warn) } }
                Section {
                    Button { Task { await work() } } label: {
                        HStack { if busy { ProgressView() }; Text(busy ? "Working it out…" : "Add to the meal").fontWeight(.bold) }.frame(maxWidth: .infinity)
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespaces).count < 3)
                }
            }
            .keyboardDone()
            .navigationTitle("Describe it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func work() async {
        busy = true; problem = nil
        defer { busy = false }
        let prompt = """
        Ingredients for a recipe, in \(Plan.country): "\(text)".
        List each ingredient with its weight in grams as used (raw unless it says cooked), and its calories, protein, carbs and fat for that weight, using standard reference values and the usual sizes there (a tablespoon of oil is about 14 g). If they give numbers themselves, use exactly those.
        """
        do {
            let a = try await Gemini.ask(schema: Self.schema, parts: [["text": prompt]], quick: true)
            let raw = CheatDays.list(a["items"]).filter { (num($0["grams"]) ?? 0) > 0 }
            guard !raw.isEmpty else { problem = "Couldn't work that out. Try saying each ingredient with an amount."; return }
            let checked = CheatDays.list(await Assistant.ground(["parts": raw])["parts"])
            let items: [JSON] = checked.map { p in
                let g = num(p["grams"]) ?? 0, k = num(p["kcal"]) ?? 0
                var it = Assistant.basis(name: str(p["name"]).capitalizedFirst, kcal: k, grams: g, p: num(p["protein_g"]) ?? 0, c: num(p["carbs_g"]) ?? 0, f: num(p["fat_g"]) ?? 0)
                it["id"] = uid(); it["kcal"] = Int(k.rounded()); it["grams"] = g.rounded()
                return it
            }
            done(items)
        } catch {
            problem = error.localizedDescription
        }
    }
}
