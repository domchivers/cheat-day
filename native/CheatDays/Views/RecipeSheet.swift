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
    @State private var swapping: SwapRef?
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var dragging: (index: Int, x: CGFloat)? = nil
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
        return ings.enumerated().map { i, g in
            var x = g
            if out.contains(swapKey(i)) { x["removed"] = true }
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
        let portions = max(1, num(r["portions"]) ?? 1)
        let ings = applied(list(v["ingredients"]), portions: portions), steps = v["steps"] as? [String] ?? []
        let used = ings.filter { $0["removed"] as? Bool != true }   // what's in it: totals, logging and saving
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
            Text("swipe left to remove").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        VStack(spacing: 0) {
            ForEach(ings.indices, id: \.self) { i in
                ingredientRow(ings[i], i, portions: portions)
                if i < ings.count - 1 { Divider().padding(.leading, 14) }
            }
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
        VStack(spacing: 10) {
            Button {
                store.add(Assistant.basis(name: name(r), kcal: k, grams: nil, p: p, c: c, f: f), kcal: k, meal: meal)
                flash("Added to \(meal.lowercased())")
            } label: { Text("Log a portion for \(meal.lowercased()) · \(Fmt.int(k)) kcal").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.borderedProminent).foregroundStyle(.black)
            Button {
                let items: [JSON] = used.map { i in
                    var it = Assistant.basis(name: str(i["name"]), kcal: num(i["kcal"]) ?? 0, grams: num(i["grams"]), p: num(i["protein_g"]) ?? 0, c: num(i["carbs_g"]) ?? 0, f: num(i["fat_g"]) ?? 0)
                    it["id"] = uid(); it["kcal"] = Int((num(i["kcal"]) ?? 0).rounded()); it["grams"] = num(i["grams"]) ?? 0; it["unitLabel"] = "g"
                    return it
                }
                store.perform(["type": "saveMeal", "meal": ["id": uid(), "name": name(r), "portions": portions, "items": items, "steps": steps, "saved": true, "updatedAt": ISO.now()] as JSON])
                flash("Saved to your meals")
            } label: { Text("Save to my meals").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.bordered)
            if let done { Label(done, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent) }
        }
        .padding(.top, 8)
    }

    private static let green = Color(red: 0.36, green: 0.82, blue: 0.56)

    /// One ingredient: its name and calories, the amount, and ••• for Swap or Remove; swipe left to remove too.
    /// A removed one stays, greyed out, with Put back.
    @ViewBuilder private func ingredientRow(_ g: JSON, _ i: Int, portions: Double) -> some View {
        let from = str(g["swappedFrom"]), out = g["removed"] as? Bool == true
        let kcal = Fmt.int(num(g["kcal"]) ?? 0)
        let offset = dragging?.index == i ? min(0, dragging?.x ?? 0) : 0
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
                } else {
                    Text("\(kcal) kcal").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if out {
                Button("Put back") { setRemoved(i, false) }.font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    .padding(.trailing, 8)
            } else {
                Text(str(g["amount"]).isEmpty ? "\(Int(num(g["grams"]) ?? 0)) g" : str(g["amount"])).font(.subheadline.weight(.semibold))
                Menu {
                    Button { swapping = SwapRef(index: i, name: from.isEmpty ? str(g["name"]) : from, grams: num(g["grams"]) ?? 0, portions: portions) } label: {
                        Label("Swap for my own", systemImage: "arrow.left.arrow.right")
                    }
                    if !from.isEmpty { Button { setSwap(i, nil) } label: { Label("Undo the swap", systemImage: "arrow.uturn.backward") } }
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
        .offset(x: offset)
        .background(alignment: .trailing) {
            if offset < 0 {
                Label("Remove", systemImage: "minus.circle.fill").labelStyle(.iconOnly).font(.title3).foregroundStyle(.white)
                    .frame(width: max(0, -offset), alignment: .center).frame(maxHeight: .infinity).background(Color.red)
            }
        }
        .contentShape(Rectangle())
        // the row follows the finger only while the swipe is sideways; the offset springs back by itself if the
        // scroll takes the touch over (gesture state resets when a gesture is cancelled, onEnded isn't called then)
        .simultaneousGesture(DragGesture(minimumDistance: 18).updating($dragging) { v, state, _ in
            guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            state = (i, v.translation.width)
        }.onEnded { v in
            if v.translation.width < -90 && abs(v.translation.width) > abs(v.translation.height) * 1.5 { setRemoved(i, true) }
        }, including: out ? .subviews : .all)
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
                if !foods.isEmpty { section("Foods you log", foods) }
                if !cupboard.isEmpty { section("From your cupboard", cupboard) }
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
            var props: JSON = ["ingredients": ing, "steps": ["type": "array", "items": ["type": "string"] as JSON] as JSON]
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
        Portions 1 to 4. Grams are as weighed; kcal and macros per ingredient from standard reference values, so they add up.
        """
        // the quick models write a recipe fine; three tries at most, so it never hangs for minutes
        let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true, tries: 3)
        guard !list(dict(a["authentic"])["ingredients"]).isEmpty else { throw Gemini.Failure(message: "Couldn't write that recipe just now. Try again.") }
        return a
    }
}
