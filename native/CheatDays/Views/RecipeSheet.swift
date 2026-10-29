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
                SwapPicker(original: s.name, grams: s.grams, cupboard: PantryItem.Saved.load(scansJSON)) { item in
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

    /// The recipe's ingredients with your own foods swapped in: same grams, your label's numbers.
    private func applied(_ ings: [JSON]) -> [JSON] {
        let s = swaps
        return ings.enumerated().map { i, g in
            guard let item = s[swapKey(i)], let grams = pos(g["grams"]) else { return g }
            var x = g
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
        let ings = applied(list(v["ingredients"])), steps = v["steps"] as? [String] ?? []
        let portions = max(1, num(r["portions"]) ?? 1)
        let k = ings.reduce(0) { $0 + (num($1["kcal"]) ?? 0) } / portions
        let p = ings.reduce(0) { $0 + (num($1["protein_g"]) ?? 0) } / portions
        let c = ings.reduce(0) { $0 + (num($1["carbs_g"]) ?? 0) } / portions
        let f = ings.reduce(0) { $0 + (num($1["fat_g"]) ?? 0) } / portions
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
            Text("tap ⇄ to use your own").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        VStack(spacing: 0) {
            ForEach(ings.indices, id: \.self) { i in
                let g = ings[i], from = str(g["swappedFrom"])
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(str(g["name"])).font(.subheadline)
                            if !from.isEmpty {
                                Text("YOUR LABEL").font(.caption2.weight(.heavy)).foregroundStyle(Self.green)
                                    .padding(.horizontal, 5).padding(.vertical, 1).background(Self.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        if !from.isEmpty {
                            Button { setSwap(i, nil) } label: {
                                (Text("instead of \(from.lowercased()) · ").foregroundStyle(.secondary) + Text("undo").foregroundStyle(Theme.accent).bold()).font(.caption)
                            }
                                .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    Text(str(g["amount"]).isEmpty ? "\(Int(num(g["grams"]) ?? 0)) g" : str(g["amount"])).font(.subheadline.weight(.semibold))
                    if let grams = pos(g["grams"]) {
                        Button { swapping = SwapRef(index: i, name: from.isEmpty ? str(g["name"]) : from, grams: grams) } label: {
                            Image(systemName: "arrow.left.arrow.right").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Swap \(str(g["name"])) for your own")
                    }
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 5)
                if i < ings.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            } label: { Text("Log a portion for \(meal.lowercased())").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.borderedProminent).foregroundStyle(.black)
            Button {
                let items: [JSON] = ings.map { i in
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

struct SwapRef: Identifiable { let index: Int; let name: String; let grams: Double; var id: Int { index } }

/// What to swap an ingredient for: a food from your cupboard, or one scanned there and then. Keeps the grams.
struct SwapPicker: View {
    let original: String
    let grams: Double
    let cupboard: [PantryItem]
    let pick: (PantryItem) -> Void
    let scan: (PantryScanSheet.Mode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !cupboard.isEmpty {
                    Section("From your cupboard") {
                        ForEach(cupboard) { s in
                            Button { pick(s) } label: {
                                HStack(spacing: 10) {
                                    FoodDot(name: s.name, size: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text("\(s.line) · \(Fmt.int(s.kcal100 * grams / 100)) kcal here").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button { scan(.barcode) } label: { Label("Scan a barcode", systemImage: "barcode.viewfinder") }
                    Button { scan(.photo) } label: { Label("Photo of a label", systemImage: "camera.fill") }
                } footer: { Text("Keeps \(Fmt.int(grams)) g and uses your label's numbers, so what you log matches what you cook.") }
            }
            .navigationTitle("Swap \(original.lowercased())").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
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
