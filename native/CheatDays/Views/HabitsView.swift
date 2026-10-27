import SwiftUI

/// Your food, your way: what you'd like to improve, then breakfast, lunch, dinner and snacks one at a time, each thing
/// you usually have kept, tweaked or swapped (the AI suggests how), then the plan. Everyone sees it once, website users
/// too; it's redone from Me, and one of its changes comes back each week with the weigh-in.
struct HabitsView: View {
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var forward = true
    @State private var loaded = false
    @State private var goals: Set<String> = []
    @State private var newGoal = ""
    @State private var items: [Habit] = []
    @State private var adding = ["", "", "", ""]
    @State private var skips: Set<String> = []
    @State private var tips: [String] = []
    @State private var asking = false
    @State private var problem: String?
    private var store: Store { Store.shared }
    private let last = 5

    var body: some View {
        VStack(spacing: 0) {
            top
            ScrollView {
                Group {
                    switch step {
                    case 0: goalsStep
                    case 1...4: mealStep(Meals.all[step - 1])
                    default: planStep
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .scrollDismissesKeyboard(.interactively)
            bottom
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { if !loaded { prefill(); loaded = true } }
        .keyboardDone()
    }

    private func close() { if let onDone { onDone() } else { dismiss() } }

    // MARK: the frame

    private var top: some View {
        VStack(spacing: 10) {
            HStack {
                if step > 0 { Button("Back") { go(-1) } } else { Button("Not now") { notNow() } }
                Spacer()
                if step > 0 && step < last { Button("Not now") { notNow() }.foregroundStyle(.secondary) }
            }
            .font(.body.weight(.semibold))
            HStack(spacing: 4) {
                ForEach(0...last, id: \.self) { i in Capsule().fill(i <= step ? Theme.accent : Theme.track).frame(height: 4) }
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
        .animation(.snappy, value: step)
    }

    private var bottom: some View {
        Button {
            if step == last { finish() } else { go(1) }
        } label: {
            Text(nextLabel).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18))
        .foregroundStyle(.black)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.bg)
    }

    private var nextLabel: String {
        switch step {
        case last: return "Done"
        case last - 1: return "See my plan"
        case 0: return "Next: breakfast"
        default: return "Next: \(Meals.all[step].lowercased())"
        }
    }

    private func go(_ by: Int) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        forward = by > 0
        if step == 0 && by > 0 { Task { await suggest(items.filter { !$0.asked }, withTips: true) } }
        withAnimation(.snappy) { step = max(0, min(last, step + by)) }
    }

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: "\(step + 1) of \(last + 1)", color: Theme.heroLabel)
            Text(title).font(.largeTitle.bold())
            Text(sub).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    // MARK: 1 what to improve

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("What would you like to improve?", "Pick a few. Then we'll go through your meals, and you choose what stays.")
            Flow {
                ForEach(Habits.goals + goals.subtracting(Habits.goals).sorted(), id: \.self) { g in
                    Chip(text: g, on: goals.contains(g)) { if goals.contains(g) { goals.remove(g) } else { goals.insert(g) } }
                }
            }
            HStack {
                TextField("Something else", text: $newGoal).submitLabel(.done)
                    .onSubmit { let t = newGoal.trimmingCharacters(in: .whitespaces); if !t.isEmpty { goals.insert(t.capitalizedFirst) }; newGoal = "" }
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
            }
            .padding(12).background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: 2 to 5, a meal at a time

    private func mealStep(_ meal: String) -> some View {
        let i = Meals.all.firstIndex(of: meal) ?? 0
        let here = items.filter { $0.meal == meal }
        let skipped = skips.contains(meal)
        return VStack(alignment: .leading, spacing: 10) {
            heading(meal == "Snacks" ? "Snacks and drinks" : meal,
                    here.isEmpty ? "What do you usually have? Add a few things." : "What you usually have. Keep it, tweak it or swap it.")
            if skipped {
                Text("You skip \(meal.lowercased()). Nothing to change here.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach($items) { $h in if h.meal == meal { row($h) } }   // bindings by id, so removing one can't index past the end
                HStack {
                    TextField(hints[i], text: $adding[i]).submitLabel(.done).onSubmit { add(meal) }
                    Button { add(meal) } label: { Image(systemName: "plus.circle.fill") }.foregroundStyle(Theme.accent)
                }
                .padding(12).background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if meal == "Breakfast" || meal == "Lunch" {
                Button(skipped ? "I do have \(meal.lowercased())" : "I skip \(meal.lowercased())") {
                    withAnimation { if skipped { skips.remove(meal) } else { skips.insert(meal) } }
                }
                .font(.subheadline.weight(.semibold)).padding(.top, 4)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
        }
        .animation(.snappy, value: items)
    }

    private let hints = ["Flat white, toast with peanut butter", "Meal deal, leftovers", "Stir fry, takeaway on Fridays", "Biscuits, a few beers"]

    private func row(_ h: Binding<Habit>) -> some View {
        let it = h.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                FoodDot(name: it.name, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.name).font(.headline).lineLimit(2)
                    if !it.often.isEmpty { Text(it.often).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Button { withAnimation { items.removeAll { $0.id == it.id } } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).font(.footnote.weight(.bold))
            }
            Picker("Choice", selection: h.choice) {
                Text("Keep").tag("keep"); Text("Tweak").tag("tweak"); Text("Swap").tag("swap")
            }
            .pickerStyle(.segmented)
            switch it.choice {
            case "keep":
                Text("Stays as it is.").font(.footnote).foregroundStyle(.secondary)
            default:
                let tweak = it.choice == "tweak"
                if !it.asked && asking {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finding an idea…").font(.footnote).foregroundStyle(.secondary) }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        TextField(tweak ? "How? Less of it, a lighter one…" : "Swap for what?", text: tweak ? h.tweak : h.swap, axis: .vertical)
                            .font(.subheadline).lineLimit(1...3)
                        let save = tweak ? it.tweakSave : it.swapSave
                        if abs(save) >= 10 {
                            Text(save > 0 ? "−\(Int(save))" : "+\(Int(-save))").font(.subheadline.weight(.heavy)).monospacedDigit()
                                .foregroundStyle(save > 0 ? Theme.accent : Theme.warn)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func add(_ meal: String) {
        let i = Meals.all.firstIndex(of: meal) ?? 0
        let names = adding[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        adding[i] = ""
        guard !names.isEmpty else { return }
        let new = names.map { Habit(meal: meal, name: $0.capitalizedFirst) }
        withAnimation { items += new }
        Task { await suggest(new, withTips: false) }
    }

    // MARK: 6 the plan

    private var planStep: some View {
        let save = items.reduce(0) { $0 + max(0, $1.weekSave) }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Your food, your way", color: Theme.heroLabel)
                Text(save >= 50 ? "About \(Fmt.int((save / 10).rounded() * 10)) kcal a week" : "Your food plan").font(.largeTitle.bold())
                Text(save >= 50 ? "Saved, without giving up what you love." : "Keep what you love. Change a little at a time.").foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            ForEach(Meals.all, id: \.self) { meal in
                let here = items.filter { $0.meal == meal && !skips.contains(meal) }
                if !here.isEmpty {
                    Eyebrow(text: meal == "Snacks" ? "Snacks and drinks" : meal).padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(here) { h in
                            summary(h)
                            if h.id != here.last?.id { Divider().padding(.leading, 14) }
                        }
                    }
                    .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            if !tips.isEmpty {
                Eyebrow(text: "For your goals").padding(.top, 6)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tips, id: \.self) { t in
                        HStack(alignment: .top, spacing: 10) { FluentIcon(emoji: "🎯", size: 20); Text(t).font(.subheadline) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if asking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working out tips for your goals…").font(.footnote).foregroundStyle(.secondary) }
            }
            Text("Each week, one of these comes up with your weigh-in. The assistant knows what you're keeping, so it won't nag about those. Change it any time in Me.")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
        }
    }

    private func summary(_ h: Habit) -> some View {
        let (tag, tint): (String, Color) = h.plan == nil ? ("Keep", Theme.accent) : h.choice == "tweak" ? ("Tweak", Theme.warn) : ("Swap", Theme.heroLabel)
        return HStack(spacing: 10) {
            Text(tag).font(.caption.weight(.bold)).foregroundStyle(.black)
                .padding(.horizontal, 8).padding(.vertical, 3).background(tint, in: Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name).font(.subheadline.weight(.semibold))
                if let p = h.plan { Text(h.choice == "swap" ? "→ \(p)" : p).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if h.weekSave >= 20 { Text("−\(Fmt.int(h.weekSave)) a week").font(.caption.weight(.bold)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: the AI's ideas

    private func suggest(_ todo: [Habit], withTips: Bool) async {
        guard !todo.isEmpty || (withTips && !goals.isEmpty) else { return }
        asking = true; problem = nil
        defer { asking = false }
        let prefs = dict(store.doc["prefs"])
        let avoid = (prefs["avoid"] as? [String] ?? []).joined(separator: ", ")
        let lines = todo.map { "\($0.id) | \($0.meal) | \($0.name) | \($0.perWeek.map { "\(Fmt.one($0)) times a week" } ?? "unknown")" }.joined(separator: "\n")
        let schema: JSON = ["type": "object", "properties": [
            "items": ["type": "array", "items": ["type": "object", "properties": [
                "id": ["type": "string"] as JSON,
                "tweak": ["type": "string", "description": "Keep the same food but less of it or a lighter version, under 9 words, e.g. '2 pints, not 4' or 'Skimmed milk instead of whole'"] as JSON,
                "tweakSave": ["type": "number", "description": "kcal saved each time (negative if the tweak adds food, e.g. an egg for protein)"] as JSON,
                "swap": ["type": "string", "description": "A different food that scratches the same itch, under 9 words, e.g. 'Popcorn instead of crisps'"] as JSON,
                "swapSave": ["type": "number", "description": "kcal saved each time"] as JSON,
                "pick": ["type": "string", "enum": ["keep", "tweak", "swap"], "description": "keep when it's already a good choice"] as JSON,
                "perWeek": ["type": "number", "description": "Your guess at how many times a week, only used when unknown"] as JSON
            ] as JSON, "required": ["id", "tweak", "tweakSave", "swap", "swapSave", "pick", "perWeek"]] as JSON] as JSON,
            "tips": ["type": "array", "items": ["type": "string"] as JSON, "description": "One short, specific action per goal, under 12 words"] as JSON
        ] as JSON, "required": ["items", "tips"]]
        let prompt = """
        Someone in \(Plan.country) wants to eat better without giving up what they love. Daily budget about \(Int(store.budgetToday)) kcal\(store.proteinGoal.map { ", protein goal \(Int($0)) g" } ?? "").
        What they want to improve: \(goals.isEmpty ? "nothing in particular, just eat a bit better" : goals.sorted().joined(separator: ", ")).
        Never suggest: \(avoid.isEmpty ? "nothing" : avoid).
        For each thing they usually have (id | meal | food | how often), suggest one realistic tweak and one swap using products and portions from there, aimed at their goals. Honest kcal per time. Pick keep for things that are already fine, or tiny.
        \(lines.isEmpty ? "(no foods this time, items can be empty)" : lines)
        \(withTips ? "Also give one tip per goal." : "Tips can be empty.")
        """
        do {
            let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true)
            var got: [String: JSON] = [:]
            for x in list(a["items"]) { got[str(x["id"])] = x }
            withAnimation {
                for i in items.indices {
                    guard let x = got[items[i].id] else { continue }
                    items[i].tweak = str(x["tweak"]); items[i].swap = str(x["swap"])
                    items[i].tweakSave = num(x["tweakSave"]) ?? 0; items[i].swapSave = num(x["swapSave"]) ?? 0
                    if items[i].perWeek == nil { items[i].perWeek = pos(x["perWeek"]) }
                    if ["keep", "tweak", "swap"].contains(str(x["pick"])) { items[i].choice = str(x["pick"]) }
                    items[i].asked = true
                }
                if withTips { tips = (a["tips"] as? [String] ?? []).filter { !$0.isEmpty } }
            }
        } catch {
            problem = "Couldn't get ideas just now. Write your own, or try again later from Me."
            for i in items.indices where todo.contains(where: { $0.id == items[i].id }) { items[i].asked = true }
        }
    }

    // MARK: saving

    private func prefill() {
        let h = store.habits
        let saved = store.habitItems
        if !saved.isEmpty {
            items = saved
            goals = Set(h["goals"] as? [String] ?? [])
            skips = Set(h["skips"] as? [String] ?? [])
            tips = h["tips"] as? [String] ?? []
            let have = Set(saved.map { $0.meal + "|" + $0.name.lowercased() })   // anything new in the log since
            items += store.loggedHabits().filter { !have.contains($0.meal + "|" + $0.name.lowercased()) }
        } else {
            items = store.loggedHabits()
        }
    }

    private func notNow() {
        if store.habits.isEmpty { store.saveHabits(["skipped": true, "updatedAt": ISO.now()]) }
        close()
    }

    private func finish() {
        let kept = items.filter { !skips.contains($0.meal) }
        store.saveHabits([
            "goals": goals.sorted(), "items": kept.map(\.json), "tips": tips, "skips": skips.sorted(), "updatedAt": ISO.now()
        ])
        Task { await Reminders.reschedule(store) }
        close()
    }
}
