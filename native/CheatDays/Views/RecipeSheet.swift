import SwiftUI

struct IdeaRef: Identifiable { let id: String; let idea: JSON }

/// A meal idea as something to follow: the authentic recipe as it's really made, and a healthier take that keeps its
/// character (what changed, and the numbers for both). Written by the AI the first time, then kept with the idea.
struct RecipeSheet: View {
    let idea: JSON
    var onRecipe: ((JSON) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var recipe: JSON?
    @State private var version = "authentic"
    @State private var problem: String?
    @State private var done: String?
    private var store: Store { Store.shared }
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
                        Button("Try again") { Task { await load() } }
                    } else {
                        HStack(spacing: 10) { ProgressView(); Text("Writing the recipe…").foregroundStyle(.secondary) }.padding(.top, 20)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            if recipe == nil { recipe = idea["recipe"] as? JSON }
            if recipe == nil { await load() }
        }
    }

    @ViewBuilder private func content(_ r: JSON) -> some View {
        let v = dict(r[version])
        let ings = list(v["ingredients"]), steps = v["steps"] as? [String] ?? []
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
        Eyebrow(text: "Ingredients").padding(.top, 4)
        VStack(spacing: 0) {
            ForEach(ings.indices, id: \.self) { i in
                let g = ings[i]
                HStack {
                    Text(str(g["name"])).font(.subheadline)
                    Spacer()
                    Text(str(g["amount"]).isEmpty ? "\(Int(num(g["grams"]) ?? 0)) g" : str(g["amount"])).font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
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

    private func name(_ r: JSON) -> String { str(idea["name"]) + (version == "healthier" ? " (lighter)" : "") }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) { Text(v).font(.headline.weight(.heavy)).monospacedDigit(); Text(l).font(.caption2).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }

    private func flash(_ t: String) {
        withAnimation { done = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { if done == t { done = nil } } }
    }

    private func load() async {
        problem = nil
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
        do {
            let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: false)
            guard !list(dict(a["authentic"])["ingredients"]).isEmpty else { problem = "Couldn't write that recipe just now."; return }
            withAnimation { recipe = a }
            onRecipe?(a)
        } catch { problem = error.localizedDescription }
    }
}
