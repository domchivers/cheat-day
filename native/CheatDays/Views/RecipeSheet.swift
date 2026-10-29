import SwiftUI

struct IdeaRef: Identifiable { let id: String; let idea: JSON }

/// Writes recipes away from the screen: close the sheet, switch tab or leave the app and it carries on, then keeps
/// the recipe with its idea. Opening the idea again shows it, or that it's still being written.
@Observable @MainActor
final class RecipeMaker {
    static let shared = RecipeMaker()
    private(set) var made: [String: JSON] = [:]
    private(set) var working: Set<String> = []
    private(set) var failed: [String: String] = [:]

    func recipe(for idea: JSON) -> JSON? {
        let name = str(idea["name"])
        return made[name] ?? idea["recipe"] as? JSON ?? Store.shared.habitIdeas.first { str($0["name"]) == name }?["recipe"] as? JSON
    }

    func make(_ idea: JSON) {
        let name = str(idea["name"])
        guard !working.contains(name), recipe(for: idea) == nil else { return }
        working.insert(name); failed[name] = nil
        Task {
            defer { working.remove(name) }
            do {
                let r = try await Self.write(idea)
                made[name] = r
                Store.shared.keepRecipe(r, for: name)
            } catch { failed[name] = error.localizedDescription }
        }
    }
}

/// A meal idea as something to follow: the authentic recipe as it's really made, and a healthier take that keeps its
/// character (what changed, and the numbers for both). Written by the AI the first time, then kept with the idea.
struct RecipeSheet: View {
    let idea: JSON
    @Environment(\.dismiss) private var dismiss
    @State private var version = "authentic"
    @State private var done: String?
    @AppStorage("recipe.swaps") private var swapsJSON = "{}"   // "recipe|version|ingredient" → your own food
    @AppStorage("pantry.scans") private var scansJSON = "[]"
    @AppStorage("recipe.removed") private var removedJSON = "[]"   // "recipe|version|ingredient" left out
    @AppStorage("recipe.added") private var addedJSON = "{}"   // "recipe|version" → ingredients you added (sweetcorn)
    @AppStorage("recipe.cooked") private var cookedJSON = "{}"   // "recipe|version" → what the finished pot weighed
    @State private var addingFood = false
    @AppStorage("recipe.grams") private var gramsJSON = "{}"   // "recipe|version|ingredient" → the grams you use
    @AppStorage("recipe.sides") private var sidesJSON = "[]"   // "recipe|version|ingredient" served on the side (rice)
    @State private var resizing: SwapRef?
    @State private var resizeText = ""
    @AppStorage("recipe.serves") private var servesJSON = "{}"   // "recipe|version" → {n, scale}: your portions
    @State private var swapping: SwapRef?
    @State private var scanFor: (index: Int, mode: PantryScanSheet.Mode)?
    @State private var scanMode: PantryScanSheet.Mode?
    private var store: Store { Store.shared }
    private var maker: RecipeMaker { RecipeMaker.shared }
    private var recipe: JSON? { maker.recipe(for: idea) }
    private var problem: String? { maker.failed[str(idea["name"])] }
    private var meal: String { Meals.all.contains(str(idea["meal"])) ? str(idea["meal"]) : Meals.byTime(Calendar.current.component(.hour, from: Date())) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        FoodDot(name: str(idea["name"]), size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(str(idea["name"])).font(.title2.bold())
                            if !str(idea["why"]).isEmpty { Text(str(idea["why"])).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    if let r = recipe { content(r) }
                    else if let problem {
                        Text(problem).font(.footnote).foregroundStyle(Theme.warn)
                        Button("Try again") { maker.make(idea) }
                    } else {
                        HStack(spacing: 10) { ProgressView(); Text("Writing the recipe…").foregroundStyle(.secondary) }.padding(.top, 20)
                        Text("Usually 10 to 20 seconds. You can close this: it keeps going and will be here when you come back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $swapping) { s in
                SwapPicker(original: s.name, grams: s.grams, portions: s.portions, foods: yourFoods,
                           cupboard: PantryItem.Saved.load(scansJSON)) { item in
                    setSwap(s.index, item); swapping = nil
                } scan: { mode in
                    swapping = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { scanFor = (s.index, mode); scanMode = mode }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $addingFood) { FoodPicker { item in add(item) } }
            .alert(resizing.map { "How much \($0.name.lowercased())?" } ?? "", isPresented: Binding(get: { resizing != nil }, set: { if !$0 { resizing = nil } })) {
                TextField("grams", text: $resizeText).keyboardType(.numberPad)
                Button("Save") {
                    if let r = resizing, let v = Double(resizeText.filter(\.isNumber)), v > 0 { setGrams(r.index, v) }
                    resizing = nil
                }
                if let r = resizing, ownGrams[swapKey(r.index)] != nil {
                    Button("Back to the recipe's") { setGrams(r.index, nil); resizing = nil }
                }
                Button("Cancel", role: .cancel) { resizing = nil }
            } message: { Text("In grams. Its calories and the recipe's totals follow.") }
            .sheet(item: $scanMode) { m in
                PantryScanSheet(mode: m) { items in
                    // scanned here: into the cupboard too, and the first one in place of the ingredient
                    let names = Set(items.map { $0.name.lowercased() })
                    scansJSON = PantryItem.Saved.save(items + PantryItem.Saved.load(scansJSON).filter { !names.contains($0.name.lowercased()) })
                    if let i = scanFor?.index, let first = items.first { setSwap(i, first) }
                    scanFor = nil
                }
            }
        }
        .onAppear { maker.make(idea) }
    }

    private var swaps: [String: PantryItem] { (try? JSONDecoder().decode([String: PantryItem].self, from: Data(swapsJSON.utf8))) ?? [:] }
    private func swapKey(_ i: Int) -> String { "\(str(idea["name"]))|\(version)|\(i)" }
    private func setSwap(_ i: Int, _ item: PantryItem?) {
        var all = swaps
        all[swapKey(i)] = item
        withAnimation(.snappy) { swapsJSON = String(data: (try? JSONEncoder().encode(all)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}" }
    }

    private var recipeKey: String { "\(str(idea["name"]))|\(version)" }

    /// Ingredients you added to this recipe, as recipe ingredients (grams, kcal and macros).
    private var added: [JSON] {
        let all = (try? JSONSerialization.jsonObject(with: Data(addedJSON.utf8))) as? [String: Any]
        return list(all?[recipeKey])
    }
    private func add(_ item: JSON) {
        let k = num(item["kcal"]) ?? 0, g = num(item["grams"]) ?? FoodMath.amounts(item, kcal: k).grams
        let m = FoodMath.macros(FoodMath.basisOf(item), kcal: k)
        var ing: JSON = ["name": str(item["name"]), "kcal": k, "protein_g": m?.p ?? 0, "carbs_g": m?.c ?? 0, "fat_g": m?.f ?? 0, "added": true]
        if let g { ing["grams"] = g; ing["amount"] = "\(Fmt.int(g)) g" } else { ing["amount"] = FoodMath.amountText(item, kcal: k) }
        var all = ((try? JSONSerialization.jsonObject(with: Data(addedJSON.utf8))) as? [String: Any]) ?? [:]
        all[recipeKey] = added + [ing]
        if let d = try? JSONSerialization.data(withJSONObject: all) { withAnimation(.snappy) { addedJSON = String(data: d, encoding: .utf8) ?? "{}" } }
    }

    /// How many it serves for you, and whether the amounts scale with it or the same pot is split differently.
    private var serves: (n: Double, scale: Bool)? {
        guard let s = (((try? JSONSerialization.jsonObject(with: Data(servesJSON.utf8))) as? [String: Any])?[recipeKey]) as? [String: Any],
              let n = pos(s["n"]) else { return nil }
        return (n, s["scale"] as? Bool ?? true)
    }
    private func setServes(_ n: Double?, scale: Bool) {
        var all = ((try? JSONSerialization.jsonObject(with: Data(servesJSON.utf8))) as? [String: Any]) ?? [:]
        all[recipeKey] = n.map { ["n": $0, "scale": scale] as [String: Any] }
        if let d = try? JSONSerialization.data(withJSONObject: all) { withAnimation(.snappy) { servesJSON = String(data: d, encoding: .utf8) ?? "{}" } }
    }

    /// Every amount times the factor (4 portions down to 1 is a quarter of each).
    private func scaled(_ ings: [JSON], by f: Double) -> [JSON] {
        guard f != 1 else { return ings }
        return ings.map { g in
            var x = g
            for k in ["kcal", "protein_g", "carbs_g", "fat_g", "grams"] { if let v = num(g[k]) { x[k] = v * f } }
            let amount = str(g["amount"])
            let inGrams = amount.isEmpty || amount.range(of: #"^[\d.,]+\s?g$"#, options: .regularExpression) != nil   // "200 g", "200g"
            if let grams = num(x["grams"]), inGrams {
                x["amount"] = "\(Fmt.int(grams)) g"
            } else if !amount.isEmpty {
                x["amount"] = "\(amount) × \(Fmt.one(f))"
            }
            return x
        }
    }

    private var weighed: Double? { (((try? JSONSerialization.jsonObject(with: Data(cookedJSON.utf8))) as? [String: Any])?[recipeKey]).flatMap { pos($0) } }
    private func setWeighed(_ g: Double?) {
        var all = ((try? JSONSerialization.jsonObject(with: Data(cookedJSON.utf8))) as? [String: Any]) ?? [:]
        all[recipeKey] = g
        if let d = try? JSONSerialization.data(withJSONObject: all) { cookedJSON = String(data: d, encoding: .utf8) ?? "{}" }
    }

    private func startResize(_ g: JSON, _ i: Int) {
        resizeText = pos(g["grams"]).map { Fmt.int($0) } ?? ""
        resizing = SwapRef(index: i, name: str(g["name"]), grams: num(g["grams"]) ?? 0, portions: 1)
    }

    /// Ingredients served on the side: out of the pot (its numbers and cooked weight), logged on their own.
    private var sides: Set<String> { Set((try? JSONDecoder().decode([String].self, from: Data(sidesJSON.utf8))) ?? []) }
    private func setSide(_ i: Int, _ on: Bool) {
        var all = sides
        if on { all.insert(swapKey(i)) } else { all.remove(swapKey(i)) }
        withAnimation(.snappy) { sidesJSON = String(data: (try? JSONEncoder().encode(Array(all))) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }

    private var ownGrams: [String: Double] { (try? JSONDecoder().decode([String: Double].self, from: Data(gramsJSON.utf8))) ?? [:] }
    private func setGrams(_ i: Int, _ g: Double?) {
        var all = ownGrams
        all[swapKey(i)] = g
        withAnimation(.snappy) { gramsJSON = String(data: (try? JSONEncoder().encode(all)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}" }
    }

    private var removed: Set<String> { Set((try? JSONDecoder().decode([String].self, from: Data(removedJSON.utf8))) ?? []) }
    private func setRemoved(_ i: Int, _ out: Bool) {
        var all = removed
        if out { all.insert(swapKey(i)) } else { all.remove(swapKey(i)) }
        withAnimation(.snappy) { removedJSON = String(data: (try? JSONEncoder().encode(Array(all))) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }

    private var yourFoods: [PantryItem] { PantryItem.yourFoods }

    /// The recipe's ingredients with your own foods swapped in, and the ones you've taken out marked "removed".
    /// A food with numbers per 100 g keeps the recipe's grams; one you log by the portion goes in as one of your
    /// portions per person.
    private func applied(_ ings: [JSON], portions: Double) -> [JSON] {
        let s = swaps, out = removed
        let own = ownGrams, side = sides
        return ings.enumerated().map { i, g0 in
            // your amount first (less carrot): everything about the ingredient scales with it, then any swap uses it
            var g = g0
            if let mine = own[swapKey(i)], let was = pos(g0["grams"]) {
                let f = mine / was
                for k in ["kcal", "protein_g", "carbs_g", "fat_g"] { if let v = num(g0[k]) { g[k] = v * f } }
                g["grams"] = mine; g["amount"] = "\(Fmt.int(mine)) g"; g["resized"] = true
            }
            var x = g
            if out.contains(swapKey(i)) { x["removed"] = true }
            if side.contains(swapKey(i)) { x["side"] = true }
            guard let item = s[swapKey(i)] else { return x }
            if item.byPortion, let k = item.portionKcal {
                x["swappedFrom"] = str(g["name"]); x["name"] = item.name
                x["amount"] = portions == 1 ? "1 × \(item.portionLabel ?? "portion")" : "\(Fmt.int(portions)) × \(item.portionLabel ?? "portion")"
                x["kcal"] = k * portions
                if let p = item.portionP { x["protein_g"] = p * portions }
                if let c = item.portionC { x["carbs_g"] = c * portions }
                if let f = item.portionF { x["fat_g"] = f * portions }
                return x
            }
            guard let grams = pos(g["grams"]), item.kcal100 > 0 else { return x }
            x["swappedFrom"] = str(g["name"]); x["name"] = item.name; x["amount"] = "\(Fmt.int(grams)) g"
            x["kcal"] = item.kcal100 * grams / 100
            // a macro the label didn't give keeps the recipe's own figure rather than counting as 0
            if let p = item.p100 { x["protein_g"] = p * grams / 100 }
            if let c = item.c100 { x["carbs_g"] = c * grams / 100 }
            if let f = item.f100 { x["fat_g"] = f * grams / 100 }
            return x
        }
    }

    @ViewBuilder private func content(_ r: JSON) -> some View {
        let v = dict(r[version])
        let base = max(1, num(r["portions"]) ?? 1), sv = serves
        let portions = sv?.n ?? base
        let factor = (sv?.scale ?? true) ? portions / base : 1   // scaled amounts, or the same pot split differently
        let ings = applied(scaled(list(v["ingredients"]), by: factor) + added, portions: portions), steps = v["steps"] as? [String] ?? []
        // what's in the pot: totals, cooked weight, logging and saving (not what's removed or served on the side)
        let used = ings.filter { $0["removed"] as? Bool != true && $0["side"] as? Bool != true }
        let k = used.reduce(0) { $0 + (num($1["kcal"]) ?? 0) } / portions
        let p = used.reduce(0) { $0 + (num($1["protein_g"]) ?? 0) } / portions
        let c = used.reduce(0) { $0 + (num($1["carbs_g"]) ?? 0) } / portions
        let f = used.reduce(0) { $0 + (num($1["fat_g"]) ?? 0) } / portions
        if !list(dict(r["healthier"])["ingredients"]).isEmpty {
            Picker("Version", selection: $version) { Text("Authentic").tag("authentic"); Text("Healthier").tag("healthier") }
                .pickerStyle(.segmented)
        }
        HStack(spacing: 0) {
            stat(Fmt.int(k), "kcal")
            stat("\(Int(p))g", "protein")
            stat("\(Int(c))g", "carbs")
            stat("\(Int(f))g", "fat")
        }
        .padding(.vertical, 12)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentTransition(.numericText())
        .animation(.snappy, value: version)
        .animation(.snappy, value: k)
        Text([num(r["minutes"]).map { "\(Int($0)) min" }, "serves \(Int(portions))", str(r["cuisine"]).isEmpty ? nil : str(r["cuisine"])].compactMap { $0 }.joined(separator: " · ") + " · per portion")
            .font(.footnote).foregroundStyle(.secondary)
        servesControl(base: base, portions: portions, scale: sv?.scale ?? true)
        // the finished pot: an estimate (the recipe's, or worked out from what goes in), or what you weighed
        let estimate = pos(v["cookedGrams"]).map { $0 * factor } ?? CookedWeight.estimate(used.map { (str($0["name"]), num($0["grams"]) ?? 0) })
        let aim = store.mealTarget(meal)
        if version == "healthier", let changes = v["changes"] as? [String], !changes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(changes, id: \.self) { ch in Label(ch, systemImage: "leaf.fill").font(.subheadline) }
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        HStack {
            Eyebrow(text: "Ingredients")
            Spacer()
            Text("tap ••• to swap or remove").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        VStack(spacing: 0) {
            ForEach(ings.indices, id: \.self) { i in
                ingredientRow(ings[i], i, portions: portions)
                Divider().padding(.leading, 14)
            }
            Button { addingFood = true } label: {
                Label("Add an ingredient", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        if !steps.isEmpty {
            Eyebrow(text: "Method").padding(.top, 4)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").font(.footnote.weight(.heavy)).foregroundStyle(.black)
                            .frame(width: 22, height: 22).background(Theme.accent, in: Circle())
                        Text(steps[i]).font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        // after the method, as weighing the pot comes after cooking; it's also where you log, by the grams on your plate
        CookedWeightCard(kcal: k * portions, protein: p * portions, carbs: c * portions, fat: f * portions, portions: portions,
                         estimate: estimate, dish: str(idea["name"]), weighed: Binding(get: { weighed }, set: { setWeighed($0) }),
                         aimKcal: aim.kcal, aimProtein: aim.protein) { g, kc, pr, ca, fa in
            store.add(Assistant.basis(name: name(r), kcal: kc, grams: g, p: pr, c: ca, f: fa), kcal: kc, meal: meal)
            flash("Added \(Fmt.int(g)) g to \(meal.lowercased())")
        }
        .id(recipeKey)
        VStack(spacing: 10) {
            if estimate == nil && weighed == nil {   // no weights to go on: log a portion instead
                Button {
                    store.add(Assistant.basis(name: name(r), kcal: k, grams: nil, p: p, c: c, f: f), kcal: k, meal: meal)
                    flash("Added to \(meal.lowercased())")
                } label: { Text("Log a portion for \(meal.lowercased()) · \(Fmt.int(k)) kcal").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
            Button {
                let items: [JSON] = used.map { i in
                    var it = Assistant.basis(name: str(i["name"]), kcal: num(i["kcal"]) ?? 0, grams: num(i["grams"]), p: num(i["protein_g"]) ?? 0, c: num(i["carbs_g"]) ?? 0, f: num(i["fat_g"]) ?? 0)
                    it["id"] = uid(); it["kcal"] = Int((num(i["kcal"]) ?? 0).rounded()); it["grams"] = num(i["grams"]) ?? 0; it["unitLabel"] = "g"
                    return it
                }
                var m: JSON = ["id": uid(), "name": name(r), "portions": portions, "items": items, "steps": steps, "saved": true, "updatedAt": ISO.now()]
                if let weighed { m["cookedGrams"] = weighed }   // weighed once: leftovers weigh against the cooked pot
                store.perform(["type": "saveMeal", "meal": m])
                flash("Saved to your meals")
            } label: { Text("Save to my meals").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.bordered)
            if let done { Label(done, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent) }
        }
        .padding(.top, 8)
    }

    private static let green = Color(red: 0.36, green: 0.82, blue: 0.56)

    /// Serves: change how many portions, and whether every amount scales with it or the same pot makes bigger or
    /// smaller portions. Back to the recipe's own number with Reset.
    @ViewBuilder private func servesControl(base: Double, portions: Double, scale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Serves").font(.subheadline.weight(.semibold))
                Spacer()
                if portions != base {
                    Button("Reset to \(Fmt.int(base))") { setServes(nil, scale: true) }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                }
                Stepper(value: Binding(get: { portions }, set: { setServes($0 == base ? nil : $0, scale: scale) }), in: 1...20, step: 1) {
                    Text("\(Fmt.int(portions))").font(.headline.monospacedDigit())
                }
                .fixedSize()
            }
            if portions != base {
                Picker("How", selection: Binding(get: { scale }, set: { setServes(portions, scale: $0) })) {
                    Text("Scale the amounts").tag(true)
                    Text("Same amounts").tag(false)
                }
                .pickerStyle(.segmented)
                Text(scale ? "Every amount is for \(Fmt.int(portions)) portion\(portions == 1 ? "" : "s") now: the recipe was for \(Fmt.int(base))."
                           : "The same pot as the recipe, split into \(Fmt.int(portions)): each portion is \(portions < base ? "bigger" : "smaller").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// One ingredient: its name and calories, the amount, and ••• for Swap or Remove. No swiping: the page only
    /// scrolls up and down. A removed one stays, greyed out, with Put back.
    @ViewBuilder private func ingredientRow(_ g: JSON, _ i: Int, portions: Double) -> some View {
        ingredientContent(g, i, portions: portions)
    }

    /// An ingredient's name and calories, the amount, and ••• for Swap or Remove.
    @ViewBuilder private func ingredientContent(_ g: JSON, _ i: Int, portions: Double) -> some View {
        let from = str(g["swappedFrom"]), out = g["removed"] as? Bool == true
        let kcal = Fmt.int(num(g["kcal"]) ?? 0)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(str(g["name"])).font(.subheadline).strikethrough(out)
                    if !from.isEmpty && !out {
                        Text("YOURS").font(.caption2.weight(.heavy)).foregroundStyle(Self.green)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Self.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if out {
                    Text("\(kcal) kcal · removed").font(.caption).foregroundStyle(.secondary)
                } else if !from.isEmpty {
                    Button { setSwap(i, nil) } label: {
                        (Text("\(kcal) kcal · instead of \(from.lowercased()) · ").foregroundStyle(.secondary) + Text("undo").foregroundStyle(Theme.accent).bold()).font(.caption)
                    }
                    .buttonStyle(.plain)
                } else if g["side"] as? Bool == true {
                    // on the side: not in the pot's numbers; a portion's worth logs on its own
                    let each = (num(g["kcal"]) ?? 0) / portions
                    HStack(spacing: 6) {
                        Text("served separately").font(.caption.weight(.semibold)).foregroundStyle(Theme.heroLabel)
                        Button("Add \(Fmt.int(each)) kcal") {
                            store.add(Assistant.basis(name: str(g["name"]), kcal: each, grams: num(g["grams"]).map { $0 / portions },
                                                      p: (num(g["protein_g"]) ?? 0) / portions, c: (num(g["carbs_g"]) ?? 0) / portions,
                                                      f: (num(g["fat_g"]) ?? 0) / portions), kcal: each, meal: meal)
                            flash("Added \(str(g["name"]).lowercased()) to \(meal.lowercased())")
                        }
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    }
                } else {
                    Text("\(kcal) kcal").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if out {
                Button("Put back") { setRemoved(i, false) }.font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    .padding(.trailing, 8)
            } else {
                // tap the amount to change it
                Button { startResize(g, i) } label: {
                    Text(str(g["amount"]).isEmpty ? "\(Int(num(g["grams"]) ?? 0)) g" : str(g["amount"])).font(.subheadline.weight(.semibold))
                        .foregroundStyle(g["resized"] as? Bool == true ? Theme.accent : .primary)
                }
                .buttonStyle(.plain).disabled(pos(g["grams"]) == nil)
                Menu {
                    if pos(g["grams"]) != nil {
                        Button { startResize(g, i) } label: { Label("Change amount", systemImage: "scalemass") }
                    }
                    Button { swapping = SwapRef(index: i, name: from.isEmpty ? str(g["name"]) : from, grams: num(g["grams"]) ?? 0, portions: portions) } label: {
                        Label("Swap for my own", systemImage: "arrow.left.arrow.right")
                    }
                    if !from.isEmpty { Button { setSwap(i, nil) } label: { Label("Undo the swap", systemImage: "arrow.uturn.backward") } }
                    let isSide = g["side"] as? Bool == true
                    Button { setSide(i, !isSide) } label: {
                        Label(isSide ? "Back in the pot" : "Served separately", systemImage: isSide ? "arrow.uturn.backward" : "square.split.2x1")
                    }
                    Button(role: .destructive) { setRemoved(i, true) } label: { Label("Remove from recipe", systemImage: "minus.circle") }
                } label: {
                    Image(systemName: "ellipsis").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30).background(Theme.accent.opacity(0.12), in: Circle()).frame(width: 40, height: 40)
                }
                .accessibilityLabel("Change \(str(g["name"]))")
            }
        }
        .opacity(out ? 0.5 : 1)
        .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
        .background(Theme.hero)
        .contentShape(Rectangle())
        .sensoryFeedback(.impact, trigger: out)
    }

    private func name(_ r: JSON) -> String { str(idea["name"]) + (version == "healthier" ? " (lighter)" : "") }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) { Text(v).font(.headline.weight(.heavy)).monospacedDigit(); Text(l).font(.caption2).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }

    private func flash(_ t: String) {
        withAnimation { done = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { if done == t { done = nil } } }
    }

}

struct SwapRef: Identifiable { let index: Int; let name: String; let grams: Double; let portions: Double; var id: Int { index } }

/// What to swap an ingredient for: a food you log (your usual portion, or per 100 g), one from your cupboard, or
/// one scanned there and then.
struct SwapPicker: View {
    let original: String
    let grams: Double
    let portions: Double
    let foods: [PantryItem]
    let cupboard: [PantryItem]
    let pick: (PantryItem) -> Void
    let scan: (PantryScanSheet.Mode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // the cupboard first: a short list of what you've scanned, then everything you log; like for like only
                // (beef for beef, rice for rice), so mayonnaise never turns up as a swap for steak
                let mine = cupboard.filter { FoodKind.swaps(original, $0.name) }, logged = foods.filter { FoodKind.swaps(original, $0.name) }
                if !mine.isEmpty { section("From your cupboard", mine) }
                if !logged.isEmpty { section("Foods you log", logged) }
                freshCuts
                if mine.isEmpty && logged.isEmpty && !(cupboard.isEmpty && foods.isEmpty) {
                    Section { Text("Nothing like \(original.lowercased()) in your foods yet. Scan one below.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Button { scan(.barcode) } label: { Label("Scan a barcode", systemImage: "barcode.viewfinder") }
                    Button { scan(.photo) } label: { Label("Photo of a label", systemImage: "camera.fill") }
                } footer: { Text("Your own numbers go in, so what you log matches what you cook.") }
            }
            .navigationTitle("Swap \(original.lowercased())").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func section(_ title: String, _ items: [PantryItem]) -> some View {
        Section(title) {
            ForEach(items) { s in
                // per 100 g needs the recipe's grams; a portion food always fits
                let fits = s.byPortion || (s.kcal100 > 0 && grams > 0)
                Button { pick(s) } label: {
                    HStack(spacing: 10) {
                        FoodDot(name: s.name, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(s.line).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(here(s)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                .disabled(!fits)
            }
        }
    }

    /// Fresh meat often has no nutrition panel: pick how lean it looks instead (raw, per 100 g).
    static let cuts: [(name: String, words: [String], levels: [(String, Double, Double)])] = [
        ("Beef chuck", ["chuck", "steak", "beef", "brisket", "blade"], [("Lean", 155, 21), ("Typical", 200, 19), ("Fatty", 220, 18)]),
        ("Beef mince", ["mince", "ground"], [("5-star", 132, 19.5), ("4-star", 170, 19), ("3-star", 220, 17.5)]),
        ("Chicken thigh fillet", ["chicken", "thigh"], [("Lean", 115, 20), ("Typical", 125, 19), ("Fatty", 150, 18)]),
        ("Pork shoulder", ["pork", "shoulder"], [("Lean", 150, 19), ("Typical", 190, 17), ("Fatty", 230, 16)])
    ]

    @ViewBuilder private var freshCuts: some View {
        let kind = FoodKind.of(original)
        if [.meat, .poultry].contains(kind) {
            let n = original.lowercased()
            let matching = Self.cuts.filter { $0.words.contains(where: { n.contains($0) }) }
            Section {
                ForEach(matching.isEmpty ? Self.cuts.map(\.name) : matching.map(\.name), id: \.self) { cutName in
                    let cut = Self.cuts.first { $0.name == cutName }!
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cut.name).font(.subheadline.weight(.semibold))
                        HStack(spacing: 8) {
                            ForEach(cut.levels, id: \.0) { lv in
                                Button {
                                    // fat from what's left once protein's counted (raw meat has next to no carbs)
                                    let fat = max(0, (lv.1 - 4 * lv.2) / 9)
                                    if let item = PantryItem(basis: ["name": "\(cut.name) (\(lv.0.lowercased()))", "kcalPer100": lv.1, "p100": lv.2, "c100": 0.0, "f100": (fat * 10).rounded() / 10]) {
                                        pick(item)
                                    }
                                } label: {
                                    VStack(spacing: 1) {
                                        Text(lv.0).font(.caption.weight(.bold))
                                        Text("\(Fmt.int(lv.1)) kcal · \(Fmt.int(lv.2))g P").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("Fresh, no label?") } footer: { Text("Raw, per 100 g. Lean is trimmed with little visible fat; fatty is well marbled.") }
        }
    }

    /// What it comes to in this recipe.
    private func here(_ s: PantryItem) -> String {
        if s.byPortion { return portions == 1 ? "\(Fmt.int(s.portionKcal ?? 0)) kcal" : "\(Fmt.int(portions)) for \(Fmt.int(portions))\n\(Fmt.int((s.portionKcal ?? 0) * portions)) kcal" }
        return "\(Fmt.int(grams)) g\n\(Fmt.int(s.kcal100 * grams / 100)) kcal"
    }
}

extension RecipeMaker {
    static func write(_ idea: JSON) async throws -> JSON {
        let store = Store.shared
        let ing: JSON = ["type": "array", "items": ["type": "object", "properties": [
            "name": ["type": "string"] as JSON, "amount": ["type": "string", "description": "How a cook measures it: '2 tbsp', '1 onion', '200 g'"] as JSON,
            "grams": ["type": "number"] as JSON, "kcal": ["type": "number"] as JSON,
            "protein_g": ["type": "number"] as JSON, "carbs_g": ["type": "number"] as JSON, "fat_g": ["type": "number"] as JSON
        ] as JSON, "required": ["name", "amount", "grams", "kcal", "protein_g", "carbs_g", "fat_g"]] as JSON]
        let version: (Bool) -> JSON = { changes in
            var props: JSON = ["ingredients": ing, "steps": ["type": "array", "items": ["type": "string"] as JSON] as JSON,
                               "cookedGrams": ["type": "number", "description": "Roughly what the whole finished dish weighs once cooked, in grams (meat loses water, rice and pasta gain it)"] as JSON]
            if changes { props["changes"] = ["type": "array", "items": ["type": "string"] as JSON, "description": "What's different, under 12 words each, e.g. 'Half the butter, a splash of milk instead'"] as JSON }
            return ["type": "object", "properties": props, "required": changes ? ["ingredients", "steps", "changes"] : ["ingredients", "steps"]]
        }
        let schema: JSON = ["type": "object", "properties": [
            "cuisine": ["type": "string"] as JSON, "minutes": ["type": "number"] as JSON, "portions": ["type": "number"] as JSON,
            "authentic": version(false), "healthier": version(true)
        ] as JSON, "required": ["cuisine", "minutes", "portions", "authentic", "healthier"]]
        let prompt = """
        Write the recipe for "\(str(idea["name"]))" for someone in \(Plan.country) who \(Habits.cookText(str(store.habits["cook"]))).
        authentic: how it's really made in its home cuisine, true to the dish, with ingredients they can buy there. Short, clear method steps.
        healthier: the same dish with its character kept, lighter or higher in protein (less oil and butter, leaner cuts, more veg, swaps that taste close), and list the changes.
        If it's really a takeaway order or shop-bought, authentic is what to buy or order and how to put it together, healthier is the lighter choice.
        Portions 1 to 4. Grams are as weighed; kcal and macros per ingredient from standard reference values, so they add up, and each ingredient's kcal ≈ 4 × protein + 4 × carbs + 9 × fat.
        \(Sanity.amounts) Use what's typical in \(Plan.country) (cuts, brands and portion sizes there).
        """
        // the quick models write a recipe fine; three tries at most, so it never hangs for minutes
        let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true, tries: 3)
        guard !list(dict(a["authentic"])["ingredients"]).isEmpty else { throw Gemini.Failure(message: "Couldn't write that recipe just now. Try again.") }
        // each ingredient's calories checked against its own protein, carbs and fat before the recipe is kept
        var out = a
        for v in ["authentic", "healthier"] {
            var ver = dict(a[v])
            ver["ingredients"] = list(ver["ingredients"]).map { g -> JSON in
                var x = g
                x["kcal"] = Sanity.check(name: str(g["name"]), grams: num(g["grams"]), kcal: num(g["kcal"]) ?? 0,
                                         p: num(g["protein_g"]), c: num(g["carbs_g"]), f: num(g["fat_g"])).kcal
                return x
            }
            out[v] = ver
        }
        return out
    }
}
