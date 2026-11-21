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

    /// Each dish's parts checked against the food tables, as the assistant's cards are, and the dish's numbers their
    /// sum. A dish's number was the AI's one guess, never checked; asked for its parts (tried live, 16 Nov), a sushi
    /// train came to 1,174 listed plate by plate where the guess was 850. A part the tables can't place, or would place
    /// far from the AI's number (battered wings as baked lean wing), keeps the AI's numbers: ground's own guards. A
    /// saved meal or a workout keeps its own.
    @MainActor static func checked(_ slots: [JSON]) async -> [JSON] {
        var out: [JSON] = []
        for s in slots {
            let raw = list(s["parts"]).filter { (num($0["grams"]) ?? 0) > 0 }
            guard !raw.isEmpty, str(s["saved"]).isEmpty, s["workout"] as? Bool != true else { out.append(s); continue }
            let parts = raw.map { p -> JSON in
                ["name": str(p["name"]), "grams": num(p["grams"]) ?? 0, "kcal": num(p["kcal"]) ?? 0, "protein_g": num(p["protein"]) ?? 0,
                 "carbs_g": num(p["carbs"]) ?? 0, "fat_g": num(p["fat"]) ?? 0, "numbers_from": "estimate"]
            }
            let got = list(await Assistant.ground(["name": str(s["title"]), "parts": parts])["parts"])
            guard !got.isEmpty else { out.append(s); continue }
            func sum(_ k: String) -> Double { got.reduce(0) { $0 + (num($1[k]) ?? 0) } }
            var x = s
            x["kcal"] = sum("kcal").rounded(); x["protein"] = sum("protein_g").rounded()
            x["carbs"] = sum("carbs_g").rounded(); x["fat"] = sum("fat_g").rounded()
            x["parts"] = got.map { p -> JSON in
                ["name": str(p["name"]), "grams": num(p["grams"]) ?? 0, "kcal": num(p["kcal"]) ?? 0, "protein": num(p["protein_g"]) ?? 0,
                 "carbs": num(p["carbs_g"]) ?? 0, "fat": num(p["fat_g"]) ?? 0, "src": str(p["src"]), "match": str(p["match"])]
            }
            out.append(x)
        }
        return out
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

    /// A takeaway order (the takeaway planner's card, design/cheat-day-planner-mockup.html) as a slot: the place, its
    /// dishes and how much of each, its numbers (a range when they're guessed), its tips. "place" marks it, so the
    /// planner's rewrites leave it as the menu made it.
    static func slot(_ c: JSON, place: String, tips: [String], time: String) -> JSON {
        let lines = list(c["lines"])
        func sum(_ l: JSON, _ k: String) -> Double { list(l["add"]).reduce(0) { $0 + (num($1[k]) ?? 0) } }
        let parts = lines.map { l -> JSON in
            var p: JSON = ["name": str(l["name"]), "grams": 0, "kcal": num(l["kcal"]) ?? 0, "protein": num(l["p"]) ?? 0, "carbs": sum(l, "c"), "fat": sum(l, "f"), "tag": str(l["tag"])]
            if l["dish"] as? Bool == true { p["share"] = num(l["share"]) ?? 1 }
            return p
        }
        let detail = parts.map { p -> String in let sh = num(p["share"]) ?? 1; return (sh < 0.99 ? "\(Takeaway.frac(sh)) " : "") + str(p["name"]) }.joined(separator: "\n")
        var s: JSON = ["time": time, "title": place, "place": place, "workout": false, "saved": "", "parts": parts, "tips": tips, "source": str(c["source"]),
                       "detail": detail, "kcal": num(c["kcal"]) ?? 0, "protein": num(c["p"]) ?? 0, "carbs": num(c["c"]) ?? 0, "fat": num(c["f"]) ?? 0]
        for k in ["kcalLo", "kcalHi", "pLo", "pHi"] { if let v = num(c[k]) { s[k] = v } }
        return s
    }

    /// A place's slot stays as its menu made it when the planner rewrites the day (it's told to keep slots as they are,
    /// but it would write its own numbers over the menu's): the planner's time for it is kept.
    static func keepingPlaces(_ new: [JSON], from old: [JSON]) -> [JSON] {
        new.map { s -> JSON in
            guard let was = old.first(where: { $0["place"] != nil && str($0["title"]).lowercased() == str(s["title"]).lowercased() }) else { return s }
            var x = was
            if !str(s["time"]).isEmpty { x["time"] = s["time"] }
            return x
        }
        .sorted { str($0["time"]) < str($1["time"]) }
    }

    /// A slot as an idea, for the recipe screen and for logging.
    static func idea(_ slot: JSON) -> JSON {
        var i: JSON = ["name": str(slot["title"]), "kcal": num(slot["kcal"]) ?? 0, "protein": num(slot["protein"]) ?? 0, "carbs": num(slot["carbs"]) ?? 0,
                       "fat": num(slot["fat"]) ?? 0, "why": str(slot["detail"]), "meal": meal(of: slot), "saved": str(slot["saved"]), "treat": true]
        if let r = slot["recipe"] { i["recipe"] = r }
        return i
    }
}

/// Plan your cheat day as a conversation: say what you're after, get only that with what's left to enjoy, then keep
/// talking to change it.
struct CheatDayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var speech = Speech()
    @State private var starting = false
    @State private var busy = false
    @State private var sent: String?   // what you just asked, on screen while the answer comes
    @State private var problem: String?
    @State private var open: IdeaRef?
    @State private var setupDay = 6
    @State private var setupSize = 1.3
    @FocusState private var typing: Bool
    @State private var showEaten = false   // the day's food so far, opened from its one line
    @State private var macroFor: SlotBox?   // a slot's numbers, ready to log (design/cheat-day-planner-mockup.html)
    struct SlotBox: Identifiable { let id = UUID(); let slot: JSON }
    /// The cheat day's own colours, the beta pass's blue to lavender (#8ec5ff to #c4a1ff): the day's name, what's
    /// free to enjoy, the day picked. The owner wasn't a fan of the yellow.
    static let tint = Color(red: 0.769, green: 0.631, blue: 1.0)
    static let tintGradient = LinearGradient(colors: [Color(red: 0.557, green: 0.773, blue: 1.0), tint], startPoint: .leading, endPoint: .trailing)
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
            // the app's own keyboard room, like the assistant's: in this sheet SwiftUI only lifted the chat box over the
            // keyboard once something was typed, so at first it sat hidden behind it
            .keyboardLift()
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
            .sheet(item: $macroFor) { b in macroSheet(b.slot) }
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
                Eyebrow(text: when(next.date), color: Self.tint).padding(.top, 8)
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
                    Eyebrow(text: when(next.date), color: Self.tint).padding(.top, 8)
                    Text(str(plan["title"])).font(.title2.bold()).padding(.bottom, 2)
                    VStack(spacing: 8) {
                        // what's eaten already, folded into one line (a row each took most of the screen); tap to see them
                        if extras.count > 1 {
                            eatenRow(extras)
                            if showEaten { ForEach(extras.indices, id: \.self) { i in loggedRow(extras[i]) } }
                        } else { ForEach(extras.indices, id: \.self) { i in loggedRow(extras[i]) } }
                        ForEach(slots.indices, id: \.self) { i in slotRow(slots[i], isToday: next.date == store.today) }
                    }
                    .opacity(busy ? 0.45 : 1)
                    .animation(.snappy, value: str(plan["at"]))
                    let options = list(plan["options"])
                    if !options.isEmpty && !busy {
                        // for something open ("thinking more Chinese"): more to pick from, not counted until added
                        Text("More to choose from").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        VStack(spacing: 8) { ForEach(options.indices, id: \.self) { i in optionRow(options[i]) } }
                    }
                    freeCard(room)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).padding(.top, 4) }
                    Button("Start again") { draft = ""; problem = nil; starting = true }
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 12).id("end")
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .simultaneousGesture(TapGesture().onEnded {   // tap away to put the keyboard down; straight to UIKit too, the focus flag can be stale
                typing = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
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

    private func optionRow(_ o: JSON) -> some View {
        HStack(spacing: 12) {
            Button { open = IdeaRef(id: str(o["title"]), idea: CheatPlan.idea(o)) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(str(o["title"])).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                    if !str(o["detail"]).isEmpty { Text(str(o["detail"])).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                    Text("est. \(Fmt.int(num(o["kcal"]) ?? 0)) kcal · \(Int((num(o["protein"]) ?? 0).rounded())) g protein").font(.caption.weight(.semibold)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { withAnimation(.snappy) { choose(o) } } label: {
                Label("Add", systemImage: "plus").font(.caption.weight(.heavy)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 11).padding(.vertical, 7).background(Theme.accent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain).accessibilityLabel("Add \(str(o["title"])) to the plan")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 11)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    /// A choice into the plan, after the last thing in it; the others stay to choose from.
    private func choose(_ o: JSON) {
        guard let date = store.nextCheat?.date, var plan = store.cheatPlan(date) else { return }
        var slots = list(plan["slots"]), x = o
        var dropped: JSON?
        if !str(o["place"]).isEmpty, let k = slots.firstIndex(where: { str($0["place"]).lowercased() == str(o["place"]).lowercased() }) {
            // another order from the same place: in its slot's place, the one it replaces back among the options
            x["time"] = slots[k]["time"]; dropped = slots.remove(at: k)
        } else {
            // 15 minutes after the last thing in the plan ("19:30" then "19:45"), never past midnight
            let hm = (slots.last.map { str($0["time"]) } ?? "").split(separator: ":").compactMap { Int($0) }
            if hm.count == 2 { let t = min(hm[0] * 60 + hm[1] + 15, 23 * 60 + 59); x["time"] = String(format: "%02d:%02d", t / 60, t % 60) }
        }
        slots.append(x)
        plan["slots"] = slots.sorted { str($0["time"]) < str($1["time"]) }
        // (a place's orders share its name: told apart by what's in them)
        plan["options"] = list(plan["options"]).filter { !(str($0["title"]) == str(o["title"]) && str($0["detail"]) == str(o["detail"])) } + (dropped.map { [$0] } ?? [])
        store.perform(["type": "cheatPlan", "date": date, "plan": plan])
    }

    private func eatenRow(_ items: [JSON]) -> some View {
        let kcal = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return Button { withAnimation(.snappy) { showEaten.toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.walk)
                Text("Eaten so far").font(.subheadline.weight(.semibold))
                Text("· \(items.count) foods").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.int(kcal)) kcal").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: showEaten ? "chevron.up" : "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
            .background(Theme.hero.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Eaten so far, \(items.count) foods, \(Fmt.int(kcal)) kcal. \(showEaten ? "Hide" : "Show") them")
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
        // the planner's guess until its recipe is written; a saved meal and anything logged are real numbers
        let est = !done && s["recipe"] == nil && str(s["saved"]).isEmpty ? "est. " : ""
        let place = s["place"] != nil, tips = (s["tips"] as? [String] ?? []).prefix(2)
        return HStack(spacing: 12) {
            // a place's order: its numbers to log, with how much of each dish; anything else: its recipe
            Button { if place { macroFor = SlotBox(slot: s) } else if !isWorkout { open = IdeaRef(id: title, idea: CheatPlan.idea(s)) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(str(s["time"])).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        if !str(s["detail"]).isEmpty { Text(str(s["detail"])).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                        if kcal > 0 || done {
                            ((done ? Text("✓ Logged · ").foregroundStyle(Theme.walk) : Text(""))
                                + Text(slotNumbers(s, done: done, kcal: kcal, protein: protein, est: est)))
                                .font(.caption.weight(.semibold)).monospacedDigit().padding(.top, 1)
                        }
                        if !done { ForEach(tips.indices, id: \.self) { i in Text("• " + tips[i]).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading) } }
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
                if !place && !isWorkout { Button { open = IdeaRef(id: title, idea: CheatPlan.idea(s)) } label: { Label("See the recipe", systemImage: "book") } }
                if !isWorkout && !list(s["parts"]).isEmpty { Button { macroFor = SlotBox(slot: s) } label: { Label("Macros and how much", systemImage: "chart.bar.doc.horizontal") } }
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

    /// A slot's numbers: a range when they're guessed ("est. 1,250–1,400 kcal · 70–80 g protein"), as the PUBCHA chat gave them.
    private func slotNumbers(_ s: JSON, done: Bool, kcal: Double, protein: Double, est: String) -> String {
        if !done, let lo = num(s["kcalLo"]), let hi = num(s["kcalHi"]), let pl = num(s["pLo"]), let ph = num(s["pHi"]) {
            return "est. \(Fmt.int(lo))–\(Fmt.int(hi)) kcal · \(Int(pl))–\(Int(ph)) g protein"
        }
        return "\(est)\(Fmt.int(kcal)) kcal · \(est)\(Int(protein.rounded())) g protein"
    }

    /// A slot's numbers, ready to log: how much of each part, then logged or kept in the plan as set.
    private func macroSheet(_ s: JSON) -> some View {
        let today = store.nextCheat?.date == store.today
        return SlotMacros(slot: s, canLog: today && !CheatPlan.logged(s, in: store.todayItems),
                          log: { x in keepSlot(x, was: s); logSlot(x) }, keep: { x in keepSlot(x, was: s) })
    }

    /// A slot as it was set in its numbers sheet, in the plan where it was.
    private func keepSlot(_ x: JSON, was: JSON) {
        guard let date = store.nextCheat?.date, var plan = store.cheatPlan(date) else { return }
        plan["slots"] = list(plan["slots"]).map { str($0["title"]) == str(was["title"]) && str($0["time"]) == str(was["time"]) ? x : $0 }
        store.perform(["type": "cheatPlan", "date": date, "plan": plan])
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
                Text(room > 0 ? "\(Fmt.int(room)) kcal free to enjoy" : "\(Fmt.int(-room)) kcal over").font(.headline).monospacedDigit().foregroundStyle(Self.tintGradient)
                Text(room > 0 ? "Snacks, a drink, whatever you fancy." : "Ask to trim something if you'd like.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Self.tintGradient.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
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
            // the assistant's box: the words on top (up to about 8 lines), the microphone and send along the bottom
            VStack(alignment: .leading, spacing: 10) {
                TextField("Change anything…", text: $draft, axis: .vertical).lineLimit(1...8).focused($typing)
                    .padding(.horizontal, 8).padding(.top, 4)
                HStack(spacing: 8) {
                    if speech.listening {
                        SpeechBars(level: speech.level).frame(maxWidth: .infinity)
                        Button { speech.stop() } label: {
                            RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 13, height: 13).frame(width: 40, height: 40).background(Color.red, in: Circle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Stop listening")
                    } else {
                        Spacer()
                        Button {
                            let before = draft.trimmingCharacters(in: .whitespaces)
                            Task { await speech.start { words in draft = before.isEmpty ? words : before + " " + words } }
                        } label: {
                            Image(systemName: "mic").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                                .frame(width: 40, height: 40).background(Color.white.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Speak")
                        Button { typing = false; speech.cancel(); Task { await send(next: next, plan: plan) } } label: {
                            Group {
                                if busy { ProgressView().tint(Theme.onAccent) }
                                else { Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onAccent) }
                            }
                            .frame(width: 40, height: 40).background(Theme.accent.opacity(empty && !busy ? 0.4 : 1), in: Circle())
                        }
                        .buttonStyle(.plain).disabled(empty || busy).accessibilityLabel("Send")
                    }
                }
            }
            .padding(10)
            .background { Color.clear.contentShape(Rectangle()).onTapGesture { typing = true } }
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(alignment: .top) {
                if let p = speech.problem { Text(p).font(.caption).foregroundStyle(Theme.warn).padding(8).offset(y: -34) }
            }
            .padding(.horizontal, 20)
            .onDisappear { speech.cancel() }
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
        // a place named ("PUBCHA for dinner"): planned from its real menu by the takeaway planner, as one slot with how
        // much of each dish, its range and its tips (the PUBCHA chat the owner shared, 21 Nov); anything else, as before
        if let made = await fromPlace(said, next: next, plan: plan) {
            store.perform(["type": "cheatPlan", "date": next.date, "plan": made]); starting = false; return
        }
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
        let part: JSON = ["type": "object", "properties": [
            "name": ["type": "string", "description": "a plain food name as a food table has it, e.g. \"Chicken thigh, fried\", \"Bread roll, white\""] as JSON,
            "grams": ["type": "number", "description": "as eaten (cooked weight)"] as JSON,
            "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON, "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON
        ] as JSON, "required": ["name", "grams", "kcal", "protein", "carbs", "fat"]]
        let slot: JSON = ["type": "object", "properties": [
            "time": ["type": "string", "description": "24-hour time like 15:30"] as JSON,
            "title": ["type": "string"] as JSON,
            "detail": ["type": "string", "description": "Under 12 words: what's in it. Empty for a saved meal"] as JSON,
            "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON, "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON,
            "workout": ["type": "boolean"] as JSON,
            "saved": ["type": "string", "description": "The exact name of the saved meal this is, or empty"] as JSON,
            // its parts, to check against the food tables (CheatPlan.checked); as tried live in tools/ai-test/cheat-check.js
            "parts": ["type": "array", "items": part, "description": "The dish's main parts as eaten, each with its grams and its own numbers; the slot's numbers are these added up. Empty for a saved meal or a workout"] as JSON
        ] as JSON, "required": ["time", "title", "detail", "kcal", "protein", "carbs", "fat", "workout", "saved", "parts"]]
        let schema: JSON = ["type": "object", "properties": [
            "title": ["type": "string", "description": "A short title for the plan, from what's in it"] as JSON,
            "reply": ["type": "string", "description": "Under 20 words, friendly: what you did or changed"] as JSON,
            "slots": ["type": "array", "items": slot] as JSON,
            "options": ["type": "array", "items": slot, "description": "For an open request: 3 more dishes to choose from, not in the plan. Empty when they named what they want"] as JSON
        ] as JSON, "required": ["title", "reply", "slots", "options"]]
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
        Rules. Plan ONLY what they asked for. Never fill the day or use up the calories unless they ask: unused calories are theirs to enjoy, and the app shows them. If they ask to leave an amount free, make the slots leave about that much. If they ask to reach their protein, or for an amount of it, reach it with what they asked for plus as few real dishes as it takes, and say what you added. It's a cheat day: the protein comes the tasty way, from proper dishes that are rich in it (a steak, a burger, fried chicken, a kebab, Korean BBQ, a loaded burrito), never protein shakes, powder or bars unless they ask for those by name, and never the same dish twice. If that goes over the calories available, that's fine; say so. Only add a workout if they ask (workout true, kcal 0). If they ask for something open rather than naming dishes (a cuisine, a mood, "something sweet", "ideas"), put your one best pick in slots and 3 more real dishes of that kind in options for them to choose from; they aren't in the plan until they add one. When they name what they want, options is empty. Name real dishes and orders. Numbers come from standard reference values, never raised to fit. Never suggest skipping meals or making up for it tomorrow.
        \(Assistant.foodData(said))
        """
        do {
            var a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: false, tries: 4, job: "chat")
            let slots = await CheatPlan.checked(list(a["slots"]))
            a["slots"] = CheatPlan.keepingPlaces(CheatPlan.tidied(CheatPlan.keepingRecipes(slots, from: list(plan?["slots"])), saved: saved), from: list(plan?["slots"]))
            let inPlan = Set(list(a["slots"]).map { str($0["title"]).lowercased() })
            a["options"] = CheatPlan.tidied(await CheatPlan.checked(list(a["options"]).filter { !inPlan.contains(str($0["title"]).lowercased()) }), saved: saved)
            a["at"] = ISO.now()
            a["chat"] = Array(list(plan?["chat"]).suffix(11)) + [["me": said] as JSON]
            store.perform(["type": "cheatPlan", "date": next.date, "plan": a])
            starting = false
        } catch {
            problem = error.localizedDescription
            draft = said   // nothing lost: it's back in the box to try again
        }
    }

    /// The takeaway planner's answer when the message is about a place (nil when it isn't, or it couldn't plan it): the
    /// place's slot made from its best order, its other orders as options to swap in, the chat so far going along so
    /// "any other options?" and "what about the seafood pancake?" work as they do in the assistant.
    private func fromPlace(_ said: String, next: (date: String, kcal: Double, extra: Double), plan: JSON?) async -> JSON? {
        var turns: [Assistant.Turn] = []
        for e in list(plan?["chat"]).suffix(8) {
            if !str(e["me"]).isEmpty { turns.append(Assistant.Turn(me: true, text: str(e["me"]))) }
            if let ta = e["ta"] as? JSON { turns.append(Assistant.Turn(me: false, text: "", result: ["takeaway": ta])) }
        }
        turns.append(Assistant.Turn(me: true, text: said))
        let logged = loggedItems(next), slots = list(plan?["slots"])
        // what's free for it: the day, less what's eaten and the rest of the plan (a place's slot is what's being changed)
        let rest = slots.filter { $0["place"] == nil && !CheatPlan.logged($0, in: logged) }
        let room = max(0, budget(next) - CheatPlan.total(slots: rest, logged: logged))
        let pLeft = store.proteinGoal.map { g in max(0, g - store.macros(logged).p - rest.reduce(0.0) { $0 + (num($1["protein"]) ?? 0) }) }
        guard let r = await Takeaway.answer(turns, store: store, step: nil, room: room, proteinLeft: pLeft), str(r["kind"]) == "takeaway",
              let ta = r["takeaway"] as? JSON, let best = list(ta["combos"]).first else { return nil }
        let place = str(ta["restaurant"]), tips = ta["tips"] as? [String] ?? []
        let was = slots.first { str($0["place"]).lowercased() == place.lowercased() }
        let time = str(was?["time"]).isEmpty ? Self.time(for: said, isToday: next.date == store.today) : str(was?["time"])
        var p = plan ?? [:]
        p["slots"] = (slots.filter { str($0["place"]).lowercased() != place.lowercased() } + [CheatPlan.slot(best, place: place, tips: tips, time: time)])
            .sorted { str($0["time"]) < str($1["time"]) }
        p["options"] = list(ta["combos"]).dropFirst().map { CheatPlan.slot($0, place: place, tips: tips, time: time) }
        p["reply"] = str(r["reply"])
        if str(p["title"]).isEmpty { p["title"] = "Cheat day: \(place)" }
        p["at"] = ISO.now()
        // the orders shown, kept small, for the next message's context (what's been suggested, what not to show again)
        var small = ta
        small["combos"] = list(ta["combos"]).map { c -> JSON in
            ["title": str(c["title"]), "key": str(c["key"]), "lines": list(c["lines"]).map { l -> JSON in ["name": str(l["name"]), "dish": l["dish"] as? Bool ?? false] }]
        }
        p["chat"] = Array(list(plan?["chat"]).suffix(11)) + [["me": said, "ta": small] as JSON]
        return p
    }

    /// When a place's order goes in the day: the meal they name, else dinner; today, never before now.
    static func time(for said: String, isToday: Bool) -> String {
        let meal = Meals.named(in: said) ?? "Dinner"
        var m = ["Breakfast": 9 * 60, "Lunch": 12 * 60 + 30, "Snacks": 15 * 60 + 30, "Dinner": 19 * 60][meal] ?? 19 * 60
        if isToday {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date()), now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if m <= now { m = min(23 * 60 + 30, ((now + 44) / 15) * 15) }
        }
        return String(format: "%02d:%02d", m / 60, m % 60)
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
                            .background(setupDay == d ? AnyShapeStyle(Self.tintGradient) : AnyShapeStyle(Color(.tertiarySystemFill)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(setupDay == d ? Theme.onAccent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            label("How big?")
            Picker("Size", selection: $setupSize) { Text("A bit more").tag(1.3); Text("Lots more").tag(1.5); Text("Go big").tag(1.7) }.pickerStyle(.segmented)
            VStack(spacing: 10) {
                HStack { Text(Calendar.current.weekdaySymbols[setupDay]).foregroundStyle(.secondary); Spacer(); Text("\(Fmt.int(Double(cheat))) kcal").font(.title3.weight(.heavy)).foregroundStyle(Self.tintGradient) }
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
