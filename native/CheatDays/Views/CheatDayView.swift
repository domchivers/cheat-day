import SwiftUI

/// The parts of a cheat day plan that don't need a screen.
enum CheatPlan {
    /// The meal a slot belongs under, from its time.
    static func meal(of slot: JSON) -> String {
        Meals.byTime(Int(str(slot["time"]).split(separator: ":").first ?? ""))
    }

    static func logged(_ slot: JSON, in items: [JSON]) -> Bool {
        loggedItem(slot, in: items) != nil
    }

    /// What was really logged for a slot, the healthier version of its recipe included.
    static func loggedItem(_ slot: JSON, in items: [JSON]) -> JSON? {
        let name = str(slot["title"]).lowercased()
        guard !name.isEmpty else { return nil }
        return items.first { let n = str($0["name"]).lowercased(); return n == name || n == name + " (lighter)" }
    }

    /// The slot takes the numbers its recipe adds up to, and keeps the recipe, so the plan and the recipe always
    /// agree, your swaps included. Nil when nothing's changed. Protein is whole grams, as the recipe shows it.
    static func following(_ slots: [JSON], title: String, recipe: JSON, kcal: Double, protein: Double, carbs: Double, fat: Double) -> [JSON]? {
        guard let i = slots.firstIndex(where: { str($0["title"]) == title }) else { return nil }
        func steps(_ r: JSON) -> Int { (dict(r["authentic"])["steps"] as? [String] ?? []).count }
        let numbers: [(String, Double)] = [("kcal", kcal.rounded()), ("protein", protein.rounded(.down)), ("carbs", carbs.rounded(.down)), ("fat", fat.rounded(.down))]
        let had = slots[i]["recipe"] as? JSON
        if numbers.allSatisfy({ num(slots[i][$0.0]) == $0.1 }), let had, steps(had) == steps(recipe) { return nil }
        var out = slots
        for (k, v) in numbers { out[i][k] = v }
        out[i]["recipe"] = recipe
        return out
    }

    /// Talking to the planner rewrites the slots: one that's still there keeps its recipe and the numbers it came to.
    static func keepingRecipes(_ new: [JSON], from old: [JSON]) -> [JSON] {
        new.map { s in
            guard let was = old.first(where: { str($0["title"]) == str(s["title"]) }), let r = was["recipe"] as? JSON else { return s }
            var x = s
            x["recipe"] = r
            for k in ["kcal", "protein", "carbs", "fat"] { x[k] = was[k] ?? s[k] }
            return x
        }
    }

    /// The day's total: what's logged plus the slots still to come (a slot already logged counts once).
    static func total(slots: [JSON], logged items: [JSON]) -> Double {
        let eaten = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return slots.filter { !logged($0, in: items) }.reduce(eaten) { $0 + (num($1["kcal"]) ?? 0) }
    }

    /// A slot naming one of your saved meals takes that meal's real numbers, not the AI's; slots go in time order.
    static func tidied(_ slots: [JSON], saved: [String: JSON]) -> [JSON] {
        slots.map { s -> JSON in
            guard let b = saved[str(s["saved"]).lowercased()] else { return s }
            var x = s
            x["kcal"] = (num(b["kcalPerServing"]) ?? num(s["kcal"]) ?? 0).rounded()
            x["protein"] = (num(b["pServ"]) ?? num(s["protein"]) ?? 0).rounded()
            x["carbs"] = (num(b["cServ"]) ?? num(s["carbs"]) ?? 0).rounded()
            x["fat"] = (num(b["fServ"]) ?? num(s["fat"]) ?? 0).rounded()
            x["title"] = b["name"] ?? s["title"]
            return x
        }
        .sorted { str($0["time"]) < str($1["time"]) }
    }

    /// A slot as an idea, for the recipe screen and for logging.
    static func idea(_ slot: JSON) -> JSON {
        var i: JSON = ["name": str(slot["title"]), "kcal": num(slot["kcal"]) ?? 0, "protein": num(slot["protein"]) ?? 0, "carbs": num(slot["carbs"]) ?? 0,
                       "fat": num(slot["fat"]) ?? 0, "why": str(slot["detail"]), "meal": meal(of: slot), "saved": str(slot["saved"])]
        if let r = slot["recipe"] { i["recipe"] = r }
        return i
    }
}

/// Plan your cheat day as a conversation: say what you're after, get only that with what's left to enjoy, then keep
/// talking to change it.
struct CheatDayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var starting = false
    @State private var busy = false
    @State private var sent: String?   // what you just asked, on screen while the answer comes
    @State private var problem: String?
    @State private var open: IdeaRef?
    @State private var setupDay = 6
    @State private var setupSize = 1.3
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }
    private static let starters = ["Leave room for snacks", "Something sweet", "Plan the whole day", "Eating out", "Go wild"]

    private var planFor: JSON? { store.nextCheat.flatMap { store.cheatPlan($0.date) } }

    var body: some View {
        NavigationStack {
            Group {
                if let next = store.nextCheat {
                    if busy && (planFor == nil || starting) { CheatPlanLoading().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
                    else if let plan = planFor, !starting { planView(plan, next: next) }
                    else { form(next) }
                } else {
                    ScrollView { setup.padding(.horizontal, 20).padding(.bottom, 30) }
                }
            }
            .animation(.snappy, value: starting)
            .animation(.snappy, value: busy)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .keyboardDone()
            .navigationTitle("Cheat day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.bold) } }
            .sheet(item: $open) { r in
                // a saved meal keeps its own real numbers; anything else follows what its recipe adds up to
                RecipeSheet(idea: r.idea, onNumbers: str(r.idea["saved"]).isEmpty ? { recipe, k, p, c, f in follow(r.id, recipe, k, p, c, f) } : nil)
            }
        }
    }

    private func follow(_ title: String, _ recipe: JSON, _ k: Double, _ p: Double, _ c: Double, _ f: Double) {
        guard let date = store.nextCheat?.date, var plan = store.cheatPlan(date),
              let slots = CheatPlan.following(list(plan["slots"]), title: title, recipe: recipe, kcal: k, protein: p, carbs: c, fat: f) else { return }
        plan["slots"] = slots
        store.perform(["type": "cheatPlan", "date": date, "plan": plan])
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    }

    private func when(_ date: String) -> String {
        date == store.today ? "Today" : DayKey.shift(store.today, days: 1) == date ? "Tomorrow" : DayKey.date(date).formatted(.dateTime.weekday(.wide))
    }

    private func budget(_ next: (date: String, kcal: Double, extra: Double)) -> Double { next.date == store.today ? store.budgetToday : next.kcal }
    private func loggedItems(_ next: (date: String, kcal: Double, extra: Double)) -> [JSON] { next.date == store.today ? store.todayItems : [] }

    // MARK: saying what you're after

    private func form(_ next: (date: String, kcal: Double, extra: Double)) -> some View {
        let eaten = loggedItems(next).reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, goal = store.proteinGoal
        let toGo = goal.map { max(0, $0 - store.macros(loggedItems(next)).p) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: when(next.date), color: Theme.warn).padding(.top, 8)
                Text("\(Fmt.int(max(0, budget(next) - eaten))) kcal \(eaten > 0 ? "left" : "to play with")").font(.title.weight(.heavy)).monospacedDigit()
                Text((eaten > 0 ? "\(Fmt.int(eaten)) of \(Fmt.int(budget(next))) logged" : "\(Fmt.int(next.extra)) more than a normal day") + (toGo.map { " · \(Int($0)) g protein to go" } ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
                label("What are you thinking?").padding(.top, 14)
                TextField("Chicken burger and ceviche, something sweet, and leave me room for snacks", text: $draft, axis: .vertical)
                    .lineLimit(4...9).focused($typing)
                    .padding(14).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 4)
                Text("Or start with").font(.caption).foregroundStyle(.secondary).padding(.top, 14)
                Flow {
                    ForEach(Self.starters, id: \.self) { s in
                        Chip(text: s, on: false) { draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? s : draft.trimmingCharacters(in: .whitespacesAndNewlines) + ", " + s.lowercased() }
                    }
                }
                .padding(.top, 2)
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).padding(.top, 10) }
                if starting, planFor != nil {
                    Button("Keep the plan I had") { starting = false; problem = nil }.font(.subheadline).frame(maxWidth: .infinity).padding(.top, 14)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                // an empty box: into it, rather than a button that does nothing
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { typing = true } else { Task { await send(next: next, plan: nil) } }
            } label: {
                Label("Plan it with me", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 20).padding(.vertical, 10).background(Theme.bg)
        }
    }

    // MARK: the plan

    private func planView(_ plan: JSON, next: (date: String, kcal: Double, extra: Double)) -> some View {
        let slots = list(plan["slots"]), logged = loggedItems(next)
        let extras = logged.filter { item in !slots.contains { CheatPlan.logged($0, in: [item]) } }
        let kcal = CheatPlan.total(slots: slots, logged: logged), room = budget(next) - kcal
        let protein = slots.filter { !CheatPlan.logged($0, in: logged) }.reduce(store.macros(logged).p) { $0 + (num($1["protein"]) ?? 0) }
        let lastMe = list(plan["chat"]).last { str($0["me"]).isEmpty == false }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let said = sent ?? lastMe.map({ str($0["me"]) }) {
                        Text(said).font(.subheadline).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 44).padding(.top, 8)
                    }
                    if busy { CheatPlanStatus().padding(.vertical, 4) }
                    else if !str(plan["reply"]).isEmpty { Text(str(plan["reply"])).font(.subheadline).foregroundStyle(.secondary).padding(.top, 2) }
                    Eyebrow(text: when(next.date), color: Theme.warn).padding(.top, 8)
                    Text(str(plan["title"])).font(.title2.bold()).padding(.bottom, 2)
                    VStack(spacing: 8) {
                        ForEach(extras.indices, id: \.self) { i in loggedRow(extras[i]) }
                        ForEach(slots.indices, id: \.self) { i in slotRow(slots[i], isToday: next.date == store.today) }
                    }
                    .opacity(busy ? 0.45 : 1)
                    .animation(.snappy, value: str(plan["at"]))
                    freeCard(room)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).padding(.top, 4) }
                    Button("Start again") { draft = ""; problem = nil; starting = true }
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 12).id("end")
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .simultaneousGesture(TapGesture().onEnded { typing = false })   // tap away to put the keyboard down
            .onChange(of: typing) { _, t in
                if t { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
            }
        }
        .onAppear { KeyboardDone.quiet = true }
        .onDisappear { KeyboardDone.quiet = false }
        .onChange(of: open?.id) { _, id in KeyboardDone.quiet = id == nil }   // a recipe's boxes keep their Done
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // always in view: the day's numbers, just above where you change them
                HStack {
                    Text("\(Fmt.int(kcal)) of \(Fmt.int(budget(next))) kcal").font(.footnote.weight(.bold)).monospacedDigit()
                    Spacer()
                    if let goal = store.proteinGoal, protein > 0 {
                        Label("\(Int(protein.rounded())) / \(Int(goal)) g protein", systemImage: protein >= goal * 0.95 ? "checkmark.circle.fill" : "circle")
                            .font(.footnote.weight(.bold)).monospacedDigit().foregroundStyle(protein >= goal * 0.95 ? Theme.walk : .secondary)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 10)
                dock(room, next: next, plan: plan)
            }
            .background(Theme.bg)
        }
        .sensoryFeedback(.success, trigger: str(plan["at"]))
    }

    private func loggedRow(_ item: JSON) -> some View {
        HStack(spacing: 12) {
            Text(str(item["name"])).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Text(Fmt.int(num(item["kcal"]) ?? 0)).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.walk)
            if !str(item["id"]).isEmpty {
                Menu {
                    Button(role: .destructive) { withAnimation(.snappy) { store.delete(str(item["id"])) } } label: { Label("Remove from today", systemImage: "minus.circle") }
                } label: { moreLabel }
                .accessibilityLabel("Change \(str(item["name"]))")
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 11)
        .background(Theme.hero.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func slotRow(_ s: JSON, isToday: Bool) -> some View {
        let isWorkout = s["workout"] as? Bool == true, title = str(s["title"])
        let eaten = isToday ? CheatPlan.loggedItem(s, in: store.todayItems) : nil, done = eaten != nil
        // once logged, the amount you logged: it's what the day's total counts
        let kcal = num(eaten?["kcal"]) ?? num(s["kcal"]) ?? 0, protein = eaten.map { store.macros([$0]).p } ?? num(s["protein"]) ?? 0
        return HStack(spacing: 12) {
            Button { if !isWorkout { open = IdeaRef(id: title, idea: CheatPlan.idea(s)) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(str(s["time"])).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        if !str(s["detail"]).isEmpty { Text(str(s["detail"])).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                        if kcal > 0 || done {
                            ((done ? Text("✓ Logged · ").foregroundStyle(Theme.walk) : Text(""))
                                + Text("\(Fmt.int(kcal)) kcal · \(Int(protein.rounded())) g protein"))
                                .font(.caption.weight(.semibold)).monospacedDigit().padding(.top, 1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isWorkout && !done && isToday {
                Button { logSlot(s) } label: { Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent).frame(width: 40, height: 40).contentShape(Rectangle()) }
                    .buttonStyle(.borderless).accessibilityLabel("Add \(title) to \(CheatPlan.meal(of: s).lowercased())")
            }
            Menu {
                if !isWorkout { Button { open = IdeaRef(id: title, idea: CheatPlan.idea(s)) } label: { Label("See the recipe", systemImage: "book") } }
                Button(role: .destructive) { withAnimation(.snappy) { remove(s, logged: eaten) } } label: {
                    Label(done ? "Remove from today and the plan" : "Remove from plan", systemImage: "minus.circle")
                }
            } label: { moreLabel }
            .accessibilityLabel("Change \(title)")
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 11)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var moreLabel: some View {
        Image(systemName: "ellipsis").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
            .frame(width: 30, height: 30).background(Theme.accent.opacity(0.12), in: Circle()).frame(width: 40, height: 40).contentShape(Rectangle())
    }

    /// Off the plan, and off today too if it was logged from it.
    private func remove(_ s: JSON, logged: JSON?) {
        if let id = logged.map({ str($0["id"]) }), !id.isEmpty { store.delete(id) }
        guard let date = store.nextCheat?.date, var plan = store.cheatPlan(date) else { return }
        plan["slots"] = list(plan["slots"]).filter { str($0["title"]) != str(s["title"]) }
        store.perform(["type": "cheatPlan", "date": date, "plan": plan])
    }

    private func logSlot(_ s: JSON) {
        let kcal = num(s["kcal"]) ?? 0, saved = savedMeals[str(s["title"]).lowercased()]
        let basis = saved ?? Assistant.basis(name: str(s["title"]), kcal: kcal, grams: nil, p: num(s["protein"]) ?? 0, c: num(s["carbs"]) ?? 0, f: num(s["fat"]) ?? 0)
        store.add(basis, kcal: kcal, meal: CheatPlan.meal(of: s))
    }

    /// What's left, its own line: the room to enjoy, or how far over.
    @ViewBuilder private func freeCard(_ room: Double) -> some View {
        if abs(room) >= 30 {
            VStack(alignment: .leading, spacing: 2) {
                Text(room > 0 ? "\(Fmt.int(room)) kcal free to enjoy" : "\(Fmt.int(-room)) kcal over").font(.headline).monospacedDigit().foregroundStyle(Theme.warn)
                Text(room > 0 ? "Snacks, a drink, whatever you fancy." : "Ask to trim something if you'd like.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.warn.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        }
    }

    private func dock(_ room: Double, next: (date: String, kcal: Double, extra: Double), plan: JSON) -> some View {
        let ideas = ["More protein", "Sweet treat"] + (room >= 150 ? ["Ideas for \(Fmt.int(room))"] : [])
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 8) {
            if empty && !typing && !busy {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ideas, id: \.self) { i in Chip(text: i, on: false) { draft = i; Task { await send(next: next, plan: plan) } } }
                    }
                    .padding(.horizontal, 20)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Change anything…", text: $draft, axis: .vertical).lineLimit(1...4).focused($typing)
                    .padding(.vertical, 6).padding(.leading, 6)
                Button { typing = false; Task { await send(next: next, plan: plan) } } label: {
                    Group {
                        if busy { ProgressView().tint(Theme.onAccent) }
                        else { Image(systemName: "arrow.up").font(.subheadline.weight(.bold)).foregroundStyle(Theme.onAccent) }
                    }
                    .frame(width: 32, height: 32).background(Theme.accent.opacity(empty && !busy ? 0.4 : 1), in: Circle())
                }
                .buttonStyle(.plain).disabled(empty || busy).accessibilityLabel("Send")
            }
            .padding(6).background(Theme.hero, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
        }
        .padding(.top, 8).padding(.bottom, 8).background(Theme.bg)
    }

    // MARK: talking to the planner

    /// Your saved meals by name, with their real numbers.
    private var savedMeals: [String: JSON] {
        Dictionary(list(store.doc["meals"]).map { store.mealBasis($0) }.map { (str($0["name"]).lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func send(next: (date: String, kcal: Double, extra: Double), plan: JSON?) async {
        let said = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !busy else { return }
        busy = true; problem = nil; sent = said; typing = false
        draft = ""
        defer { busy = false; sent = nil }
        let isToday = next.date == store.today, logged = loggedItems(next), saved = savedMeals
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date()), now = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let had = logged.map { "\(str($0["name"])) (\(Int(num($0["kcal"]) ?? 0)) kcal)" }.joined(separator: ", ")
        let room = max(0, budget(next) - logged.reduce(0) { $0 + (num($1["kcal"]) ?? 0) })
        let protein = store.proteinGoal.map { max(0, $0 - store.macros(logged).p) }
        let prefs = dict(store.doc["prefs"])
        let avoid = (prefs["avoid"] as? [String] ?? []).joined(separator: ", ")
        let loves = (prefs["loves"] as? [String] ?? []).joined(separator: ", ")
        let meals = list(store.doc["meals"]).prefix(40).map { store.mealBasis($0) }.map { "\(str($0["name"])): \(Int(num($0["kcalPerServing"]) ?? 0)) kcal, \(Int(num($0["pServ"]) ?? 0)) g protein" }.joined(separator: "; ")
        let usual = store.mealHistory("Dinner").prefix(8).map(\.name).joined(separator: ", ")
        let earlier = list(plan?["chat"]).suffix(8).map { "They said: \(str($0["me"]))" }.joined(separator: "\n")
        let current = plan.map { list($0["slots"]).map { "\(str($0["time"])) \(str($0["title"])) (\(Int(num($0["kcal"]) ?? 0)) kcal, \(Int(num($0["protein"]) ?? 0)) g protein)" }.joined(separator: "\n") } ?? ""
        let schema: JSON = ["type": "object", "properties": [
            "title": ["type": "string", "description": "A short title for the plan, from what's in it"] as JSON,
            "reply": ["type": "string", "description": "Under 20 words, friendly: what you did or changed"] as JSON,
            "slots": ["type": "array", "items": ["type": "object", "properties": [
                "time": ["type": "string", "description": "24-hour time like 15:30"] as JSON,
                "title": ["type": "string"] as JSON,
                "detail": ["type": "string", "description": "Under 12 words: what's in it. Empty for a saved meal"] as JSON,
                "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON, "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON,
                "workout": ["type": "boolean"] as JSON,
                "saved": ["type": "string", "description": "The exact name of the saved meal this is, or empty"] as JSON
            ] as JSON, "required": ["time", "title", "detail", "kcal", "protein", "carbs", "fat", "workout", "saved"]] as JSON] as JSON
        ] as JSON, "required": ["title", "reply", "slots"]]
        let prompt = """
        You're planning a cheat day together with someone in \(Plan.country). It should feel like a treat, not a diet.
        \(isToday ? "It's \(now) today: every slot's time is after \(now)." : "The day is \(when(next.date)).")
        \(had.isEmpty ? "" : "Already logged today, never list these: \(had).")
        About \(Int(room)) kcal are available for the slots.\(protein.map { " Protein still to reach today: \(Int($0)) g." } ?? "")
        Their saved meals, newest first, with their real numbers: \(meals.isEmpty ? "none" : meals). If they mean one of these ("my brownie"), use it, the newest that fits, set saved to its exact name and use exactly those numbers. Something added to a saved meal (a frosting) is its own slot, and the saved meal stays as it is.
        Foods they love: \(loves.isEmpty ? "not said" : loves). Never include: \(avoid.isEmpty ? "nothing" : avoid). What they often have for dinner: \(usual.isEmpty ? "not known" : usual).
        \(current.isEmpty ? "" : "The plan so far:\n\(current)\nKeep every slot exactly as it is unless they ask to change it, or a change they asked for can't work without it, and if so say so in reply.")
        \(earlier.isEmpty ? "" : "What they've said so far:\n\(earlier)")
        They now say: "\(said)"
        Rules. Plan ONLY what they asked for. Never fill the day or use up the calories unless they ask: unused calories are theirs to enjoy, and the app shows them. If they ask to leave an amount free, make the slots leave about that much. If they ask to reach their protein, reach it with what they asked for plus as little as possible, and say what you added. Only add a workout if they ask (workout true, kcal 0). If they ask for ideas, add them as slots. Name real dishes and orders. Numbers come from standard reference values, never raised to fit. Never suggest skipping meals or making up for it tomorrow.
        """
        do {
            var a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: false, tries: 4)
            a["slots"] = CheatPlan.tidied(CheatPlan.keepingRecipes(list(a["slots"]), from: list(plan?["slots"])), saved: saved)
            a["at"] = ISO.now()
            a["chat"] = Array(list(plan?["chat"]).suffix(11)) + [["me": said] as JSON]
            store.perform(["type": "cheatPlan", "date": next.date, "plan": a])
            starting = false
        } catch {
            problem = error.localizedDescription
            draft = said   // nothing lost: it's back in the box to try again
        }
    }

    // MARK: no cheat day yet

    private var setup: some View {
        let base = store.baseBudget(store.today)
        let cheat = Plan.r10(base * setupSize), everyday = Plan.r10((base * 7 - Double(cheat)) / 6)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pick a cheat day").font(.largeTitle.bold()).padding(.top, 10)
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

/// The status line while the planner works: a pulsing spark and what it's up to.
struct CheatPlanStatus: View {
    private static let steps = ["Reading your day", "Checking your saved meals", "Working out the numbers", "Tidying it up"]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.2)) { t in
            let i = Int(t.date.timeIntervalSinceReferenceDate / 2.2) % Self.steps.count
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent).symbolEffect(.pulse, options: .repeating)
                Text(Self.steps[i] + "…").font(.subheadline).foregroundStyle(.secondary).contentTransition(.opacity).animation(.easeInOut, value: i)
            }
        }
        .accessibilityLabel("Planning")
    }
}

/// The first plan on its way: the shape of it, shimmering.
struct CheatPlanLoading: View {
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var sweep = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CheatPlanStatus().padding(.bottom, 6)
            bar(width: 210, height: 24).padding(.bottom, 4)
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 12) {
                    bar(width: 38, height: 12)
                    VStack(alignment: .leading, spacing: 7) { bar(width: 180, height: 14); bar(width: 110, height: 11) }
                    Spacer()
                    Circle().fill(Theme.track).frame(width: 26, height: 26)
                }
                .padding(14).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.horizontal, 20).padding(.top, 14)
        .overlay {
            GeometryReader { g in
                LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.6)
                    .offset(x: sweep ? g.size.width : -g.size.width * 0.6)
            }
            .allowsHitTesting(false)
            .opacity(still ? 0 : 1)
        }
        .clipped()
        .onAppear { if !still { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { sweep = true } } }
    }
    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2.5, style: .continuous).fill(Theme.track).frame(width: width, height: height)
    }
}
