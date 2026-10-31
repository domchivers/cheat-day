import SwiftUI

/// The parts of a cheat day plan that don't need a screen.
enum CheatPlan {
    /// What was typed under "What's on?": commas make separate things.
    static func whats(from typed: String) -> [String] {
        typed.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces).capitalizedFirst }.filter { !$0.isEmpty }
    }

    /// The meal a slot belongs under, from its time; a cheeky extra is a snack whenever it is.
    static func meal(of slot: JSON) -> String {
        if slot["extra"] as? Bool == true { return "Snacks" }
        return Meals.byTime(Int(str(slot["time"]).split(separator: ":").first ?? ""))
    }

    static func logged(_ slot: JSON, in items: [JSON]) -> Bool {
        let name = str(slot["title"]).lowercased()
        return !name.isEmpty && items.contains { str($0["name"]).lowercased() == name }
    }

    /// The day's total: what's logged plus the slots still to come (a slot already logged counts once).
    static func total(slots: [JSON], logged items: [JSON]) -> Double {
        let eaten = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return slots.filter { !logged($0, in: items) }.reduce(eaten) { $0 + (num($1["kcal"]) ?? 0) }
    }

    /// A slot as an idea, for the recipe screen and for logging.
    static func idea(_ slot: JSON) -> JSON {
        ["name": str(slot["title"]), "kcal": num(slot["kcal"]) ?? 0, "protein": num(slot["protein"]) ?? 0, "carbs": num(slot["carbs"]) ?? 0,
         "fat": num(slot["fat"]) ?? 0, "why": str(slot["detail"]), "meal": meal(of: slot)]
    }
}

/// Plan your cheat day: what kind of day, what's on, keep protein or not, then a timeline that makes the most of it.
struct CheatDayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "smart"
    @State private var whats: Set<String> = []
    @State private var newWhat = ""
    @State private var keepProtein = true
    @State private var training = true
    @State private var cheeky = "Properly"
    @State private var busy = false
    @State private var problem: String?
    @State private var replan = false
    @State private var setupDay = 6
    @State private var setupSize = 1.3
    @State private var cooking = "Eating out"
    @State private var open: IdeaRef?
    @State private var swapping: Set<String> = []
    @AppStorage("pantry") private var pantry = ""
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }
    private static let cookChoices = ["Eating out", "Quick, 15 min", "Happy to cook"]
    private let ideas = ["Yum cha", "Pizza night", "Sunday roast", "Curry night", "Burgers", "BBQ", "Brunch out", "Fish and chips", "Drinks out", "Dessert", "Takeaway", "Movie snacks"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let next = store.nextCheat {
                        if let saved = store.cheatPlan(next.date), !replan { planView(saved, next: next) }
                        else { form(next) }
                    } else {
                        setup
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
                .animation(.snappy, value: replan)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .keyboardDone()
            .navigationTitle("Cheat day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.bold) } }
            .sheet(item: $open) { r in RecipeSheet(idea: r.idea) }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    }

    private func when(_ date: String) -> String {
        date == store.today ? "Today" : DayKey.shift(store.today, days: 1) == date ? "Tomorrow" : DayKey.date(date).formatted(.dateTime.weekday(.wide))
    }

    private func top(_ next: (date: String, kcal: Double, extra: Double)) -> some View {
        let isToday = next.date == store.today, eaten = isToday ? store.eaten : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                PizzaIcon(size: 34).scaleEffect(y: -1)
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: when(next.date), color: Theme.warn)
                    Text(eaten > 0 ? "\(Fmt.int(max(0, store.budgetToday - eaten))) kcal left" : "\(Fmt.int(next.kcal)) kcal to play with").font(.title2.weight(.heavy))
                }
            }
            if eaten > 0 {
                Text("\(Fmt.int(store.budgetToday)) today, \(Fmt.int(eaten)) already logged.\(proteinToGo.map { " \(Int($0)) g protein to go." } ?? "")").font(.footnote).foregroundStyle(.secondary)
            } else if next.extra > 0 { Text("That's \(Fmt.int(next.extra)) more than a normal day, banked through the week.").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, 8)
    }

    private var proteinToGo: Double? { store.proteinGoal.map { max(0, $0 - store.macros(store.todayItems).p).rounded() } }

    /// Whatever's in the box counts, however you leave it: return, the +, the keyboard's Done, or going straight to Plan.
    private func keepTyped() {
        whats.formUnion(CheatPlan.whats(from: newWhat))
        newWhat = ""
    }

    // MARK: choosing

    private func form(_ next: (date: String, kcal: Double, extra: Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            top(next)
            label("What kind of day?")
            ChoiceCard(title: "Smart cheat", sub: "Eat what you want, with the day planned around it", symbol: "brain.head.profile", on: kind == "smart") { kind = "smart" }
            ChoiceCard(title: "One big meal", sub: "Light and high protein all day, then go all out", symbol: "fork.knife", on: kind == "big") { kind = "big" }
            ChoiceCard(title: "Full send", sub: "No counting. Just a few tips so Monday's easy", symbol: "party.popper.fill", on: kind == "full") { kind = "full" }
            label("What's on?")
            Flow {
                ForEach(ideas + whats.subtracting(ideas).sorted(), id: \.self) { w in
                    Chip(text: w, on: whats.contains(w)) { if whats.contains(w) { whats.remove(w) } else { whats.insert(w) } }
                }
            }
            HStack {
                TextField("Something else, like a birthday dinner", text: $newWhat).submitLabel(.done).focused($typing)
                    .onSubmit(keepTyped)
                    .onChange(of: typing) { _, t in if !t { keepTyped() } }
                Button(action: keepTyped) { Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Theme.accent).frame(width: 44, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Add to what's on")
            }
            .padding(12).background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            label("How much cooking?")
            Flow { ForEach(Self.cookChoices, id: \.self) { c in Chip(text: c, on: cooking == c) { cooking = c } } }
            label("How cheeky?")
            Flow { ForEach(["A bit", "Properly", "Go wild"], id: \.self) { c in Chip(text: c, on: cheeky == c) { cheeky = c } } }
            VStack(spacing: 0) {
                Toggle(isOn: $keepProtein) { VStack(alignment: .leading, spacing: 1) { Text("Still hit my protein"); Text("\(Int(store.proteinGoal ?? 0)) g").font(.caption).foregroundStyle(.secondary) } }
                    .padding(.vertical, 10)
                Divider()
                Toggle("Fit a workout in", isOn: $training).padding(.vertical, 10)
            }
            .padding(.horizontal, 16)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 6)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
            Button { typing = false; keepTyped(); Task { await make(next) } } label: {
                Label(busy ? "Planning your day…" : next.date == store.today ? "Plan the rest of my day" : "Plan my day", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).foregroundStyle(Theme.onAccent)
            .disabled(busy).padding(.top, 8)
            if replan, store.cheatPlan(next.date) != nil {
                Button("Keep the plan I had") { withAnimation(.snappy) { replan = false } }.frame(maxWidth: .infinity).padding(.top, 4)
            }
        }
    }

    // MARK: the plan

    private func planView(_ plan: JSON, next: (date: String, kcal: Double, extra: Double)) -> some View {
        let slots = list(plan["slots"]), isToday = next.date == store.today
        let logged = isToday ? store.todayItems : []
        let extras = logged.filter { item in !slots.contains { CheatPlan.logged($0, in: [item]) } }
        let kcal = CheatPlan.total(slots: slots, logged: logged)
        let protein = slots.filter { !CheatPlan.logged($0, in: logged) }.reduce(store.macros(logged).p) { $0 + (num($1["protein"]) ?? 0) }
        let budget = isToday ? store.budgetToday : next.kcal
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: when(next.date), color: Theme.warn).padding(.top, 8)
            Text(str(plan["title"])).font(.title.bold())
            if !str(plan["from"]).isEmpty { Text("From \(str(plan["from"])), around what you've already had").font(.footnote).foregroundStyle(Theme.walk) }
            ForEach(extras.indices, id: \.self) { i in
                HStack(spacing: 12) {
                    Text(str(extras[i]["name"])).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(Fmt.int(num(extras[i]["kcal"]) ?? 0)).font(.caption.weight(.bold)).monospacedDigit()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.walk)
                }
                .padding(14).background(Theme.hero.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            ForEach(slots.indices, id: \.self) { i in slotRow(slots[i], at: i, plan: plan, next: next, isToday: isToday) }
            HStack {
                Text("\(Fmt.int(kcal)) of \(Fmt.int(budget)) kcal").font(.subheadline.weight(.bold))
                Spacer()
                if let goal = store.proteinGoal, protein > 0 {
                    Label("\(Int(protein)) / \(Int(goal)) g protein", systemImage: protein >= goal * 0.95 ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.bold)).foregroundStyle(protein >= goal * 0.95 ? Color.green : .secondary)
                }
            }
            .padding(.horizontal, 4)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
            Text("Tap a meal for what's in it. The arrows swap just that one.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            let tips = plan["tips"] as? [String] ?? []
            if !tips.isEmpty {
                label("Make the most of it")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tips, id: \.self) { t in Label(t, systemImage: "lightbulb.fill").font(.footnote) }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Button { restore(plan); replan = true } label: { Label("Plan it differently", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)).padding(.top, 6)
        }
    }

    private func slotRow(_ s: JSON, at i: Int, plan: JSON, next: (date: String, kcal: Double, extra: Double), isToday: Bool) -> some View {
        let isWorkout = s["workout"] as? Bool == true, big = (num(s["kcal"]) ?? 0) >= next.kcal * 0.35, title = str(s["title"])
        let done = isToday && CheatPlan.logged(s, in: store.todayItems)
        return HStack(spacing: 10) {
            Button { if !isWorkout { open = IdeaRef(id: title, idea: CheatPlan.idea(s)) } } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 4) {
                        Text(str(s["time"])).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: isWorkout ? "dumbbell.fill" : big ? "star.fill" : "fork.knife")
                            .font(.caption).foregroundStyle(big ? Theme.warn : Theme.accent)
                    }
                    .frame(width: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).multilineTextAlignment(.leading)
                        Text(str(s["detail"])).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        if (num(s["kcal"]) ?? 0) > 0 {
                            Text("\(Fmt.int(num(s["kcal"]) ?? 0)) kcal · \(Int(num(s["protein"]) ?? 0)) g protein").font(.caption.weight(.bold)).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isWorkout {
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.walk).accessibilityLabel("Logged")
                } else {
                    Button { Task { await swap(i, plan: plan, next: next) } } label: {
                        Group {
                            if swapping.contains(title) { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.accent) }
                        }
                        .frame(width: 36, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).disabled(!swapping.isEmpty).accessibilityLabel("Swap \(title)")
                    if isToday {
                        Button {
                            store.add(Assistant.basis(name: title, kcal: num(s["kcal"]) ?? 0, grams: nil, p: num(s["protein"]) ?? 0, c: num(s["carbs"]) ?? 0, f: num(s["fat"]) ?? 0), kcal: num(s["kcal"]) ?? 0, meal: CheatPlan.meal(of: s))
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.borderless).accessibilityLabel("Add \(title) to \(CheatPlan.meal(of: s).lowercased())")
                    }
                }
            }
        }
        .padding(14)
        .background(big ? Color(red: 0.16, green: 0.13, blue: 0.07) : Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(done ? 0.6 : 1)
        .overlay {
            if s["extra"] as? Bool == true {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.warn, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .overlay(alignment: .topTrailing) {
            if s["extra"] as? Bool == true {
                Text("Cheeky extra").font(.caption2.weight(.heavy)).foregroundStyle(Theme.warn).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.bg, in: Capsule()).offset(x: -14, y: -9)
            }
        }
    }

    /// "Plan it differently" starts from what you chose last time.
    private func restore(_ plan: JSON) {
        problem = nil
        if !str(plan["kind"]).isEmpty { kind = str(plan["kind"]) }
        whats = Set(plan["whats"] as? [String] ?? [])
        if !str(plan["cheeky"]).isEmpty { cheeky = str(plan["cheeky"]) }
        if !str(plan["cooking"]).isEmpty { cooking = str(plan["cooking"]) }
        if let p = plan["keepProtein"] as? Bool { keepProtein = p }
        if let t = plan["training"] as? Bool { training = t }
    }

    private var slotProperties: JSON {
        ["time": ["type": "string", "description": "24-hour time like 09:00"] as JSON,
         "title": ["type": "string"] as JSON,
         "detail": ["type": "string", "description": "Under 22 words: what to have, or the move that makes it better"] as JSON,
         "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON, "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON,
         "workout": ["type": "boolean"] as JSON,
         "extra": ["type": "boolean", "description": "true for the one cheeky extra treat added because there's room"] as JSON]
    }

    private var slotRequired: [String] { ["time", "title", "detail", "kcal", "protein", "carbs", "fat", "workout", "extra"] }

    private var cookingLine: String {
        if cooking == Self.cookChoices[0] { return "They're eating out or getting food in: name real orders, nothing to cook." }
        let have = pantry.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cooking == Self.cookChoices[1] ? "Quick food at home, 15 minutes or so, or shop-bought." : "They're happy to cook properly.") + (have.isEmpty ? "" : " They have in: \(have).")
    }

    private func nowText() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// One meal changed for something else of about the same size, keeping the rest of the plan.
    private func swap(_ i: Int, plan: JSON, next: (date: String, kcal: Double, extra: Double)) async {
        var slots = list(plan["slots"])
        guard slots.indices.contains(i) else { return }
        let s = slots[i], title = str(s["title"])
        swapping.insert(title); problem = nil
        defer { swapping.remove(title) }
        let others = slots.map { str($0["title"]) }.joined(separator: ", ")
        let avoid = (dict(store.doc["prefs"])["avoid"] as? [String] ?? []).joined(separator: ", ")
        let what = plan["whats"] as? [String] ?? []
        let prompt = """
        A cheat day plan for someone in \(Plan.country) has these: \(others). They want something else instead of "\(title)" at \(str(s["time"])).
        Suggest one different treat of about \(Int(num(s["kcal"]) ?? 0)) kcal and at least \(Int(num(s["protein"]) ?? 0)) g protein. Keep the same time. It must not repeat anything in the plan.
        \(what.isEmpty ? "" : "The day is built around: \(what.joined(separator: ", ")). Keep that feel.") \(avoid.isEmpty ? "" : "Never include: \(avoid).")
        A real dish or order, numbers from standard reference values. workout false, extra \(s["extra"] as? Bool == true).
        """
        do {
            let schema: JSON = ["type": "object", "properties": slotProperties, "required": slotRequired]
            var a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true, tries: 3)
            a["time"] = s["time"]; a["workout"] = false; a["extra"] = s["extra"] ?? false
            slots[i] = a
            var p = plan; p["slots"] = slots
            store.perform(["type": "cheatPlan", "date": next.date, "plan": p])
        } catch { problem = error.localizedDescription }
    }

    private func make(_ next: (date: String, kcal: Double, extra: Double)) async {
        busy = true; problem = nil
        defer { busy = false }
        let prefs = dict(store.doc["prefs"])
        let loves = (prefs["loves"] as? [String] ?? []).joined(separator: ", ")
        let cuisines = (prefs["cuisines"] as? [String] ?? []).joined(separator: ", ")
        let avoid = (prefs["avoid"] as? [String] ?? []).joined(separator: ", ")
        let fromPrefs: String? = list(prefs["training"]).first { Int(num($0["weekday"]) ?? -1) == DayKey.weekday(next.date) }.map { str($0["name"]) }
        let workout = store.workoutPlan?.session(on: next.date)?.name ?? fromPrefs
        let style: String
        switch kind {
        case "big": style = "One big meal: keep the rest of the day light and high in protein so the main event gets most of the calories."
        case "full": style = "Full send: they won't count today. Don't police it. Make it feel great, give rough kcal anyway, and a few tips so getting back to normal tomorrow is easy."
        default: style = "Smart cheat: they eat what they want, planned so the treats get the calories and nothing is wasted on food they don't care about."
        }
        let schema: JSON = ["type": "object", "properties": [
            "title": ["type": "string", "description": "A short fun title for the day, e.g. 'Yum cha and drinks'"] as JSON,
            "slots": ["type": "array", "items": ["type": "object", "properties": slotProperties, "required": slotRequired] as JSON] as JSON,
            "tips": ["type": "array", "items": ["type": "string"] as JSON, "description": "3 short tips, under 16 words each"] as JSON
        ] as JSON, "required": ["title", "slots", "tips"]]
        let isToday = next.date == store.today, from = nowText()
        let had = isToday ? store.todayItems.map { "\(str($0["name"])) (\(Int(num($0["kcal"]) ?? 0)) kcal)" }.joined(separator: ", ") : ""
        let budget = isToday ? max(0, store.budgetToday - store.eaten) : next.kcal
        let protein = isToday ? (proteinToGo ?? 120) : (store.proteinGoal ?? 120)
        let prompt = """
        Plan a cheat day for someone in \(Plan.country). It should feel like a treat, not a diet.
        \(isToday ? "It's already \(from) today, so plan only from now on: every slot's time is after \(from), with no meal they've missed." : "")
        \(had.isEmpty ? "" : "Already logged today: \(had). Don't list these again.")
        Budget for the slots: about \(Int(budget)) kcal\(kind == "full" ? " (a guide only)" : ""). \(keepProtein ? "Reach at least \(Int(protein)) g protein across the slots without it feeling like diet food." : "Protein doesn't matter today.")
        \(style)
        What's on: \(whats.isEmpty ? "nothing fixed, suggest a great day around the foods they love" : "\(whats.sorted().joined(separator: ", ")). This is what they asked for: each one must be its own named slot, and the title and the rest of the day follow from them").
        \(cookingLine)
        Foods they love: \(loves.isEmpty ? "not said" : loves). Cuisines: \(cuisines.isEmpty ? "anything" : cuisines). Never include: \(avoid.isEmpty ? "nothing" : avoid).
        \(training ? "Include one workout slot (workout true, kcal 0) before the biggest meal\(workout.map { ": their plan has \($0) that day" } ?? ", ideally legs or full body"). The big meal after training helps recovery." : "No workout today.")
        How cheeky: \(cheeky). \(cheeky == "A bit" ? "Treats, but sensible portions and some lighter picks." : cheeky == "Go wild" ? "Go big and indulgent: the full fat, the extra side, dessert, a proper shake. Off the books, have fun with it." : "Proper treats, no lighter swaps unless they really don't cost the fun.")
        If there's room left in the budget, add one cheeky extra treat slot (extra true): a shake, dessert, a pastry, something fun, and say there's room for it.
        What they normally have for dinner lately: \(store.mealHistory("Dinner").prefix(8).map(\.name).joined(separator: ", ")). Lean into those cuisines unless what's on says otherwise.
        4 to 6 slots. Name real dishes and orders from those places, with smart choices that keep the fun (e.g. which yum cha dishes give most for the calories, spirits with soda over pints).
        Tips: hydration, sleep, and getting straight back to normal tomorrow. Never suggest skipping meals the next day or making up for it.
        """
        do {
            var a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: false)
            a["kind"] = kind; a["whats"] = whats.sorted(); a["cheeky"] = cheeky; a["at"] = ISO.now()
            a["cooking"] = cooking; a["keepProtein"] = keepProtein; a["training"] = training
            if isToday && store.eaten > 0 { a["from"] = from }
            store.perform(["type": "cheatPlan", "date": next.date, "plan": a])
            withAnimation(.snappy) { replan = false }
        } catch { problem = error.localizedDescription }
    }

    // MARK: no cheat day yet

    private var setup: some View {
        let base = store.baseBudget(store.today)
        let cheat = Plan.r10(base * setupSize), everyday = Plan.r10((base * 7 - Double(cheat)) / 6)
        return VStack(alignment: .leading, spacing: 10) {
            PizzaIcon(size: 54).scaleEffect(y: -1).padding(.top, 10)
            Text("Pick a cheat day").font(.largeTitle.bold())
            Text("Eat a little less on normal days and spend it on one day. Same weekly total, so you stay on track.").foregroundStyle(.secondary)
            label("Which day?")
            HStack(spacing: 6) {
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                    Button { setupDay = d } label: {
                        Text(Calendar.current.shortWeekdaySymbols[d].prefix(2)).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(setupDay == d ? Theme.warn : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(setupDay == d ? Theme.onAccent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            label("How big?")
            Picker("Size", selection: $setupSize) { Text("A bit more").tag(1.3); Text("Lots more").tag(1.5); Text("Go big").tag(1.7) }.pickerStyle(.segmented)
            VStack(spacing: 10) {
                HStack { Text(Calendar.current.weekdaySymbols[setupDay]).foregroundStyle(.secondary); Spacer(); Text("\(Fmt.int(Double(cheat))) kcal").font(.title3.weight(.heavy)).foregroundStyle(Theme.warn) }
                HStack { Text("Other days").foregroundStyle(.secondary); Spacer(); Text("\(Fmt.int(Double(everyday))) kcal").font(.title3.weight(.heavy)) }
            }
            .padding(16).background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !dict(store.doc["dayBudgets"]).isEmpty {
                Text("This replaces the different budgets you have on some days.").font(.footnote).foregroundStyle(Theme.warn)
            }
            Button {
                store.perform(["type": "cheatSpread", "day": setupDay, "cheat": cheat, "everyday": everyday])
            } label: {
                Text("Set my cheat day").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).foregroundStyle(Theme.onAccent).padding(.top, 8)
        }
    }
}
