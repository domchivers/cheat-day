import PhotosUI
import SwiftUI

/// The assistant: a chat that can log a plate from a photo or words, plan the rest of the day, fix today's list,
/// write a recipe to save as a meal, or find a lighter version. Chats are kept, without photos.
struct AssistantView: View {
    let meal: String
    var firstQuestion = ""
    var startCamera = false   // opened from a meal pop-up's +: the fridge or the plate
    @Environment(\.dismiss) private var dismiss
    private var live: AssistantLive { AssistantLive.shared }
    private var turns: [Assistant.Turn] { get { live.turns } nonmutating set { live.turns = newValue } }
    private var chatId: String { get { live.chatId } nonmutating set { live.chatId = newValue } }
    private var busy: Bool { get { live.busy } nonmutating set { live.busy = newValue } }
    private var problem: String? { get { live.problem } nonmutating set { live.problem = newValue } }
    @State private var text = ""
    @State private var pending: [UIImage] = []
    @State private var speech = Speech()
    @State private var picked: [PhotosPickerItem] = []
    @State private var camera = false
    @State private var library = false
    private var done: [UUID: String] { get { live.done } nonmutating set { live.done = newValue } }
    @State private var showChats = false
    @State private var viewing: Photos?
    @State private var openPart: String?   // the estimate part showing its details ("turn-index")
    @State private var stepsDone: [String] = []   // what the AI has done so far for this message, ticked
    @State private var stepNow = "Thinking…"
    @State private var changing: PartRef?
    @State private var amount: EditTarget?   // a typed food's How much, from its card
    private var addedFoods: [String: Set<Int>] { get { live.addedFoods } nonmutating set { live.addedFoods = newValue } }   // a meal card's foods put on one at a time
    private var mealNames: [String: String] { get { live.mealNames } nonmutating set { live.mealNames = newValue } }   // what a meal card's foods are called, as one
    @State private var keeping: Task<Void, Never>?
    @State private var keptKey = ""
    @State private var openCombo: [UUID: Int] = [:]   // which of a takeaway answer's combos is open
    @State private var openMethod: Set<UUID> = []   // the dish cards whose method is showing
    @State private var cardEdits: [String: CardEdit] = [:]   // what's been changed on each takeaway combo ("turn-combo")
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }

    private static let examples = ["What fits the rest of today?", "2 eggs on toast and a flat white", "Any healthy lunch spots near me?", "A recipe under 600 kcal", "Make today healthier"]
    @State private var exampleAt = 0

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
              VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // one line and one example at a time, like Plan a meal (a paragraph and four suggestion buttons
                        // were too much); the examples fade to the next every 4 seconds, all laid out so the bubble
                        // keeps the tallest one's height, and stay put once they're typing or talking
                        bot(VStack(alignment: .leading, spacing: 8) {
                            Text("**Ask me anything about your day.**")
                            if turns.isEmpty {
                                ZStack(alignment: .topLeading) {
                                    ForEach(Self.examples.indices, id: \.self) { i in
                                        Text("For example: “\(Self.examples[i])”").italic().foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .opacity(i == exampleAt % Self.examples.count ? 1 : 0).accessibilityHidden(i != exampleAt % Self.examples.count)
                                    }
                                }
                            }
                        })
                        .task {
                            while !Task.isCancelled {
                                try? await Task.sleep(for: .seconds(4))
                                if text.isEmpty && turns.isEmpty && !Task.isCancelled { withAnimation(.easeInOut(duration: 0.5)) { exampleAt += 1 } }
                            }
                        }
                        if turns.isEmpty {
                            HStack(spacing: 10) {
                                Button { openPhotos(camera: true) } label: { Label("Snap a plate", systemImage: "camera.fill").lineLimit(1).frame(maxWidth: .infinity) }
                                Button { openPhotos(camera: false) } label: { Label("Photos", systemImage: "photo.on.rectangle").lineLimit(1).frame(maxWidth: .infinity) }
                            }
                            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)).controlSize(.large)
                        }
                        ForEach(turns) { t in turnView(t).id(t.id) }
                        // only while their message is the last thing: once an answer's in, it never lingers under it
                        if busy, turns.last?.me == true { bot(progress).id("busy") }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 4) }
                    }
                    .padding(16)
                }
                .contentShape(Rectangle())   // the empty space counts too, not just the bubbles
                .scrollIndicators(.visible)   // the one place a scroll bar shows: a long chat
                .accessibilityIdentifier("chat")
                .scrollDismissesKeyboard(.immediately)
                // a short chat doesn't scroll, so a swipe can't put the keyboard away: a tap on the chat does
                .simultaneousGesture(TapGesture().onEnded {
                    // straight to UIKit: the focus flag can be stale after a plain tap into the box, so clearing it did nothing
                    typing = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                })
                .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) } }
                .onChange(of: busy) { _, b in if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
                .onChange(of: typing) { _, t in
                    guard t, let last = turns.last?.id else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                composer
              }
              .keyboardLift()
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Assistant")
            .keyboardDone()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { turns = []; chatId = uid(); done = [:]; addedFoods = [:]; mealNames = [:] } label: { Label("New chat", systemImage: "square.and.pencil") }
                        Button { showChats = true } label: { Label("Past chats", systemImage: "clock.arrow.circlepath") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showChats) { ChatsList { c in live.show(c); keptKey = cardsKey; showChats = false } }
            // what's done on the cards (grams changed, a sauce added, Add as a meal…) is saved too, not just the messages:
            // a chat where a meal was built on the cards came back from Past chats without any of it
            .onChange(of: cardsKey) { _, k in
                guard k != keptKey, !turns.isEmpty, !busy else { return }
                keeping?.cancel()
                keeping = Task { try? await Task.sleep(for: .seconds(1.5)); guard !Task.isCancelled else { return }; keptKey = k; live.keep(store) }
            }
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { Task { pending.append(await Self.shrunk(img)) } } }.ignoresSafeArea() }
            .fullScreenCover(item: $viewing) { PhotoViewer(photos: $0) }
            .sheet(item: $changing) { ref in MatchPicker(ref: ref) { food in setMatch(ref, to: food); changing = nil }.presentationDetents([.medium]) }
            .sheet(item: $amount) { t in
                NavigationStack { AmountView(target: t) { amount = nil } }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .photosPicker(isPresented: $library, selection: $picked, maxSelectionCount: 4, matching: .images)
            .onChange(of: picked) { _, items in if !items.isEmpty { Task { await load(items) } } }
            .onChange(of: showChats) { _, open in KeyboardDone.quiet = !open }   // past chats keep their Done
            .onChange(of: amount == nil) { _, none in KeyboardDone.quiet = none }   // and How much, for its number pad
            .onDisappear { KeyboardDone.quiet = false }
            .onAppear {
                KeyboardDone.quiet = true   // a chat box: the send button's right there, and scrolling or tapping away closes it
                live.open(fresh: !firstQuestion.isEmpty || startCamera)
                if startCamera { text = firstQuestion; camera = true }
                else if !firstQuestion.isEmpty && turns.isEmpty { text = firstQuestion; send() }
            }
        }
    }

    // MARK: bubbles

    /// A reply's **bold** shown bold, its lines and "- " points kept as written.
    static func rich(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// While the AI works: the steps done so far, ticked, and the one it's on.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(stepsDone, id: \.self) { s in
                Label { Text(s).foregroundStyle(.secondary) } icon: { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green) }
            }
            Label { Text(stepNow).fontWeight(.semibold) } icon: { ProgressView().controlSize(.small) }
        }
        .animation(.snappy, value: stepsDone)
    }

    /// Under a reply: what was checked, once it's all done.
    @ViewBuilder private func trailLines(_ lines: [String]) -> some View {
        if !lines.isEmpty {
            Divider().overlay(Color.white.opacity(0.08))
            ForEach(lines, id: \.self) { s in
                Label { Text(s).foregroundStyle(.secondary) } icon: { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                    .font(.caption)
            }
        }
    }

    private func bot<C: View>(_ content: C) -> some View {
        content.font(.subheadline).padding(12)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func turnView(_ t: Assistant.Turn) -> some View {
        if t.me {
            VStack(alignment: .trailing, spacing: 6) {
                if !t.images.isEmpty {
                    HStack { ForEach(t.images.indices, id: \.self) { i in
                        Button { viewing = Photos(images: t.images, start: i) } label: {
                            Image(uiImage: t.images[i]).resizable().scaledToFill().frame(width: 70, height: 70).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Photo \(i + 1), full screen")
                    } }
                }
                Text(t.text).font(.subheadline).padding(12).foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                bot(VStack(alignment: .leading, spacing: 8) { Text(Self.rich(t.text)); trailLines(t.result?["trail"] as? [String] ?? []) })
                if str(t.result?["engine"]) == "device" {
                    Label("Answered on this iPhone", systemImage: "bolt.fill").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.leading, 6)
                }
                if let r = t.result { card(r, turn: t.id) }
            }
        }
    }

    @ViewBuilder private func card(_ r: JSON, turn: UUID) -> some View {
        let meal = str(r["meal"]).isEmpty ? self.meal : str(r["meal"])   // "add to lunch" adds to lunch
        switch str(r["kind"]) {
        case "estimate":
            if let e = r["estimate"] as? JSON { estimateCard(e, turn: turn, meal: str(r["meal"]).isEmpty ? Meals.forEstimate(e, opened: meal) : meal) }
        case "plan":
            if let p = r["plan"] as? JSON { planCard(p, turn: turn, meal: str(r["meal"]).isEmpty ? Meals.now : meal) }
        case "edit":
            if let e = r["edit"] as? JSON { editCard(e, turn: turn, meal: meal) }
        case "recipe":
            if let rc = r["recipe"] as? JSON { recipeCard(rc, turn: turn, meal: meal) }
        case "lighter":
            if let l = r["lighter"] as? JSON { lighterCard(l, turn: turn, meal: meal) }
        case "takeaway":
            if let ta = r["takeaway"] as? JSON { takeawayCard(ta, turn: turn, meal: meal) }
        case "places":
            if let pl = r["places"] as? JSON { placesCard(pl) }
        case "quick":
            quickCard(list(r["foods"]), turn: turn, meal: meal)
        default: EmptyView()
        }
    }

    private func panel<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func macros(_ k: Double, _ p: Double, _ c: Double, _ f: Double) -> some View {
        HStack(spacing: 14) {
            Text("\(Fmt.int(k)) kcal").font(.headline.weight(.heavy))
            Text("P \(Int(p))g").foregroundStyle(.secondary); Text("C \(Int(c))g").foregroundStyle(.secondary); Text("F \(Int(f))g").foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold)).monospacedDigit()
    }

    private func addButton(_ label: String, key: String, turn: UUID, action: @escaping () -> Void) -> some View {
        let tag = "\(turn)-\(key)"
        return Button {
            action(); withAnimation { done[turn, default: ""] += "|\(tag)" }
        } label: {
            Label(done[turn, default: ""].contains(tag) ? "Added" : label, systemImage: done[turn, default: ""].contains(tag) ? "checkmark" : "plus.circle.fill").font(.subheadline.weight(.bold))
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(Theme.onAccent)
        .disabled(done[turn, default: ""].contains(tag))
    }

    private func estimateCard(_ e: JSON, turn: UUID, meal: String) -> some View {
        let k = num(e["kcal_total"]) ?? 0, p = num(e["protein_g"]) ?? 0, c = num(e["carbs_g"]) ?? 0, f = num(e["fat_g"]) ?? 0
        return panel {
            Text(str(e["name"])).font(.headline)
            // the shop once here, not in every part
            Text((str(e["shop"]).isEmpty ? "" : "\(str(e["shop"])) · ") + "\(Fmt.int(num(e["portion_g"]) ?? 0)) \(str(e["unit"]).isEmpty ? "g" : str(e["unit"]))")
                .font(.caption).foregroundStyle(.secondary)
            macros(k, p, c, f)
            let parts = list(e["parts"]), checked = Assistant.checkedCount(parts)
            let own = parts.filter { ["label", "them"].contains(str($0["src"])) }.count
            let web = parts.first { str($0["src"]) == "web" }
            ForEach(keyed(parts)) { entry in
                let i = entry.index, pt = entry.item, key = "\(turn)-\(i)"
                let flagged = pt["flagged"] as? Bool == true, ok = !["", "ai"].contains(str(pt["src"])) && !flagged
                Button { withAnimation(.snappy) { openPart = openPart == key ? nil : key } } label: {
                    HStack(spacing: 10) {
                        // the food's own icon, with a small tick when it was checked against the food tables, amber when
                        // its numbers still look wrong for that kind of food (the warning below says why), nothing when unchecked
                        FoodDot(name: str(pt["name"]), size: 30, hint: str(pt["match"]))
                            .overlay(alignment: .bottomTrailing) {
                                if flagged || ok {
                                    Image(systemName: flagged ? "exclamationmark" : "checkmark").font(.system(size: 7, weight: .black)).foregroundStyle(.black)
                                        .frame(width: 13, height: 13).background(flagged ? Theme.warn : Color.green, in: Circle())
                                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2)).offset(x: 3, y: 3)
                                }
                            }
                            .accessibilityLabel(flagged ? "Check this one" : ok ? "Checked" : "Not checked")
                        Text(str(pt["name"])).font(.subheadline.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer()
                        Text("\(Int(num(pt["grams"]) ?? 0)) g · \(Int(num(pt["kcal"]) ?? 0))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: openPart == key ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if openPart == key { partDetail(pt, index: i, turn: turn) }
            }
            flagList(e["flags"] as? [String] ?? [])
            let pending = !parts.isEmpty && parts.allSatisfy { str($0["src"]).isEmpty }   // not checked yet
            if pending { Label("Checking against the food database…", systemImage: "hourglass").font(.caption2).foregroundStyle(.secondary) }
            else if let web, parts.count == 1 { Text("From its label, found online: \(str(web["source"]))").font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
            else if let web, parts.allSatisfy({ str($0["src"]) == "web" }) {   // every item from the shop's own published numbers
                Text("From \(str(e["shop"]).isEmpty ? "the shop" : str(e["shop"]))'s own published numbers: \(str(web["source"]))").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            else if own > 0, own == parts.count { Text("Worked out from your label or your numbers.").font(.caption2).foregroundStyle(.secondary) }
            else { Text(checked > 0 ? "\(checked) of \(parts.count) parts checked against food databases\(num(e["aiKcal"]).map { " (the AI first said \(Int($0)) kcal)" } ?? ""). An estimate, not a label."
                             : "The AI's estimate: none of the parts could be checked against a food database.")
                .font(.caption2).foregroundStyle(.secondary) }
            let tag = "\(turn)-est", added = done[turn, default: ""].contains(tag)
            if e["size_unsure"] as? Bool == true, !added {
                // nothing in the photo showed its size: one tap says, and stays picked so it can be changed
                choiceRow("How big was it?", ["Small", "Regular", "Large"], picked: str(e["sizeAnswer"])) { answerSize(turn, $0) }
            }
            if e["eaten_unsure"] as? Bool == true, !added {
                // only a finished or part-eaten plate: the parts are the full serving, scaled to how much they had
                choiceRow("How much did you have?", Self.eaten.map { $0.name }, picked: str(e["eatenAnswer"]).isEmpty ? "All" : str(e["eatenAnswer"])) { answerEaten(turn, $0) }
            }
            let sauce = str(e["side_sauce"])
            if !sauce.isEmpty, !added, e["sauceAdded"] as? Bool != true, let food = Self.sauceFood(sauce) {
                // left out because it wasn't on the food: one tap puts the usual amount in
                choiceRow("Had \(sauce.lowercased())?", ["None"] + Self.spoons.map { $0.name }, picked: "") { name in
                    if let g = Self.spoons.first(where: { $0.name == name })?.grams { addSauce(turn, sauce, food, grams: g) } else { noSauce(turn) }
                }
            }
            // a plate of several things can be called what they call it, as a card of separate foods can
            let nameKey = "\(turn)-name", typed = (mealNames[nameKey] ?? "").trimmingCharacters(in: .whitespaces)
            if parts.count > 1, !added {
                HStack(spacing: 8) {
                    Text("Name").foregroundStyle(.secondary)
                    TextField(str(e["name"]), text: Binding(get: { mealNames[nameKey] ?? "" }, set: { mealNames[nameKey] = $0 })).submitLabel(.done)
                }
                .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 10) {
                // one clear Add, the full width left over; every control on the card 40 pt tall with the same corners
                Button {
                    var b = Assistant.basis(name: typed.isEmpty ? str(e["name"]) : typed, kcal: k, grams: num(e["portion_g"]), unit: str(e["unit"]).isEmpty ? "g" : str(e["unit"]), p: p, c: c, f: f)
                    // what the AI made it, kept on the item so a later change of amount can be learnt from
                    if !str(e["shop"]).isEmpty { b["shop"] = str(e["shop"]) }
                    if let g = pos(e["aiPortion"]) ?? pos(e["portion_g"]) { b["aiGrams"] = g; b["aiKcal"] = num(e["aiPortionKcal"]) ?? k }
                    b["aiMatches"] = parts.map { "\(str($0["name"])) → \(str($0["match"]).isEmpty ? "unchecked" : str($0["match"]))" }.joined(separator: "; ")
                    store.add(b, kcal: k, meal: meal)
                    withAnimation { done[turn, default: ""] += "|\(tag)" }
                } label: {
                    Label(added ? "Added" : "Add to \(meal.lowercased())", systemImage: added ? "checkmark" : "plus.circle.fill")
                        .font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).frame(height: Self.control)
                        .foregroundStyle(Theme.onAccent).background(Theme.accent.opacity(added ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).disabled(added)
                if !added && !parts.isEmpty {   // the whole plate a size down or up, every part with it
                    let start = pos(e["aiPortion"]) ?? pos(e["portion_g"]) ?? 1
                    // 10% steps of what the AI first said (100, 90, 80…), or a percentage typed in the middle
                    let pct = ((num(e["portion_g"]) ?? start) / start * 100).rounded()
                    SizeStepper(less: { setPercent(turn, Self.step(pct, by: -10, min: 10)) }, more: { setPercent(turn, Self.step(pct, by: 10, min: 10)) }) {
                        NumberBox(value: pct, unit: "%") { setPercent(turn, $0) }
                    }
                }
            }
        }
    }

    /// Every button on the estimate card is this tall, with 12 pt corners.
    static let control: CGFloat = 40

    /// A question on the card with a row of equal buttons, the picked one filled.
    private func choiceRow(_ title: String, _ names: [String], picked: String, _ tap: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    let on = picked == name
                    Button { tap(name) } label: {
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).frame(height: Self.control)
                            .foregroundStyle(on ? Theme.onAccent : .primary)
                            .background(on ? Theme.accent : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static let eaten: [(name: String, share: Double)] = [("¼", 0.25), ("½", 0.5), ("¾", 0.75), ("All", 1)]
    static let spoons: [(name: String, grams: Double)] = [("1 tsp", 5), ("1 tbsp", 15), ("2 tbsp", 30)]

    /// The table's entry for a side sauce the AI named, so it can be added with real numbers (nil: no offer).
    static func sauceFood(_ name: String) -> FoodTable.Food? { FoodTable.current.best(name, tags: ["bought"]) }

    /// A tapped part: the size the AI judged it at, the entry it was counted as (with Change), and its grams to type over.
    private func partDetail(_ pt: JSON, index i: Int, turn: UUID) -> some View {
        let g = num(pt["grams"]) ?? 0, canChange = !["label", "them", "web"].contains(str(pt["src"]))
        return VStack(spacing: 0) {
            if !str(pt["size"]).isEmpty {
                detailRow("Sized") { Text(str(pt["size"])).foregroundStyle(.primary).multilineTextAlignment(.trailing) }
                Divider()
            }
            Button { if canChange { changing = PartRef(turn: turn, index: i, part: pt) } } label: {
                detailRow("Counted as") {
                    HStack(spacing: 6) {
                        Text(str(pt["match"]).isEmpty ? "The AI's own numbers" : str(pt["match"])).foregroundStyle(.primary).multilineTextAlignment(.trailing)
                        if canChange { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                    }
                }
            }
            .buttonStyle(.plain).disabled(!canChange)
            Divider()
            detailRow("Amount") {
                // just this part a size down or up, or its grams typed in the middle
                // 10 g steps, 5 g under 50 g, landing on round numbers (97 → 90 → 80)
                let by: Double = g < 50 ? 5 : 10
                SizeStepper(less: { setGrams(turn, index: i, to: Self.step(g, by: -by, min: by)) }, more: { setGrams(turn, index: i, to: Self.step(g, by: by, min: by)) }) {
                    NumberBox(value: g, unit: "g") { setGrams(turn, index: i, to: $0) }
                }
            }
        }
        .font(.caption)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func detailRow<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value()
        }
        .padding(.horizontal, 12).frame(minHeight: 48).contentShape(Rectangle())
    }

    // MARK: changing an estimate before it's added

    /// Changes a turn's estimate in place (parts, then the totals from them), remembering what the AI first said.
    private func change(_ turn: UUID, _ edit: (inout [JSON]) -> Void) {
        guard let t = turns.firstIndex(where: { $0.id == turn }), var r = turns[t].result, var e = r["estimate"] as? JSON else { return }
        if e["aiPortion"] == nil { e["aiPortion"] = e["portion_g"] ?? 0; e["aiPortionKcal"] = e["kcal_total"] ?? 0 }
        var parts = list(e["parts"])
        edit(&parts)
        func sum(_ k: String) -> Double { parts.reduce(0) { $0 + (num($1[k]) ?? 0) } }
        e["parts"] = parts
        e["kcal_total"] = sum("kcal").rounded(); e["protein_g"] = sum("protein_g"); e["carbs_g"] = sum("carbs_g"); e["fat_g"] = sum("fat_g")
        e["portion_g"] = sum("grams").rounded()
        r["estimate"] = e
        var all = turns; all[t].result = r; turns = all
    }

    /// Changes when anything on a card does, to know when to save the chat again.
    private var cardsKey: String {
        let cards = turns.map { t -> String in
            let e = dict(t.result?["estimate"])
            return "\(t.id)\(num(e["kcal_total"]) ?? 0)/\(num(e["portion_g"]) ?? 0)/\(list(e["parts"]).count)/\(str(e["sizeAnswer"]))\(str(e["eatenAnswer"]))\(e["sauceAdded"] != nil)"
        }
        return cards.joined(separator: ",") + "\(done.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value))\(addedFoods.mapValues { $0.sorted() }.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" })\(mealNames.sorted { $0.key < $1.key }.map(\.value))"
    }

    private func estimate(_ turn: UUID) -> JSON { dict(turns.first { $0.id == turn }?.result?["estimate"]) }

    /// What changed, kept for learning how far off the AI runs (nothing reads it yet).
    private func logCorrection(_ turn: UUID, _ change: String, part: JSON, from: Any, to: Any) {
        let e = estimate(turn)
        store.perform(["type": "correction", "row": ["at": ISO.now(), "name": str(part["name"]), "plate": str(e["name"]), "shop": str(e["shop"]),
                                                    "kind": FoodKind.of(str(part["name"])).rawValue, "change": change, "from": from, "to": to,
                                                    "match": str(part["match"]), "size": str(part["size"])] as JSON])
    }

    private func scaled(_ p: JSON, _ f: Double) -> JSON {
        var x = p
        x["grams"] = ((num(p["grams"]) ?? 0) * f).rounded(); x["kcal"] = ((num(p["kcal"]) ?? 0) * f).rounded()
        for m in ["protein_g", "carbs_g", "fat_g"] { if let v = num(p[m]) { x[m] = v * f } }
        return x
    }

    /// The next round number up or down: 97 down by 10 is 90, 90 down is 80, 97 up is 100. Never below the minimum.
    static func step(_ v: Double, by d: Double, min lo: Double) -> Double {
        let size = abs(d), onStep = (v / size).rounded() * size == v.rounded()
        let next = d < 0 ? (onStep ? v.rounded() - size : (v / size).rounded(.down) * size)
                         : (onStep ? v.rounded() + size : (v / size).rounded(.up) * size)
        return max(lo, next)
    }

    /// The whole plate at a percentage of what the AI first said.
    private func setPercent(_ turn: UUID, _ pct: Double) {
        let e = estimate(turn), start = pos(e["aiPortion"]) ?? pos(e["portion_g"]) ?? 0, now = pos(e["portion_g"]) ?? 0
        guard start > 0, now > 0, pct > 0 else { return }
        let f = start * pct / 100 / now
        if abs(f - 1) > 0.001 { scale(turn, by: f) }
    }

    private func scale(_ turn: UUID, by f: Double) {
        let before = num(estimate(turn)["portion_g"]) ?? 0
        change(turn) { parts in parts = parts.map { scaled($0, f) } }
        logCorrection(turn, f < 1 ? "smaller" : "bigger", part: ["name": str(estimate(turn)["name"])], from: before, to: num(estimate(turn)["portion_g"]) ?? 0)
    }

    /// Small, Regular or Large for a plate the AI couldn't size: the whole plate scaled, and the question gone.
    /// Small, Regular or Large for a plate the AI couldn't size: the whole plate scaled from whatever was picked before
    /// (Small then Large is ×1.3 / ×0.75), and the choice kept highlighted.
    private func answerSize(_ turn: UUID, _ name: String) {
        func factor(_ n: String) -> Double { n == "Small" ? 0.75 : n == "Large" ? 1.3 : 1 }
        let was = str(estimate(turn)["sizeAnswer"])
        guard was != name else { return }
        let f = factor(name) / factor(was.isEmpty ? "Regular" : was)
        if f != 1 { scale(turn, by: f) }
        guard let t = turns.firstIndex(where: { $0.id == turn }), var r = turns[t].result, var e = r["estimate"] as? JSON else { return }
        e["sizeAnswer"] = name; r["estimate"] = e
        var all = turns; all[t].result = r
        withAnimation(.snappy) { turns = all }
        if f == 1 { logCorrection(turn, "regular", part: ["name": str(e["name"])], from: num(e["portion_g"]) ?? 0, to: num(e["portion_g"]) ?? 0) }
    }

    /// ¼, ½, ¾ or All of a plate photographed after: every part scaled from whatever was picked before (All at first).
    private func answerEaten(_ turn: UUID, _ name: String) {
        func share(_ n: String) -> Double { Self.eaten.first { $0.name == n }?.share ?? 1 }
        let was = str(estimate(turn)["eatenAnswer"])
        guard was != name, was != "" || name != "All" else { return }
        // not through scale: eating half isn't the AI sizing it wrong, so it isn't logged as a correction
        let f = share(name) / share(was.isEmpty ? "All" : was)
        change(turn) { parts in parts = parts.map { scaled($0, f) } }
        guard let t = turns.firstIndex(where: { $0.id == turn }), var r = turns[t].result, var e = r["estimate"] as? JSON else { return }
        e["eatenAnswer"] = name; r["estimate"] = e
        var all = turns; all[t].result = r
        withAnimation(.snappy) { turns = all }
    }

    /// The side sauce they did have, as its own checked part, and the offer gone.
    private func addSauce(_ turn: UUID, _ name: String, _ food: FoodTable.Food, grams: Double) {
        let part = Assistant.checked(["name": name, "grams": grams, "numbers_from": "estimate"], kcal100: food.kcal, p100: food.p, c100: food.c, f100: food.f,
                                     source: FoodTable.current.src, match: food.name)
        withAnimation(.snappy) { change(turn) { parts in parts.append(part) } }
        guard let t = turns.firstIndex(where: { $0.id == turn }), var r = turns[t].result, var e = r["estimate"] as? JSON else { return }
        e["sauceAdded"] = true; r["estimate"] = e
        var all = turns; all[t].result = r; turns = all
        logCorrection(turn, "part added", part: part, from: 0, to: grams)
    }

    /// None: the offer goes and nothing's added.
    private func noSauce(_ turn: UUID) {
        guard let t = turns.firstIndex(where: { $0.id == turn }), var r = turns[t].result, var e = r["estimate"] as? JSON else { return }
        e["sauceAdded"] = true; r["estimate"] = e
        var all = turns; all[t].result = r
        withAnimation(.snappy) { turns = all }
    }

    private func setGrams(_ turn: UUID, index i: Int, to g: Double) {
        let parts = list(estimate(turn)["parts"])
        guard parts.indices.contains(i), let was = pos(parts[i]["grams"]), g > 0, abs(g - was) >= 1 else { return }
        change(turn) { parts in parts[i] = scaled(parts[i], g / was); parts[i]["grams"] = g.rounded() }
        logCorrection(turn, "grams", part: parts[i], from: was, to: g.rounded())
    }

    private func setMatch(_ ref: PartRef, to food: FoodTable.Food) {
        let old = str(ref.part["match"])
        change(ref.turn) { parts in
            guard parts.indices.contains(ref.index) else { return }
            parts[ref.index] = Assistant.checked(parts[ref.index], kcal100: food.kcal, p100: food.p, c100: food.c, f100: food.f, source: FoodTable.current.src, match: food.name)
        }
        logCorrection(ref.turn, "match", part: ref.part, from: old, to: food.name)
    }

    private func planCard(_ plan: JSON, turn: UUID, meal: String) -> some View {
        panel {
            ForEach(list(plan["suggestions"]).indices, id: \.self) { i in
                let s = list(plan["suggestions"])[i], k = num(s["kcal"]) ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(str(s["name"])).font(.subheadline.weight(.bold))
                        Spacer()
                        Text("\(Fmt.int(k))").font(.subheadline.weight(.heavy)).monospacedDigit()
                    }
                    Text("\(str(s["amount"])) · \(str(s["why"]))").font(.caption).foregroundStyle(.secondary)
                    addButton("Add", key: "plan\(i)", turn: turn) {
                        store.add(Assistant.basis(name: str(s["name"]), kcal: k, grams: nil, p: num(s["protein_g"]) ?? 0, c: num(s["carbs_g"]) ?? 0, f: num(s["fat_g"]) ?? 0), kcal: k, meal: meal)
                    }
                }
                if i < list(plan["suggestions"]).count - 1 { Divider() }
            }
        }
    }

    @ViewBuilder private func editCard(_ edit: JSON, turn: UUID, meal: String) -> some View {
        let acts = list(edit["actions"])
        // only foods to add, two or more (a dinner's ingredients): each can go on by itself, or the lot as one meal
        if acts.count >= 2, acts.allSatisfy({ str($0["action"]) == "add" }) { mealCard(acts, flags: edit["flags"] as? [String] ?? [], turn: turn, meal: meal) }
        else { changesCard(edit, acts: acts, turn: turn, meal: meal) }
    }

    /// Foods to add, as a meal or one at a time: a + on each puts just that one on (it turns into a tick); Add as a meal
    /// puts the rest on as one food, named as they like (the meal to start), with their totals; Add separately puts each
    /// on as its own row, as Make these changes did.
    private func mealCard(_ acts: [JSON], flags: [String], turn: UUID, meal: String) -> some View {
        let key = turn.uuidString, gone = addedFoods[key] ?? [], all = done[turn, default: ""].contains("|meal")
        let left = acts.indices.filter { !gone.contains($0) && !all }
        let k = left.reduce(0.0) { $0 + (num(acts[$1]["kcal"]) ?? 0) }, p = left.reduce(0.0) { $0 + (num(acts[$1]["protein_g"]) ?? 0) }
        return panel {
            ForEach(acts.indices, id: \.self) { i in
                let a = acts[i], on = gone.contains(i) || all
                HStack(spacing: 11) {
                    FoodDot(name: str(a["name"]), size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(str(a["name"])).font(.subheadline.weight(.semibold))
                        Text("\(Fmt.int(num(a["kcal"]) ?? 0)) kcal · P \(Int(num(a["protein_g"]) ?? 0))g · C \(Int(num(a["carbs_g"]) ?? 0))g · F \(Int(num(a["fat_g"]) ?? 0))g")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button {
                        store.add(Self.food(a), kcal: num(a["kcal"]) ?? 0, meal: meal)
                        withAnimation(.snappy) { addedFoods[key, default: []].insert(i) }
                    } label: {
                        Image(systemName: on ? "checkmark" : "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(on ? Color.black : Theme.onAccent)
                            .frame(width: 36, height: 36).background(on ? AnyShapeStyle(Theme.walk) : Theme.accentFill, in: Circle())
                    }
                    .buttonStyle(.plain).disabled(on)
                    .accessibilityLabel(on ? "\(str(a["name"])) added" : "Add \(str(a["name"])) on its own")
                }
            }
            flagList(flags)
            if !left.isEmpty {
                HStack(spacing: 8) {
                    Text("Name").foregroundStyle(.secondary)
                    TextField(meal, text: Binding(get: { mealNames[key] ?? "" }, set: { mealNames[key] = $0 })).submitLabel(.done)
                }
                .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                (Text(gone.isEmpty ? "" : "The other \(left.count): ").foregroundStyle(.secondary) + Text("\(Fmt.int(k)) kcal").bold() + Text(" · \(Int(p.rounded())) g protein").foregroundStyle(.secondary))
                    .font(.footnote)
                HStack(spacing: 8) {
                    Button {
                        let name = (mealNames[key] ?? "").trimmingCharacters(in: .whitespaces)
                        store.add(Self.meal(left.map { acts[$0] }, name: name.isEmpty ? meal : name), kcal: k, meal: meal)
                        withAnimation(.snappy) { done[turn, default: ""] += "|meal" }
                    } label: { Label("Add as a meal", systemImage: "plus.circle.fill").font(.subheadline.weight(.bold)) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(Theme.onAccent)
                    Button {
                        let ids = left.map { store.add(Self.food(acts[$0]), kcal: num(acts[$0]["kcal"]) ?? 0, meal: meal) }
                        if ids.count > 1 { store.undo = Store.Undo(ids: ids, label: "Added \(ids.count) foods", at: Date()) }
                        withAnimation(.snappy) { done[turn, default: ""] += "|meal" }
                    } label: { Text("Add separately").font(.subheadline.weight(.bold)) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                }
            } else {
                Label("All added", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.walk)
            }
        }
    }

    /// One food to add, as an edit card describes it.
    private static func food(_ a: JSON) -> JSON {
        Assistant.basis(name: str(a["name"]), kcal: num(a["kcal"]) ?? 0, grams: nil, p: num(a["protein_g"]) ?? 0, c: num(a["carbs_g"]) ?? 0, f: num(a["fat_g"]) ?? 0)
    }

    /// Several foods as one: their totals under one name, and the foods named on it ("8 ingredients" on Today).
    private static func meal(_ acts: [JSON], name: String) -> JSON {
        func sum(_ k: String) -> Double { acts.reduce(0) { $0 + (num($1[k]) ?? 0) } }
        var b = Assistant.basis(name: name, kcal: sum("kcal"), grams: nil, p: sum("protein_g"), c: sum("carbs_g"), f: sum("fat_g"))
        b["ingredients"] = acts.map { str($0["name"]) }
        return b
    }

    private func changesCard(_ edit: JSON, acts: [JSON], turn: UUID, meal: String) -> some View {
        return panel {
            ForEach(keyed(acts)) { entry in
                let a = entry.item
                VStack(alignment: .leading, spacing: 2) {
                    Label(describe(a), systemImage: ["add": "plus.circle", "remove": "minus.circle", "update": "pencil.circle", "workout": "figure.walk"][str(a["action"])] ?? "circle")
                        .font(.subheadline)
                    // each change's numbers before it's made, so a slip shows at a glance
                    if ["add", "update"].contains(str(a["action"])), let k = num(a["kcal"]) {
                        Text("\(Fmt.int(k)) kcal · P \(Int(num(a["protein_g"]) ?? 0))g · C \(Int(num(a["carbs_g"]) ?? 0))g · F \(Int(num(a["fat_g"]) ?? 0))g")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).padding(.leading, 28)
                    }
                }
            }
            flagList(edit["flags"] as? [String] ?? [])
            let key = "edit"
            Button {
                let result = Assistant.apply(edit, meal: meal, store: store)
                withAnimation { done[turn, default: ""] += "|\(turn)-\(key)|" + result.joined(separator: ". ") }
            } label: {
                Label(done[turn, default: ""].contains("\(turn)-\(key)") ? "Done" : "Make these changes", systemImage: done[turn, default: ""].contains("\(turn)-\(key)") ? "checkmark" : "checkmark.circle.fill").font(.subheadline.weight(.bold))
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(Theme.onAccent)
            .disabled(done[turn, default: ""].contains("\(turn)-\(key)"))
        }
    }

    /// What the checks found: numbers fixed from the macros, or values that look wrong for that kind of food.
    @ViewBuilder private func flagList(_ flags: [String]) -> some View {
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(flags, id: \.self) { f in
                    Label(f, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private func describe(_ a: JSON) -> String {
        let name = str(a["name"]).isEmpty ? str(a["target"]) : str(a["name"])
        switch str(a["action"]) {
        case "add": return "Add \(name)\(num(a["kcal"]).map { ", \(Int($0)) kcal" } ?? "")"
        case "remove": return "Remove \(str(a["target"]))"
        case "update": return "Change \(str(a["target"]))\(num(a["kcal"]).map { " to \(Int($0)) kcal" } ?? "")"
        case "workout": return "Log \(str(a["activity"])), \(Int(num(a["minutes"]) ?? 0)) min"
        default: return name
        }
    }

    private func recipeCard(_ rc: JSON, turn: UUID, meal: String) -> some View {
        let ings = list(rc["ingredients"]), portions = max(1, num(rc["portions"]) ?? 1)
        let total = ings.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let p = ings.reduce(0) { $0 + (num($1["protein_g"]) ?? 0) }, c = ings.reduce(0) { $0 + (num($1["carbs_g"]) ?? 0) }, f = ings.reduce(0) { $0 + (num($1["fat_g"]) ?? 0) }
        let items: [JSON] = ings.map { i in
            var it = Assistant.basis(name: str(i["name"]), kcal: num(i["kcal"]) ?? 0, grams: num(i["grams"]), p: num(i["protein_g"]) ?? 0, c: num(i["carbs_g"]) ?? 0, f: num(i["fat_g"]) ?? 0)
            it["id"] = uid(); it["kcal"] = Int((num(i["kcal"]) ?? 0).rounded()); it["grams"] = num(i["grams"]) ?? 0; it["unitLabel"] = "g"
            return it
        }
        return panel {
            Text(str(rc["name"])).font(.headline)
            Text("\(Fmt.one(portions)) portion\(portions == 1 ? "" : "s")\(portions == 1 ? "" : " · per portion:")").font(.caption).foregroundStyle(.secondary)
            macros(total / portions, p / portions, c / portions, f / portions)
            // each ingredient as the foods card shows a food: its picture, its name, its numbers under it, the grams beside
            ForEach(ings.indices, id: \.self) { i in
                let g = ings[i]
                HStack(spacing: 11) {
                    FoodDot(name: str(g["name"]), size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(str(g["name"])).font(.subheadline.weight(.semibold))
                        Text("\(Fmt.int(num(g["kcal"]) ?? 0)) kcal · P \(Int((num(g["protein_g"]) ?? 0).rounded()))g · C \(Int((num(g["carbs_g"]) ?? 0).rounded()))g · F \(Int((num(g["fat_g"]) ?? 0).rounded()))g")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text("\(Int(num(g["grams"]) ?? 0)) g").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            let steps = rc["steps"] as? [String] ?? []
            if !steps.isEmpty {
                // the method on one line until it's wanted
                let open = openMethod.contains(turn)
                Divider()
                Button { withAnimation(.snappy) { if open { openMethod.remove(turn) } else { openMethod.insert(turn) } } } label: {
                    HStack {
                        Text("Method").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                        Spacer()
                        Text("\(steps.count) step\(steps.count == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
                        Image(systemName: open ? "chevron.up" : "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    VStack(alignment: .leading, spacing: 4) { ForEach(steps.indices, id: \.self) { i in Text("\(i + 1). \(steps[i])").font(.caption) } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // their own name for it, as the foods card has: the dish's to start with
            let key = turn.uuidString, typed = (mealNames[key] ?? "").trimmingCharacters(in: .whitespaces), named = typed.isEmpty ? str(rc["name"]) : typed
            HStack(spacing: 8) {
                Text("Name").foregroundStyle(.secondary)
                TextField(str(rc["name"]), text: Binding(get: { mealNames[key] ?? "" }, set: { mealNames[key] = $0 })).submitLabel(.done)
            }
            .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                addButton("Add a portion", key: "portion", turn: turn) {
                    store.add(Assistant.basis(name: named, kcal: total / portions, grams: nil, p: p / portions, c: c / portions, f: f / portions), kcal: total / portions, meal: meal)
                }
                // the quieter of the two: saving it for another day
                let tag = "\(turn)-save", saved = done[turn, default: ""].contains(tag)
                Button {
                    store.perform(["type": "saveMeal", "meal": ["id": uid(), "name": named, "portions": portions, "items": items, "steps": steps, "saved": true, "updatedAt": ISO.now()] as JSON])
                    withAnimation { done[turn, default: ""] += "|\(tag)" }
                } label: { Label(saved ? "Saved" : "Save as a meal", systemImage: saved ? "checkmark" : "bookmark").font(.subheadline.weight(.bold)) }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).disabled(saved)
            }
        }
    }

    private func lighterCard(_ l: JSON, turn: UUID, meal: String) -> some View {
        let k = num(l["kcal_per_serving"]) ?? 0
        return panel {
            Text(str(l["name"])).font(.headline)
            macros(k, num(l["protein_g"]) ?? 0, num(l["carbs_g"]) ?? 0, num(l["fat_g"]) ?? 0)
            ForEach((l["tips"] as? [String] ?? []), id: \.self) { t in Label(t, systemImage: "lightbulb.fill").font(.caption) }
            addButton("Add to \(meal.lowercased())", key: "lighter", turn: turn) {
                store.add(Assistant.basis(name: str(l["name"]), kcal: k, grams: nil, p: num(l["protein_g"]) ?? 0, c: num(l["carbs_g"]) ?? 0, f: num(l["fat_g"]) ?? 0), kcal: k, meal: meal)
            }
        }
    }

    /// A takeaway answer: the open combo with its lines (the dish, a shake, a dessert from home), one line saying where
    /// the numbers came from, and one button to add it; ✕ takes a line off (↺ puts it back), ⇄ swaps the dish for another
    /// from the menu, and when it's short of protein a shake from home is offered. The other combos are under it, a tap
    /// opening one instead.
    @ViewBuilder private func takeawayCard(_ ta: JSON, turn: UUID, meal: String) -> some View {
        let combos = list(ta["combos"]), at = min(openCombo[turn] ?? 0, max(0, combos.count - 1)), aim = num(ta["aim"]) ?? 0
        let place = str(ta["restaurant"]), key = "\(turn)-\(at)", edit = cardEdits[key] ?? CardEdit()
        if !combos.isEmpty {
            let c = Takeaway.edited(combos[at], off: edit.off, dish: edit.dish, tip: edit.tip, restaurant: place, kcal: num(ta["kcal"]) ?? 9999)
            panel {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !str(c["note"]).isEmpty { Text(str(c["note"]).uppercased()).font(.caption2.weight(.heavy)).foregroundStyle(Theme.accent) }
                        Text(str(c["title"])).font(.subheadline.weight(.bold))
                    }
                    Spacer()
                    comboTotal(c, aim: aim).font(.subheadline.weight(.bold))
                }
                ForEach(list(c["lines"]).indices, id: \.self) { i in
                    let l = list(c["lines"])[i], off = l["off"] as? Bool == true
                    HStack(spacing: 11) {
                        FoodDot(name: str(l["name"]), size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(str(l["name"])).font(.subheadline.weight(.semibold)).strikethrough(off)
                            if !str(l["detail"]).isEmpty { Text(str(l["detail"])).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 4)
                        (Text(Fmt.int(num(l["kcal"]) ?? 0)).bold().foregroundStyle(.primary) + Text(" · \(Int((num(l["p"]) ?? 0).rounded())) g"))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        // the dish: swap it for another from the menu, closest in size first
                        if i == 0, !list(combos[at]["swaps"]).isEmpty {
                            Menu {
                                ForEach(list(combos[at]["swaps"]).indices, id: \.self) { j in
                                    let s = list(combos[at]["swaps"])[j]
                                    Button("\(str(s["name"]))  ·  \(Fmt.int(num(s["kcal"]) ?? 0)) kcal, \(Int((num(s["p"]) ?? 0).rounded())) g") {
                                        withAnimation(.snappy) { var e = edit; e.dish = s; e.off.remove(0); cardEdits[key] = e }
                                    }
                                }
                            } label: { lineButton("arrow.left.arrow.right") }
                            .accessibilityLabel("Swap \(str(l["name"]))")
                        }
                        Button {
                            withAnimation(.snappy) { var e = edit; if off { e.off.remove(i) } else { e.off.insert(i) }; cardEdits[key] = e }
                        } label: { lineButton(off ? "arrow.uturn.backward" : "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(off ? "Put back \(str(l["name"]))" : "Take off \(str(l["name"]))")
                    }
                    .opacity(off ? 0.4 : 1)
                }
                // short of protein with nothing from home asked for: one shake offered, a tap puts it in
                if !edit.tip, let t = combos[at]["tip"] as? JSON {
                    Button { withAnimation(.snappy) { var e = edit; e.tip = true; cardEdits[key] = e } } label: {
                        HStack(spacing: 9) {
                            FoodDot(name: "Protein shake", size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(str(t["text"])).font(.caption.weight(.semibold)).multilineTextAlignment(.leading)
                                Text(str(t["more"])).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text("Add").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                        }
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
                if (num(c["over"]) ?? 0) > 10 {
                    Text("\(Fmt.int(num(c["over"]) ?? 0)) kcal over what's left today").font(.caption).foregroundStyle(Theme.warn)
                }
                // where the numbers came from, said once; amber when the dish's kJ wasn't found
                if !str(c["source"]).isEmpty {
                    Text(str(c["source"])).font(.caption).foregroundStyle(c["warn"] as? Bool == true ? Theme.warn : .secondary)
                }
                let count = Int(num(c["count"]) ?? 0), all = count == list(c["lines"]).count
                addButton(all ? "Add all to \(meal.lowercased())" : "Add \(count) to \(meal.lowercased())", key: "ta\(at)", turn: turn) {
                    let foods = list(c["lines"]).filter { $0["off"] as? Bool != true }.flatMap { list($0["add"]) }.map { a -> JSON in
                        let g = pos(a["grams"])
                        var b = Assistant.basis(name: str(a["name"]), kcal: num(a["kcal"]) ?? 0, grams: g, unit: str(a["unit"]).isEmpty ? "g" : str(a["unit"]),
                                                p: num(a["p"]) ?? 0, c: num(a["c"]) ?? 0, f: num(a["f"]) ?? 0)
                        b["kcal"] = num(a["kcal"]) ?? 0
                        if let g { b["grams"] = g }
                        return b
                    }
                    store.addAll(foods, meal: meal, label: "Added \(str(c["title"]))")
                }
            }
            ForEach(combos.indices.filter { $0 != at }, id: \.self) { i in
                let o = combos[i]
                Button { withAnimation(.snappy) { openCombo[turn] = i } } label: {
                    HStack(spacing: 10) {
                        // its foods' icons, overlapping a little, then its name
                        HStack(spacing: -6) { ForEach(list(o["lines"]).indices, id: \.self) { j in FoodDot(name: str(list(o["lines"])[j]["name"]), size: 22) } }
                        Text(str(o["title"])).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        Spacer()
                        comboTotal(o, aim: aim).font(.caption.weight(.bold))
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityHint("Shows this one")
            }
        }
    }

    /// Foods typed with their numbers ("protein shake 250 cal 40p"), read on the phone: shown with Add, so nothing goes
    /// on Today until they choose to. A tap on a food (or Change, for one) opens How much for it instead.
    @ViewBuilder private func quickCard(_ foods: [JSON], turn: UUID, meal: String) -> some View {
        let lines = foods.map { QuickLog.Line(name: str($0["name"]), kcal: num($0["kcal"]) ?? 0, p: num($0["p"]), c: num($0["c"]), f: num($0["f"])) }
        panel {
            ForEach(lines.indices, id: \.self) { i in
                let l = lines[i]
                Button { amount = EditTarget(basis: QuickLog.basis(l), kcal: l.kcal, editId: nil, meal: meal) } label: {
                    HStack(spacing: 11) {
                        FoodDot(name: l.name, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.name).font(.subheadline.weight(.semibold))
                            Text(([ "\(Fmt.int(l.kcal)) kcal"] + [l.p.map { "\(Fmt.int($0)) g protein" }, l.c.map { "\(Fmt.int($0)) g carbs" }, l.f.map { "\(Fmt.int($0)) g fat" }].compactMap { $0 }).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityHint("Change the amount")
            }
            HStack(spacing: 8) {
                addButton(lines.count == 1 ? "Add to \(meal.lowercased())" : lines.count == 2 ? "Add both to \(meal.lowercased())" : "Add all to \(meal.lowercased())", key: "quick", turn: turn) {
                    let ids = lines.map { store.add(QuickLog.basis($0), kcal: $0.kcal, meal: meal) }
                    if ids.count > 1 { store.undo = Store.Undo(ids: ids, label: "Added \(ids.count) foods", at: Date()) }
                }
                if lines.count == 1, let l = lines.first {
                    Button("Change") { amount = EditTarget(basis: QuickLog.basis(l), kcal: l.kcal, editId: nil, meal: meal) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
        }
    }

    /// Places found on the web: each with the dish that suits what's left, its numbers, and whether they're the place's
    /// own kJ or estimated. A tap plans that place like naming it (its name is sent).
    @ViewBuilder private func placesCard(_ pl: JSON) -> some View {
        let aim = num(pl["protein"]) ?? 0
        ForEach(list(pl["places"]).indices, id: \.self) { i in
            let p = list(pl["places"])[i], pr = num(p["protein_g"]) ?? 0, estimated = str(p["published"]) == "none"
            // Never drawn as switched off. They were while an answer was on its way, and stayed grey after it had
            // come until the chat was touched; a tap while it's still working is simply passed over.
            Button { if !busy { text = str(p["name"]); send() } } label: {
                HStack(spacing: 11) {
                    FoodDot(name: str(p["dish"]), size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(str(p["name"])).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        Text(str(p["dish"])).font(.caption.weight(.medium)).multilineTextAlignment(.leading)
                        Text([str(p["area"]), str(p["cuisine"])].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        (Text("\(Fmt.int(num(p["kcal"]) ?? 0)) · ") + Text("\(Int(pr.rounded())) g").foregroundStyle(pr >= aim - 0.5 ? Theme.walk : Theme.warn))
                            .font(.caption.weight(.bold)).monospacedDigit()
                        Text(estimated ? "estimated" : str(p["published"]) == "full" ? "their numbers" : "their kJ")
                            .font(.caption2).foregroundStyle(estimated ? Theme.warn : .secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Plan \(str(p["name"]))")
        }
    }

    /// What's been changed on a takeaway card: lines taken off, the dish swapped, the offered shake put in.
    struct CardEdit { var off: Set<Int> = []; var dish: JSON?; var tip = false }

    /// The small round ✕, ↺ and ⇄ on a takeaway card's lines.
    private func lineButton(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            .frame(width: 26, height: 26).background(Color(.tertiarySystemFill), in: Circle())
    }

    /// "851 kcal · 66 g", the protein green when it reaches the aim.
    private func comboTotal(_ c: JSON, aim: Double) -> Text {
        let p = num(c["p"]) ?? 0
        return Text("\(Fmt.int(num(c["kcal"]) ?? 0)) kcal · ") + Text("\(Int(p.rounded())) g").foregroundStyle(p >= aim - 0.5 ? Theme.walk : Theme.warn)
    }

    // MARK: composer

    /// One rounded box, like the Claude app's: waiting photos on top, the words under them (growing to 5 lines, then
    /// scrolling inside), and a row of buttons along the bottom: ＋ for a photo, the microphone, send.
    private var composer: some View {
        let empty = text.trimmingCharacters(in: .whitespaces).isEmpty && pending.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // each photo by itself, removed by itself: a quick double tap can't take the wrong one or run past the end;
                        // a tap on the photo opens it full screen before it's sent
                        ForEach(Array(pending.enumerated()), id: \.element) { i, img in
                            Button { viewing = Photos(images: pending, start: i) } label: {
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain).accessibilityLabel("Photo \(i + 1), full screen")
                            .overlay(alignment: .topTrailing) {
                                Button { pending.removeAll { $0 === img } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black) }
                                    .offset(x: 5, y: -5).accessibilityLabel("Remove photo \(i + 1)")
                            }
                        }
                    }
                    .padding(.top, 6).padding(.horizontal, 6)
                }
                .frame(height: 70)   // a set height: a sideways scroller takes whatever height it's offered
            }
            // return is a new line, shown as the plain return key: it said "send" but only went down a line
            TextField("Ask, or say what you ate", text: $text, axis: .vertical).lineLimit(1...5).focused($typing)
                .accessibilityIdentifier("chatBox")
                .padding(.horizontal, 8).padding(.top, 4)
            HStack(spacing: 8) {
                Menu {
                    Button { openPhotos(camera: true) } label: { Label("Take a photo", systemImage: "camera") }
                    Button { openPhotos(camera: false) } label: { Label("Choose photos", systemImage: "photo.on.rectangle") }
                } label: { roundButton("plus") }
                .accessibilityLabel("Add a photo")
                if speech.listening {
                    SpeechBars(level: speech.level).frame(maxWidth: .infinity)
                    Button { speech.stop() } label: {
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 13, height: 13).frame(width: 40, height: 40).background(Color.red, in: Circle())
                    }
                    .accessibilityLabel("Stop listening")
                } else {
                    Spacer()
                    Button { listen() } label: { roundButton("mic") }.accessibilityLabel("Speak")
                    Button { send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).frame(width: 40, height: 40)
                            .foregroundStyle(empty ? Theme.onAccent.opacity(0.45) : Theme.onAccent)
                            .background(Theme.accent.opacity(empty ? 0.4 : 1), in: Circle())
                    }
                    .disabled(busy || empty).accessibilityLabel("Send")
                }
            }
        }
        .padding(10)
        // its full height always (the photos and up to 5 lines): with a photo in, the chat above won the space and
        // the words were squashed to two lines under the photo
        .fixedSize(horizontal: false, vertical: true)
        // the whole box takes the tap (not just the line of text), so the keyboard comes up first time; behind the field,
        // so its own cursor and Paste menu still work
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { typing = true } }
        .composerGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .top) {
            if let p = speech.problem { Text(p).font(.caption).foregroundStyle(Theme.warn).padding(8).offset(y: -34) }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .composerBar()
        .onDisappear { speech.stop() }
    }

    /// The camera or the photo library, once the keyboard's down: opened while it was still sliding away, the first
    /// tap or two did nothing.
    private func openPhotos(camera cam: Bool) {
        let wasTyping = typing
        typing = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasTyping ? 0.35 : 0.05)) { if cam { camera = true } else { library = true } }
    }

    private func roundButton(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
            .frame(width: 40, height: 40).background(Color.white.opacity(0.1), in: Circle())
    }

    /// Speaking: what's said goes after what's already typed, and keeps updating until they stop.
    private func listen() {
        let before = text.trimmingCharacters(in: .whitespaces)
        Task { await speech.start { words in text = before.isEmpty ? words : before + " " + words } }
    }

    /// A photo at most 2048 pixels on its longest side (still enough to read a label), made off the main thread.
    static func shrunk(_ img: UIImage) async -> UIImage {
        await Task.detached(priority: .userInitiated) {
            let side = max(img.size.width, img.size.height)
            guard side > 2048 else { return img }
            let f = 2048 / side, size = CGSize(width: img.size.width * f, height: img.size.height * f)
            let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
            return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        }.value
    }

    /// The quick notes under a waiting photo; a tap adds the words to the box, another takes them out.
    static let notes = ["Homemade", "Shared", "Had half", "No sauce"]
    private func hasNote(_ n: String) -> Bool { text.range(of: n, options: .caseInsensitive) != nil }
    private func toggleNote(_ n: String) {
        if let r = text.range(of: n, options: .caseInsensitive) {
            text.removeSubrange(r)
            text = text.replacingOccurrences(of: ", ,", with: ",").trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        } else {
            let t = text.trimmingCharacters(in: .whitespaces)
            text = t.isEmpty ? n : "\(t), \(n.lowercased())"
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for i in items { if let d = try? await i.loadTransferable(type: Data.self), let img = UIImage(data: d) { pending.append(await Self.shrunk(img)) } }
        picked = []
    }

    private func send() {
        speech.stop()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !t.isEmpty || !pending.isEmpty else { return }
        // foods with their numbers typed in: read here, no waiting for the AI, and shown with Add (nothing goes on Today
        // until they tap it). Not in the middle of a conversation: after asking about 918 g of chicken, "Want around
        // 60g protein from it" means a portion of that chicken, so it goes to the AI with the chat. After one of these
        // cards it still reads the next one, so several can be typed in a row
        let talking = turns.last.map { !$0.me && $0.result != nil && str($0.result?["kind"]) != "quick" } ?? false
        if pending.isEmpty, !talking, let lines = QuickLog.instant(t) {
            turns.append(Assistant.Turn(me: true, text: t))
            let foods: [JSON] = lines.map { ["name": $0.name, "kcal": $0.kcal, "p": $0.p ?? NSNull(), "c": $0.c ?? NSNull(), "f": $0.f ?? NSNull()] }
            let reply = lines.count == 1 ? "Here's what I read. Add it, or tell me if it's not right." : "Here's what I read. Add them, or tell me if they're not right."
            withAnimation(.snappy) { turns.append(Assistant.Turn(me: false, text: reply, result: ["kind": "quick", "meal": meal, "foods": foods])) }
            text = ""; problem = nil
            live.keep(store); keptKey = cardsKey
            return
        }
        let photos = pending.count
        turns.append(Assistant.Turn(me: true, text: t.isEmpty ? "What's this?" : t, images: pending))
        text = ""; pending = []; problem = nil; busy = true
        // what it's doing, ticked off as it goes. The careful model's own work is one request, so its two steps are paced
        // by time (sizing first, then the parts); reading, spotting and the checks are real
        stepsDone = [photos > 0 ? "Read your message and \(photos) photo\(photos == 1 ? "" : "s")" : "Read your message"]
        stepNow = photos > 0 ? "Looking at what's in the photos…" : "Working it out…"
        let store = self.store, live = self.live
        Task {
            defer { live.busy = false; live.used = Date() }
            do {
                // the answer shows as soon as it's back; an estimate's parts are checked against the food database after
                let r = try await Assistant.ask(live.turns, store: store, ground: false) { seen in
                    stepsDone.append("Spotted \(seen.foods.prefix(4).joined(separator: ", "))\(seen.shop.isEmpty ? "" : " from \(seen.shop)")")
                    stepNow = "Sizing each food against what's around it…"
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        if busy, stepNow.hasPrefix("Sizing") { stepsDone.append("Sized each food"); stepNow = "Working out each part…" }
                    }
                } step: { did, now in stepsDone.append(did); stepNow = now }
                let turn = Assistant.Turn(me: false, text: str(r["reply"]), result: r)
                withAnimation(.snappy) { turns.append(turn) }
                busy = false   // the answer's in; the checks after it show on the card, not as "working"
                if str(r["kind"]) == "estimate", r["scaled"] == nil, let e = r["estimate"] as? JSON {
                    // what a follow-up didn't change keeps the numbers the last card had
                    let before = turns.last { !$0.me && $0.id != turn.id && $0.result?["estimate"] != nil }?.result?["estimate"] as? JSON
                    // and a food already worked out in this chat, under another name or amount, keeps those numbers too
                    let cards = turns.filter { !$0.me && $0.id != turn.id }.compactMap { $0.result?["estimate"] as? JSON }
                    let checked = Assistant.steady(Assistant.keepingEarlier(await Assistant.ground(Assistant.unfolded(e, earlier: cards)), before), earlier: cards)
                    // the parts no food table had (the sparkle): kept, so the tables can be filled where they're used
                    let gaps = CheatDays.list(checked["parts"]).filter { str($0["src"]) == "ai" }.map { str($0["name"]) }
                    if !gaps.isEmpty { store.perform(["type": "gaps", "names": gaps, "at": ISO.now()]) }
                    if let i = turns.firstIndex(where: { $0.id == turn.id }), var res = turns[i].result {
                        res["estimate"] = checked
                        withAnimation { turns[i].result = res }
                    }
                    // then the shop's own published numbers, if it has any: only over a card nobody has changed yet
                    let shop = await Assistant.fromShop(checked)
                    if let i = turns.firstIndex(where: { $0.id == turn.id }), var res = turns[i].result {
                        let untouched = dict(res["estimate"])["aiPortion"] == nil && !done[turn.id, default: ""].contains("est")
                        if let shop, untouched { res["estimate"] = shop }
                        res["trail"] = Assistant.trail(dict(res["estimate"]), shopFound: shop != nil && untouched)
                        withAnimation { turns[i].result = res }
                    }
                }
                live.keep(store); keptKey = cardsKey
            } catch { problem = error.localizedDescription }
        }
    }
}

/// Past chats: open one to carry on, swipe to delete.
struct ChatsList: View {
    var open: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            List {
                let chats = list(store.doc["chats"])
                if chats.isEmpty { Text("No chats yet.").foregroundStyle(.secondary) }
                ForEach(keyed(chats)) { entry in
                    let c = entry.item
                    Button { open(c) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(str(c["title"])).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(ISO.date(str(c["when"]))?.formatted(date: .abbreviated, time: .shortened) ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions { Button(role: .destructive) { store.perform(["type": "deleteChat", "id": str(c["id"]), "at": nowMs()]) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
            .navigationTitle("Past chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct Photos: Identifiable { let id = UUID(); let images: [UIImage]; let start: Int }

/// One part of one turn's estimate, for Change.
private struct PartRef: Identifiable { let id = UUID(); let turn: UUID; let index: Int; let part: JSON }

/// Change: the entry a part was counted as, and the closest others of its kind, per 100 g.
private struct MatchPicker: View {
    let ref: PartRef
    let pick: (FoodTable.Food) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let options = FoodTable.current.alternatives(str(ref.part["name"]), tags: Assistant.tags(ref.part), matched: str(ref.part["match"]))
        NavigationStack {
            List {
                Section {
                    ForEach(options, id: \.name) { f in
                        Button { pick(f) } label: {
                            HStack {
                                if f.name == str(ref.part["match"]) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                Text(f.name).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Spacer()
                                Text("\(Fmt.int(f.kcal)) kcal").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("\(str(ref.part["name"])) · \(Fmt.int(num(ref.part["grams"]) ?? 0)) g") }
                  footer: { Text("Per 100 g, from the food table for \(Plan.country). Picking one redoes this part's numbers.") }
            }
            .navigationTitle("Which is it closest to?").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// − | value | + in one 40 pt control, the same as the Add button beside it: the plate's percentage, or a part's grams.
private struct SizeStepper<V: View>: View {
    let less: () -> Void
    let more: () -> Void
    @ViewBuilder let value: V
    var body: some View {
        HStack(spacing: 0) {
            step("minus", "Smaller", less)
            Divider().frame(height: 18)
            value.font(.subheadline.weight(.bold)).monospacedDigit().padding(.horizontal, 10).frame(minWidth: 56)
            Divider().frame(height: 18)
            step("plus", "Bigger", more)
        }
        .frame(height: AssistantView.control)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func step(_ icon: String, _ name: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: icon).font(.subheadline.weight(.semibold)).frame(width: 40, height: AssistantView.control).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.primary).accessibilityLabel(name)
    }
}

extension SizeStepper where V == Text {
    init(value: String, less: @escaping () -> Void, more: @escaping () -> Void) {
        self.init(less: less, more: more) { Text(value) }
    }
}

/// The number in the middle of a − | + control, to type over (a part's grams, the plate's percentage): it looks like a
/// box so it reads as typeable, and saves when the keyboard goes (a tap on the chat).
private struct NumberBox: View {
    let value: Double
    let unit: String
    let save: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 1) {
            TextField("–", text: $text).keyboardType(.numberPad).focused($focused).multilineTextAlignment(.trailing).fixedSize()
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.bold)).monospacedDigit()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(focused ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { if focused { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5) } }
        .contentShape(Rectangle()).onTapGesture { focused = true }
        .onAppear { text = Fmt.int(value) }
        .onChange(of: value) { _, v in if !focused { text = Fmt.int(v) } }
        .onChange(of: focused) { _, on in if !on, let v = Fmt.typed(text), v > 0 { save(v) } else if !on { text = Fmt.int(value) } }
    }
}

/// A chat photo tapped: full screen on black, swipe between them, pinch or double-tap to zoom, swipe down or ✕ to close.
private struct PhotoViewer: View {
    let photos: Photos
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var zoomed = false   // the photo showing is bigger than the screen (told when a pinch ends, not during)
    @State private var drop: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(1 - min(abs(drop) / 400, 0.6)).ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(photos.images.indices, id: \.self) { i in
                    ZoomablePhoto(image: photos.images[i], showing: i == page, zoomed: $zoomed).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.images.count > 1 ? .automatic : .never))
            .offset(y: drop)
            // swipe down to close, only when not zoomed in
            .simultaneousGesture(DragGesture().onChanged { v in if !zoomed, abs(v.translation.height) > abs(v.translation.width) { drop = v.translation.height } }
                .onEnded { _ in if drop > 120 { dismiss() } else { withAnimation(.spring) { drop = 0 } } })
            .onChange(of: page) { _, _ in zoomed = false }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .accessibilityLabel("Close photo")
        }
        .onAppear { page = photos.start }
        .statusBarHidden()
    }
}

/// One photo in the viewer, with its own zoom. The pinch is this view's alone: kept by the viewer, every move of the
/// fingers redrew the whole pager and each photo in it, and the app dragged.
private struct ZoomablePhoto: View {
    let image: UIImage
    var showing: Bool
    @Binding var zoomed: Bool
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .scaleEffect(min(max(zoom * pinch, 0.8), 5))
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            .gesture(MagnifyGesture().updating($pinch) { m, state, _ in state = m.magnification }
                .onEnded { m in
                    withAnimation(.snappy(duration: 0.2)) { zoom = min(max(zoom * m.magnification, 1), 4) }
                    zoomed = zoom > 1.01
                })
            .onTapGesture(count: 2) { withAnimation(.spring) { zoom = zoom > 1 ? 1 : 2.5 }; zoomed = zoom > 1.01 }
            .onChange(of: showing) { _, on in if !on { zoom = 1 } }
    }
}

/// The chat box (the assistant's and Plan a meal's): on iOS 26 it floats in the same glass as the keyboard; before that, a material bar.
extension View {
    @ViewBuilder func composerGlass(_ shape: some Shape) -> some View {
        if #available(iOS 26, *) { glassEffect(.regular, in: shape) }
        else { background(Color(.secondarySystemBackground), in: shape) }
    }
    @ViewBuilder func composerBar() -> some View {
        if #available(iOS 26, *) { self } else { background(.regularMaterial) }
    }
}
