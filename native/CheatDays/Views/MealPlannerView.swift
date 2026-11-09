import SwiftUI

extension Store {
    /// A fair size for one meal: what's left today, shared across the meals still to come (snacks always keep a
    /// little), so a lunch idea leaves room for dinner. Never more than about a third over that meal's usual share.
    func mealTarget(_ meal: String) -> (kcal: Double, protein: Double?) {
        let share = ["Breakfast": 0.25, "Lunch": 0.30, "Dinner": 0.35, "Snacks": 0.10]
        let at = Meals.all.firstIndex(of: meal) ?? 0
        let upcoming = Meals.all.enumerated().filter { i, m in
            i >= at && (m == meal || m == "Snacks" || !todayItems.contains { Meals.of($0) == m })
        }.map(\.element)
        let part = (share[meal] ?? 0.3) / max(0.1, upcoming.reduce(0) { $0 + (share[$1] ?? 0) })
        let left = max(0, budgetToday - eaten)
        let kcal = min(left * part, budgetToday * (share[meal] ?? 0.3) * 1.3)
        let protein = proteinGoal.map { max(0, $0 - macros(todayItems).p) * part }
        return ((kcal / 10).rounded() * 10, protein.map { $0.rounded() })
    }

    /// What you've had at a meal over the last four weeks, most often first: the planner's sense of your style
    /// (Asian dinners, toast breakfasts) and the ingredients you already buy.
    func mealHistory(_ meal: String, days: Int = 28) -> [(name: String, days: Int, kcal: Double)] {
        let since = DayKey.shift(today, days: -days)
        let all: [(String, [JSON])] = [(today, todayItems)] + list(doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < today }.map { (str($0["date"]), list($0["items"])) }
        var seen: [String: (name: String, days: Set<String>, kcal: Double)] = [:]
        for (date, items) in all {
            for it in items where Meals.of(it) == meal {
                let n = str(it["name"]).trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { continue }
                var e = seen[n.lowercased(), default: (n, [], 0)]
                e.days.insert(date); e.kcal = max(e.kcal, num(it["kcal"]) ?? 0)
                seen[n.lowercased()] = e
            }
        }
        return seen.values.sorted { ($0.days.count, $1.name) > ($1.days.count, $0.name) }.map { ($0.name, $0.days.count, $0.kcal) }
    }
}

/// The Plan button on a normal day, as a chat: it says what the meal should come to and how to ask (with your own
/// numbers, and how much cooking), you say what you fancy, and ideas in your usual style come back as cards
/// to log or cook. Reply to change them ("something spicier", "no rice"); the earlier ones stay above.
struct MealPlannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var meal: String
    /// The meal it's time for (dinner rather than snacks), or the one a reminder asked to plan.
    init(meal: String? = nil) {
        let now = Meals.byTime(Calendar.current.component(.hour, from: Date()))
        _meal = State(initialValue: meal ?? (now == "Snacks" ? "Dinner" : now))
    }
    /// One message: theirs, or the planner's with its ideas.
    struct Turn: Identifiable { let id = UUID(); let me: Bool; var text: String; var ideas: [JSON] = [] }
    @State private var turns: [Turn] = []
    @State private var text = ""
    @State private var cooking = ""
    @AppStorage("pantry.scans") private var scansJSON = "[]"   // foods scanned in, with their label numbers
    @State private var scanning: PantryScanSheet.Mode?
    @State private var busy = false
    @State private var stepsDone: [String] = []
    @State private var stepNow = ""
    @State private var problem: String?
    @State private var added: Set<String> = []
    @State private var open: IdeaRef?
    @State private var cheat = false
    @State private var speech = Speech()
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }

    private static let cookChoices = ["No cooking", "Quick, 15 min", "Happy to cook"]
    private var left: Double { max(0, store.budgetToday - store.eaten) }
    private var history: [(name: String, days: Int, kcal: Double)] { store.mealHistory(meal) }
    /// This meal's share of the protein goal, to the nearest 5 g (25 g without a goal).
    private var proteinShare: Double { ((store.mealTarget(meal).protein ?? 25) / 5).rounded() * 5 }
    /// How to ask, kept simple (a list of their own foods read oddly, "white sandwich, kewpie light mayo…"): the meal's
    /// numbers are above it and the cooking time is its own button. "Something high protein, Chinese style."
    private var example: String {
        let style = (store.habits["cuisines"] as? [String])?.first.map { ", \($0) style" } ?? ""
        return "Something high protein\(style)."
    }

    /// The examples the intro fades between: a recipe, and places near them. No restaurant named.
    private var examples: [String] { [example, "Any healthy \(meal.lowercased()) spots near me?"] }
    @State private var exampleAt = 0
    /// A takeaway or places question sent here: the Assistant answers it, where its cards live.
    struct Asking: Identifiable { let id = UUID(); let q: String }
    @State private var asking: Asking?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                ForEach(["Breakfast", "Lunch", "Dinner"], id: \.self) { m in Chip(text: m, on: meal == m) { meal = m } }
                            }
                            intro
                            ForEach(turns) { t in turnView(t).id(t.id) }
                            if busy { progress.id("busy") }
                            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
                            Button { cheat = true } label: { Label("Plan your cheat day instead", systemImage: "arrow.right").font(.subheadline.weight(.semibold)) }
                                .frame(maxWidth: .infinity).padding(.top, 6)
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo(turns.last?.id, anchor: .top) } }
                    .onChange(of: busy) { _, b in if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
                    composer
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Plan a meal").navigationBarTitleDisplayMode(.inline)
            .keyboardDone()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            // a chat box: no Done bar (the send button's right there); the sheets it opens keep theirs (a recipe's number pads)
            .sheet(item: $open, onDismiss: { KeyboardDone.quiet = true }) { r in RecipeSheet(idea: r.idea) }
            .sheet(item: $scanning, onDismiss: { KeyboardDone.quiet = true }) { m in
                PantryScanSheet(mode: m) { items in
                    // newest first; scanning the same food again replaces the old one
                    let names = Set(items.map { $0.name.lowercased() })
                    withAnimation { scansJSON = PantryItem.Saved.save(items + scans.filter { !names.contains($0.name.lowercased()) }) }
                }
            }
            .sheet(isPresented: $cheat, onDismiss: { KeyboardDone.quiet = true }) { CheatDayView().presentationDragIndicator(.visible) }
            .sheet(item: $asking, onDismiss: { KeyboardDone.quiet = true }) { a in AssistantView(meal: meal, firstQuestion: a.q) }
            .onChange(of: open == nil && scanning == nil) { _, none in if !none { KeyboardDone.quiet = false } }
            .onChange(of: meal) { _, _ in turns = []; problem = nil }
            .onAppear {
                KeyboardDone.quiet = true
                if cooking.isEmpty {
                    switch str(store.habits["cook"]) { case "love": cooking = Self.cookChoices[2]; case "hate": cooking = Self.cookChoices[0]; default: cooking = Self.cookChoices[1] }
                }
            }
            .onDisappear { speech.stop(); KeyboardDone.quiet = false }
        }
    }

    private var scans: [PantryItem] { PantryItem.Saved.load(scansJSON) }

    private func bubble<C: View>(_ content: C) -> some View {
        content.font(.subheadline).padding(12)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The planner's first message: what the meal should come to, and how to ask (a tap puts the example in the box).
    @ViewBuilder private var intro: some View {
        let t = store.mealTarget(meal)
        bubble(VStack(alignment: .leading, spacing: 8) {
            (Text("\(meal): about \(Fmt.int(t.kcal)) kcal and \(Int(proteinShare)) g protein").bold() + Text(" (\(Fmt.int(left)) left today). What do you fancy?"))
            Text("Try:").foregroundStyle(.secondary)
            // one at a time, fading to the next every 4 seconds; all laid out at once so the box keeps the tallest one's
            // height. A Use button, not dots: dots looked like a swipe, and a tap put it in the box instead
            let all = examples, at = exampleAt % all.count
            Button { text = all[at]; typing = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        ForEach(all.indices, id: \.self) { i in
                            Text("“\(all[i])”").italic().multilineTextAlignment(.leading).foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .opacity(i == at ? 1 : 0).accessibilityHidden(i != at)
                        }
                    }
                    Text("Use").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9).padding(.vertical, 4).background(Theme.accent.opacity(0.16), in: Capsule())
                }
                .padding(10)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
            }
            .buttonStyle(.plain).accessibilityHint("Puts the example in the box")
            // how much cooking: one small button, its three choices in a menu
            Menu {
                Picker("Cooking", selection: $cooking) { ForEach(Self.cookChoices, id: \.self) { Text($0).tag($0) } }
            } label: {
                Label { Text(cooking) + Text(" ") + Text(Image(systemName: "chevron.down")).font(.caption2) } icon: { Image(systemName: "timer") }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Color(.tertiarySystemFill), in: Capsule())
            }
            .accessibilityLabel("Cooking: \(cooking)")
        })
        // they've started typing or asking: the example stays put (and still for the planner's UI test, which taps it)
        .task(id: meal) {
            guard !ProcessInfo.processInfo.arguments.contains("-uitest-plan") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if text.isEmpty && turns.isEmpty && !Task.isCancelled { withAnimation(.easeInOut(duration: 0.5)) { exampleAt += 1 } }
            }
        }
        // the foods scanned in, with their label numbers: the ideas use them
        if !scans.isEmpty {
            Flow {
                ForEach(scans) { s in
                    HStack(spacing: 6) {
                        Text("🏷 \(s.name)").font(.subheadline.weight(.semibold))
                        Button { withAnimation { scansJSON = PantryItem.Saved.save(scans.filter { $0.id != s.id }) } } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(s.name)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder private func turnView(_ t: Turn) -> some View {
        if t.me {
            Text(t.text).font(.subheadline).padding(12).foregroundStyle(Theme.onAccent)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            bubble(Text(t.text))
            ForEach(t.ideas.indices, id: \.self) { i in idea(t.ideas[i]) }
        }
    }

    /// What it's doing, ticked off as it goes, like the assistant.
    private var progress: some View {
        bubble(VStack(alignment: .leading, spacing: 7) {
            ForEach(stepsDone, id: \.self) { s in
                Label { Text(s).foregroundStyle(.secondary) } icon: { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green) }
            }
            Label { Text(stepNow).fontWeight(.semibold) } icon: { ProgressView().controlSize(.small) }
        }
        .animation(.snappy, value: stepsDone))
    }

    /// The assistant's box: the words on top, ＋ to scan a barcode or photograph a label, the microphone and send.
    private var composer: some View {
        let empty = text.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            TextField(turns.isEmpty ? "What do you fancy?" : "Reply to change them…", text: $text, axis: .vertical).lineLimit(1...8).focused($typing)
                .submitLabel(.send).onSubmit { send() }
                .padding(.horizontal, 8).padding(.top, 4)
            HStack(spacing: 8) {
                Menu {
                    Button { typing = false; scanning = .barcode } label: { Label("Scan a barcode", systemImage: "barcode.viewfinder") }
                    Button { typing = false; scanning = .photo } label: { Label("Photo of a label", systemImage: "camera") }
                } label: { round("plus") }
                .accessibilityLabel("Add a food you have")
                if speech.listening {
                    SpeechBars(level: speech.level).frame(maxWidth: .infinity)
                    Button { speech.stop() } label: {
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 13, height: 13).frame(width: 40, height: 40).background(Color.red, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Stop listening")
                } else {
                    Spacer()
                    Button {
                        let before = text.trimmingCharacters(in: .whitespaces)
                        Task { await speech.start { words in text = before.isEmpty ? words : before + " " + words } }
                    } label: { round("mic") }
                    .buttonStyle(.plain).accessibilityLabel("Speak")
                    Button { send() } label: {
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
        .composerGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))   // the assistant's box
        .overlay(alignment: .top) {
            if let p = speech.problem { Text(p).font(.caption).foregroundStyle(Theme.warn).padding(8).offset(y: -34) }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .composerBar()
    }

    private func round(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
            .frame(width: 40, height: 40).background(Color.white.opacity(0.1), in: Circle())
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        speech.stop(); typing = false
        let mine = Turn(me: true, text: t)
        turns.append(mine)
        text = ""
        let ideas = Task { await suggest(t) }
        // "Gami for lunch, what should I get?" or "any lunch spots near me?": asked alongside the ideas; the Assistant
        // answers it with its takeaway or places card, over this screen
        Task {
            guard let i = await Takeaway.intent(t), i == "choose" || i == "find", turns.last?.id == mine.id else { return }   // not once ideas are in
            ideas.cancel()
            withAnimation(.snappy) { turns.removeAll { $0.id == mine.id } }
            asking = Asking(q: t)
        }
    }

    private func idea(_ m: JSON) -> some View {
        let name = str(m["name"]), kcal = (num(m["kcal"]) ?? 0).rounded()
        return HStack(spacing: 12) {
            Button { open = IdeaRef(id: name, idea: m) } label: {
                HStack(spacing: 12) {
                    FoodDot(name: name, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        // the protein in green when it reaches what you asked for, red when it falls short; an estimate until its recipe is written
                        let p = num(m["protein"]) ?? 0, aim = num(m["aim"])
                        let hit = aim.map { p >= $0 - 0.5 }
                        let est = RecipeMaker.shared.recipe(for: m) == nil ? "est. " : ""
                        (Text("\(est)\(Fmt.int(kcal)) kcal · ")
                         + Text("\(est)\(Int(p.rounded())) g protein").fontWeight(hit == nil ? .regular : .bold)
                            .foregroundStyle(hit == true ? Theme.walk : hit == false ? Color(red: 1, green: 0.42, blue: 0.38) : Color.secondary)
                         + Text("\(num(m["minutes"]).map { " · \(Int($0)) min" } ?? "") · recipe"))
                            .font(.caption).foregroundStyle(.secondary)
                        if !str(m["why"]).isEmpty { Text(str(m["why"])).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                        if !str(m["uses"]).isEmpty { Text(str(m["uses"])).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                        if m["fromLabels"] as? Bool == true {
                            Text("FROM YOUR LABELS").font(.caption2.weight(.heavy)).foregroundStyle(Color(red: 0.36, green: 0.82, blue: 0.56))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(red: 0.36, green: 0.82, blue: 0.56).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                store.add(Assistant.basis(name: name, kcal: kcal, grams: nil, p: num(m["protein"]) ?? 0, c: num(m["carbs"]) ?? 0, f: num(m["fat"]) ?? 0), kcal: kcal, meal: meal)
                withAnimation { _ = added.insert(name) }
            } label: {
                Image(systemName: added.contains(name) ? "checkmark.circle.fill" : "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless).disabled(added.contains(name))
            .accessibilityLabel("Add \(name) to \(meal.lowercased())")
        }
        .padding(12)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The scanned foods' parts worked out from their labels (grams × the printed numbers), not the AI's sums, and the
    /// idea's totals added up from its ingredients; with the grams of each scanned food listed under the idea.
    static func withLabels(_ idea: JSON, _ scanned: [PantryItem]) -> JSON {
        let parts = list(idea["ingredients"])
        guard !parts.isEmpty else { return idea }
        var m = idea, k = 0.0, p = 0.0, c = 0.0, f = 0.0, used: [String] = [], checked: [JSON] = []
        for x in parts {
            let g = num(x["grams"]) ?? 0, i = Int(num(x["label"]) ?? 0)
            var y = x
            if i >= 1, i <= scanned.count, g > 0 {
                let s = scanned[i - 1]
                y["kcal"] = (s.kcal100 * g / 100).rounded(); y["protein"] = (s.p100 ?? 0) * g / 100; y["carbs"] = (s.c100 ?? 0) * g / 100; y["fat"] = (s.f100 ?? 0) * g / 100
                used.append("\(Fmt.int(g)) g \(s.name)")
            } else {
                // the same checks a recipe gets, so its card and its recipe show the same numbers
                let fixed = FoodReference.checked([["name": str(x["name"]), "amount": "", "grams": g, "kcal": num(x["kcal"]) ?? 0, "protein_g": num(x["protein"]) ?? 0, "carbs_g": num(x["carbs"]) ?? 0, "fat_g": num(x["fat"]) ?? 0]]).items[0]
                y["kcal"] = num(fixed["kcal"]) ?? 0; y["protein"] = num(fixed["protein_g"]) ?? 0; y["carbs"] = num(fixed["carbs_g"]) ?? 0; y["fat"] = num(fixed["fat_g"]) ?? 0
            }
            k += num(y["kcal"]) ?? 0; p += num(y["protein"]) ?? 0; c += num(y["carbs"]) ?? 0; f += num(y["fat"]) ?? 0
            checked.append(y)
        }
        guard k > 0 else { return idea }
        // corrected numbers can leave it short of the protein you asked for: a little more of its main protein food,
        // never more than a third extra, to the next 5 g. A scanned food stays as the AI portioned it
        if let aim = num(idea["aim"]), p < aim - 0.5,
           let i = checked.indices.filter({ (num(checked[$0]["label"]) ?? 0) == 0 && (num(checked[$0]["grams"]) ?? 0) > 0 }).max(by: { (num(checked[$0]["protein"]) ?? 0) < (num(checked[$1]["protein"]) ?? 0) }),
           let had = pos(checked[i]["protein"]), let g = pos(checked[i]["grams"]) {
            let wanted = g * min((had + aim - p) / had, 4.0 / 3), grams = (wanted / 5).rounded(.up) * 5, more = grams / g - 1
            let x = checked[i], ek = (num(x["kcal"]) ?? 0) * more, ep = had * more, ec = (num(x["carbs"]) ?? 0) * more, ef = (num(x["fat"]) ?? 0) * more
            checked[i]["grams"] = grams
            checked[i]["kcal"] = ((num(x["kcal"]) ?? 0) + ek).rounded(); checked[i]["protein"] = had + ep
            checked[i]["carbs"] = (num(x["carbs"]) ?? 0) + ec; checked[i]["fat"] = (num(x["fat"]) ?? 0) + ef
            k += ek; p += ep; c += ec; f += ef
        }
        // the totals are the ingredients added up, and the recipe is written from these same ingredients
        m["ingredients"] = checked
        m["kcal"] = k.rounded(); m["protein"] = p.rounded(); m["carbs"] = c.rounded(); m["fat"] = f.rounded()
        if !used.isEmpty { m["uses"] = used.joined(separator: ", "); m["fromLabels"] = true }
        return m
    }

    /// Ideas for what they asked, with the conversation so far: their own calories or protein when they gave them, this
    /// meal's share otherwise; a reply changes the last ideas rather than starting again.
    private func suggest(_ asked: String) async {
        busy = true; problem = nil
        stepsDone = ["Read what you asked"]
        stepNow = "Thinking up ideas in your usual style…"
        defer { busy = false }
        let target = store.mealTarget(meal), aim = proteinShare
        let had = history.prefix(20).map { "\($0.name) (\($0.days)×)" }.joined(separator: ", ")
        let cuisines = (store.habits["cuisines"] as? [String] ?? []).joined(separator: ", ")
        let cook = cooking == Self.cookChoices[0] ? "No cooking: assembling, shop-bought or a microwave only."
                 : cooking == Self.cookChoices[2] ? "Happy to cook properly." : "Quick: 15 minutes or so."
        let scanned = scans
        // the conversation so far: what they asked, and the ideas given each time
        let earlier = turns.dropLast().suffix(8).map { t -> String in
            t.me ? "They asked: \(t.text)" : "You suggested: " + t.ideas.map { "\(str($0["name"])) (\(Int(num($0["kcal"]) ?? 0)) kcal)" }.joined(separator: "; ")
        }.joined(separator: "\n")
        let ingredient: JSON = ["type": "object", "properties": [
            "name": ["type": "string"] as JSON, "grams": ["type": "number"] as JSON,
            "label": ["type": "integer", "description": "The number of the scanned food this is (1, 2…), or 0 if it isn't one"] as JSON,
            "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON, "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON
        ] as JSON, "required": ["name", "grams", "label", "kcal", "protein", "carbs", "fat"]]
        let schema: JSON = ["type": "object", "properties": [
            "reply": ["type": "string", "description": "Under 15 words introducing the ideas, in plain words, e.g. 'Three quick Chinese-style ones, each about 500 kcal and 60 g protein:'. Nothing about sources or rounding"] as JSON,
            "aim": ["type": "number", "description": "The protein the ideas aim for, in grams"] as JSON,
            "ideas": ["type": "array", "items": ["type": "object", "properties": [
                "name": ["type": "string"] as JSON, "kcal": ["type": "number"] as JSON, "protein": ["type": "number"] as JSON,
                "carbs": ["type": "number"] as JSON, "fat": ["type": "number"] as JSON, "minutes": ["type": "number"] as JSON,
                "why": ["type": "string", "description": "Under 14 words: why it suits them"] as JSON,
                "ingredients": ["type": "array", "items": ingredient] as JSON
            ] as JSON, "required": ["name", "kcal", "protein", "carbs", "fat", "minutes", "why", "ingredients"]] as JSON] as JSON
        ] as JSON, "required": ["reply", "aim", "ideas"]]
        let labels = scanned.enumerated().map { "\($0.offset + 1). \($0.element.prompt)" }.joined(separator: "\n")
        let prompt = """
        Suggest 3 \(meal.lowercased()) ideas for someone in \(Plan.country), one portion each.
        They said: "\(asked)"
        \(earlier.isEmpty ? "" : "The conversation so far (their new message changes your last ideas: keep what they didn't ask to change):\n\(earlier)\n")
        Size each idea for this one meal: about \(Int(target.kcal)) kcal (between \(Int(target.kcal - 120)) and \(Int(target.kcal + 60))), not the whole day's \(Int(left)) kcal left, and at least \(Int(aim)) g protein. If they give their own calories or protein in their message, use theirs instead, and set aim to the protein you're aiming for.
        Protein comes from real portions of protein foods (meat, fish, eggs, dairy, beans, tofu): protein per ingredient must be its true standard value, never raised to reach the aim. If what they have in can't honestly get there, get as close as you can.
        What they've actually had for \(meal.lowercased()) over the last 4 weeks: \(had.isEmpty ? "nothing logged yet" : had).
        Match that style unless they ask for something else: if it's mostly one cuisine, stay in it and use the ingredients and dishes they clearly buy, just lighter or better balanced.
        Cuisines they like: \(cuisines.isEmpty ? "not said" : cuisines). \(cook)
        Foods they name are what they have in: build the ideas mostly from those, plus staples like oil, salt, sauces and spices.
        \(labels.isEmpty ? "" : "They scanned these foods, with the numbers printed on their packs:\n\(labels)\nUse them where they fit, and lean on the highest-protein ones to reach the protein aim. For these use exactly those numbers.")
        List every ingredient with its grams and its own kcal, protein, carbs and fat; set label to the scanned food's number when it is one.
        Real dish names, numbers from standard reference values.
        """
        do {
            let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true, tries: 3, job: "plans")
            if Task.isCancelled { return }   // a takeaway question: the Assistant has it
            stepsDone.append("Came up with \(list(a["ideas"]).count) ideas")
            stepNow = "Checking each ingredient's numbers…"
            let goal = pos(a["aim"]) ?? aim
            let got = list(a["ideas"]).map { i -> JSON in
                var c = i; c["meal"] = meal; c["aim"] = goal
                return Self.withLabels(c, scanned)
            }
            if got.isEmpty { problem = "No ideas came back. Try again."; return }
            let reply = str(a["reply"]).isEmpty ? "Here are three:" : str(a["reply"])
            withAnimation(.snappy) { turns.append(Turn(me: false, text: reply, ideas: got)) }
        } catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }
}
