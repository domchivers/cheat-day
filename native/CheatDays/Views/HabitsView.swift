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
    @State private var aim = "better"
    @State private var goals: Set<String> = []
    @State private var verdict = ""   // "great" when what you eat already fits what you're after
    @State private var verdictLine = ""
    @State private var newGoal = ""
    @State private var items: [Habit] = []
    @State private var adding = ["", "", "", ""]
    @State private var skips: Set<String> = []
    @State private var tips: [String] = []
    @State private var ideas: [JSON] = []   // meals to try: meal, name, kcal, protein, carbs, fat, why, picked
    @State private var cook = "sometimes"
    @State private var cuisines: Set<String> = []
    @State private var open: IdeaRef?
    @State private var asking = false
    @State private var problem: String?
    private var store: Store { Store.shared }
    private let last = 6

    var body: some View {
        VStack(spacing: 0) {
            top
            ScrollView {
                Group {
                    switch step {
                    case 0: goalsStep
                    case 1: cookStep
                    case 2...5: mealStep(Meals.all[step - 2])
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
        .sheet(item: $open) { r in
            RecipeSheet(idea: r.idea)
        }
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
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.bg)
    }

    private var nextLabel: String {
        switch step {
        case last: return "Done"
        case last - 1: return "See my plan"
        case 0: return "Next: cooking"
        case 1: return "Next: breakfast"
        default: return "Next: \(Meals.all[step - 1].lowercased())"
        }
    }

    private func go(_ by: Int) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        forward = by > 0
        if step == 1 && by > 0 { Task { await suggest(items.filter { !$0.asked }, withTips: true) } }
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

    private static let aims: [(k: String, title: String, sub: String, symbol: String)] = [
        ("lose", "Lose weight", "Steadily, still eating what you love", "flame.fill"),
        ("stuck", "My weight's not moving", "Find where it's slipping", "pause.circle.fill"),
        ("muscle", "Build muscle", "Enough protein and food to grow", "dumbbell.fill"),
        ("steady", "Stay where I am", "Keep it steady", "equal.circle.fill"),
        ("better", "Just eat a bit better", "Feel good, no big changes", "leaf.fill")
    ]

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("What are you after?", "Then we'll go through your meals, and you choose what stays.")
            ForEach(Self.aims, id: \.k) { a in
                ChoiceCard(title: a.title, sub: a.sub, symbol: a.symbol, on: aim == a.k) { aim = a.k }
            }
            Text("Anything you'd like to improve?").font(.headline).padding(.top, 10)
            Text("Optional. If you're happy with how you eat, leave these.").font(.footnote).foregroundStyle(.secondary)
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

    // MARK: 2 cooking and cuisines

    private var cookStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("How do you feel about cooking?", "So the ideas suit you, from proper recipes to no-cook.")
            ForEach(Habits.cookLevels, id: \.k) { c in
                ChoiceCard(title: c.title, sub: c.sub, symbol: c.symbol, on: cook == c.k) { cook = c.k }
            }
            Text("Cuisines you like").font(.headline).padding(.top, 10)
            Flow {
                ForEach(Habits.cuisines + cuisines.subtracting(Habits.cuisines).sorted(), id: \.self) { c in
                    Chip(text: c, on: cuisines.contains(c)) { if cuisines.contains(c) { cuisines.remove(c) } else { cuisines.insert(c) } }
                }
            }
        }
    }

    // MARK: 3 to 6, a meal at a time

    private func mealStep(_ meal: String) -> some View {
        let i = Meals.all.firstIndex(of: meal) ?? 0
        let here = items.filter { $0.meal == meal }
        let skipped = skips.contains(meal)
        return VStack(alignment: .leading, spacing: 10) {
            heading(meal == "Snacks" ? "Snacks and drinks" : meal,
                    here.isEmpty ? "What do you usually have? Add a few things." : "What you usually have. Keep it, tweak it or swap it.")
            if verdict == "great" && i == 0 {
                Label(verdictLine.isEmpty ? "Your diet already looks great. Keep it all, or switch things up if you like." : verdictLine, systemImage: "checkmark.seal.fill")
                    .font(.subheadline).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
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
            ideaList(meal)
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

    @ViewBuilder private func ideaList(_ meal: String) -> some View {
        let here = ideas.indices.filter { str(ideas[$0]["meal"]) == meal }
        if !here.isEmpty || asking {
            Text("Ideas for \(meal == "Snacks" ? "snacks" : meal.lowercased())").font(.headline).padding(.top, 10)
            Text("Picked for what you're after. Tap one for its recipe, and the heart for the ones you'd try.").font(.footnote).foregroundStyle(.secondary)
        }
        if here.isEmpty && asking {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finding ideas…").font(.footnote).foregroundStyle(.secondary) }
        }
        ForEach(here, id: \.self) { k in
            let m = ideas[k], on = m["picked"] as? Bool == true
            HStack(spacing: 12) {
                Button { open = IdeaRef(id: str(m["name"]), idea: m) } label: {
                    HStack(spacing: 12) {
                        FoodDot(name: str(m["name"]), size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(str(m["name"])).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                            Text(str(m["why"])).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            Text("See the recipe").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.int(num(m["kcal"]) ?? 0)).font(.subheadline.weight(.heavy)).monospacedDigit()
                            Text("\(Int(num(m["protein"]) ?? 0))g protein").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { ideas[k]["picked"] = !on } label: {
                    Image(systemName: on ? "heart.fill" : "heart").font(.title3).foregroundStyle(on ? Theme.warn : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(on ? "Don't try this" : "I'd try this")
                .sensoryFeedback(.selection, trigger: on)
            }
            .padding(12)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(on ? Theme.warn : .clear, lineWidth: 1.5))
        }
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
        let great = verdict == "great" && save < 50
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Your food, your way", color: Theme.heroLabel)
                Text(great ? "Your diet's already great" : save >= 50 ? "About \(Fmt.int((save / 10).rounded() * 10)) kcal a week" : "Your food plan").font(.largeTitle.bold())
                Text(great ? (verdictLine.isEmpty ? "Nothing needs to change. Go back and switch things up if you fancy a change." : verdictLine)
                     : save >= 50 ? "Saved, without giving up what you love." : "Keep what you love. Change a little at a time.").foregroundStyle(.secondary)
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
            let tryThese = ideas.filter { $0["picked"] as? Bool == true }
            if !tryThese.isEmpty {
                Eyebrow(text: "Meals to try").padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(tryThese.indices, id: \.self) { i in
                        let m = tryThese[i]
                        Button { open = IdeaRef(id: str(m["name"]), idea: m) } label: { HStack(spacing: 10) {
                            FoodDot(name: str(m["name"]), size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(str(m["name"])).font(.subheadline.weight(.semibold))
                                Text(str(m["meal"])).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Text("\(Fmt.int(num(m["kcal"]) ?? 0)) kcal").font(.caption.weight(.bold)).foregroundStyle(.secondary).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        if i < tryThese.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            Text("Every idea is in Add for its meal, ready to log in a tap. Each week, one of these comes up with your weigh-in. The assistant knows what you're keeping, so it won't nag about those. Change it any time in Me.")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
        }
    }

    private func summary(_ h: Habit) -> some View {
        let (tag, tint): (String, Color) = h.plan == nil ? ("Keep", Theme.accent) : h.choice == "tweak" ? ("Tweak", Theme.warn) : ("Swap", Theme.heroLabel)
        return HStack(spacing: 10) {
            Text(tag).font(.caption.weight(.bold)).foregroundStyle(Theme.onAccent)
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
        guard !todo.isEmpty || withTips else { return }
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
            "tips": ["type": "array", "items": ["type": "string"] as JSON, "description": "One short, specific action per goal, under 12 words"] as JSON,
            "ideas": ["type": "array", "items": ["type": "object", "properties": [
                "meal": ["type": "string", "enum": ["Breakfast", "Lunch", "Dinner", "Snacks"]] as JSON,
                "name": ["type": "string", "description": "A real dish or order, under 7 words"] as JSON,
                "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON, "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON,
                "why": ["type": "string", "description": "Under 10 words, e.g. 'Like your toast, twice the protein'"] as JSON
            ] as JSON, "required": ["meal", "name", "kcal", "protein", "carbs", "fat", "why"]] as JSON] as JSON,
            "verdict": ["type": "string", "enum": ["great", "good", "work"], "description": "great when what they eat already suits what they're after and nothing needs to change"] as JSON,
            "verdictLine": ["type": "string", "description": "One warm, honest sentence under 20 words on how their eating suits their aim"] as JSON
        ] as JSON, "required": ["items", "tips", "verdict", "verdictLine"]]
        let prompt = """
        Someone in \(Plan.country) wants to eat better without giving up what they love. Daily budget about \(Int(store.budgetToday)) kcal\(store.proteinGoal.map { ", protein goal \(Int($0)) g" } ?? "").
        What they're after: \(aimText). What they'd like to improve: \(goals.isEmpty ? "nothing in particular" : goals.sorted().joined(separator: ", ")).
        Never suggest: \(avoid.isEmpty ? "nothing" : avoid).
        For each thing they usually have (id | meal | food | how often), suggest one realistic tweak and one swap using products and portions from there, aimed at their goals. Honest kcal per time. Pick keep for things that are already fine, or tiny. If their eating already suits what they're after, say so honestly (verdict great) and pick keep for everything: the tweaks and swaps are then just ideas to switch things up. Don't invent problems.
        \(lines.isEmpty ? "(no foods this time, items can be empty)" : lines)
        \(withTips ? "Also give one tip per goal, the verdict on their whole day, and 3 meal ideas for each of Breakfast, Lunch, Dinner and Snacks (\(ideaBrief)). Ideas are real food they'd want, matched to how much they like cooking: authentic, familiar dishes, home-cooked or easy orders, close to what they already like, sized for one portion (breakfast about \(Int(store.budgetToday * 0.25)), lunch \(Int(store.budgetToday * 0.3)), dinner \(Int(store.budgetToday * 0.35)), snacks under \(Int(store.budgetToday * 0.12)) kcal) and honest kcal and macros." : "Tips and ideas can be empty; verdict good.")
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
                if withTips {
                    tips = (a["tips"] as? [String] ?? []).filter { !$0.isEmpty }
                    verdict = str(a["verdict"]); verdictLine = str(a["verdictLine"])
                    ideas = list(a["ideas"]).filter { !str($0["name"]).isEmpty && pos($0["kcal"]) != nil }
                }
            }
        } catch {
            problem = "Couldn't get ideas just now. Write your own, or try again later from Me."
            for i in items.indices where todo.contains(where: { $0.id == items[i].id }) { items[i].asked = true }
        }
    }

    private var ideaBrief: String {
        let p = dict(store.doc["prefs"])
        let loves = (p["loves"] as? [String] ?? []).joined(separator: ", "), cuisines = (p["cuisines"] as? [String] ?? []).joined(separator: ", ")
        let skipped = skips.isEmpty ? "" : "; they skip \(skips.sorted().joined(separator: " and ").lowercased()), so none for that"
        let liked = self.cuisines.isEmpty ? cuisines : self.cuisines.sorted().joined(separator: ", ")
        return "they \(Habits.cookText(cook)); they love \(loves.isEmpty ? "not said" : loves); cuisines they like \(liked.isEmpty ? "anything" : liked), mostly ideas from these\(skipped)"
    }

    private var aimText: String {
        switch aim {
        case "lose": return "lose weight"
        case "stuck": return "their weight isn't moving and they want it to start going down again"
        case "muscle": return "build muscle (enough protein and food)"
        case "steady": return "stay at the weight they are"
        default: return "just eat a bit better, no big changes"
        }
    }

    // MARK: saving

    private func prefill() {
        let h = store.habits
        if let c = h["cook"] as? String, !c.isEmpty { cook = c }
        cuisines = Set(h["cuisines"] as? [String] ?? dict(store.doc["prefs"])["cuisines"] as? [String] ?? [])
        if let a = h["aim"] as? String, !a.isEmpty { aim = a }
        else {
            switch str(dict(store.doc["plan"])["goal"]) {
            case "lose": aim = "lose"
            case "leanbulk", "recomp": aim = "muscle"
            case "maintain": aim = "steady"
            default: break
            }
        }
        let saved = store.habitItems
        if !saved.isEmpty {
            items = saved
            goals = Set(h["goals"] as? [String] ?? [])
            skips = Set(h["skips"] as? [String] ?? [])
            tips = h["tips"] as? [String] ?? []
            verdict = str(h["verdict"]); verdictLine = str(h["verdictLine"])
            ideas = list(h["ideas"])
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
        let ideas = self.ideas.map { i -> JSON in
            guard i["recipe"] == nil, let r = RecipeMaker.shared.recipe(for: i) else { return i }
            var c = i; c["recipe"] = r; return c
        }
        store.saveHabits([
            "aim": aim, "cook": cook, "cuisines": cuisines.sorted(), "ideas": ideas.filter { !skips.contains(str($0["meal"])) }, "verdict": verdict, "verdictLine": verdictLine, "goals": goals.sorted(), "items": kept.map(\.json), "tips": tips, "skips": skips.sorted(), "updatedAt": ISO.now()
        ])
        Task { await Reminders.reschedule(store) }
        close()
    }
}
