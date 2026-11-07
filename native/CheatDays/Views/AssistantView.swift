import PhotosUI
import SwiftUI

/// The assistant: a chat that can log a plate from a photo or words, plan the rest of the day, fix today's list,
/// write a recipe to save as a meal, or find a lighter version. Chats are kept, without photos.
struct AssistantView: View {
    let meal: String
    var firstQuestion = ""
    @Environment(\.dismiss) private var dismiss
    private var live: AssistantLive { AssistantLive.shared }
    private var turns: [Assistant.Turn] { get { live.turns } nonmutating set { live.turns = newValue } }
    private var chatId: String { get { live.chatId } nonmutating set { live.chatId = newValue } }
    private var busy: Bool { get { live.busy } nonmutating set { live.busy = newValue } }
    private var problem: String? { get { live.problem } nonmutating set { live.problem = newValue } }
    @State private var text = ""
    @State private var pending: [UIImage] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var camera = false
    @State private var library = false
    @State private var done: [UUID: String] = [:]
    @State private var showChats = false
    @State private var viewing: Photos?
    @State private var openPart: String?   // the estimate part showing its details ("turn-index")
    @State private var stepsDone: [String] = []   // what the AI has done so far for this message, ticked
    @State private var stepNow = "Thinking…"
    @State private var changing: PartRef?
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }

    private let chips = ["What fits the rest of today?", "Make today healthier", "Healthier swaps for what I eat most", "A recipe under 600 kcal"]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
              VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        bot(Text("**Ask me anything about your day.** Photograph a plate and tell me what it is, ask for a plan for the rest of today, a recipe that fits, a lighter version of something, or tell me what you actually ate and I'll fix the list."))
                        if turns.isEmpty {
                            HStack(spacing: 10) {
                                Button { camera = true } label: { Label("Snap a plate", systemImage: "camera.fill").lineLimit(1).frame(maxWidth: .infinity) }
                                Button { library = true } label: { Label("Photos", systemImage: "photo.on.rectangle").lineLimit(1).frame(maxWidth: .infinity) }
                            }
                            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)).controlSize(.large)
                            Flow { ForEach(chips, id: \.self) { c in Chip(text: c, on: false) { text = c; send() } } }
                        }
                        ForEach(turns) { t in turnView(t).id(t.id) }
                        if busy { bot(progress).id("busy") }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 4) }
                    }
                    .padding(16)
                }
                .contentShape(Rectangle())   // the empty space counts too, not just the bubbles
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
                        Button { turns = []; chatId = uid(); done = [:] } label: { Label("New chat", systemImage: "square.and.pencil") }
                        Button { showChats = true } label: { Label("Past chats", systemImage: "clock.arrow.circlepath") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showChats) { ChatsList { c in turns = Assistant.turns(from: c); chatId = str(c["id"]); done = [:]; showChats = false } }
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { pending.append(img) } }.ignoresSafeArea() }
            .fullScreenCover(item: $viewing) { PhotoViewer(photos: $0) }
            .sheet(item: $changing) { ref in MatchPicker(ref: ref) { food in setMatch(ref, to: food); changing = nil }.presentationDetents([.medium]) }
            .photosPicker(isPresented: $library, selection: $picked, maxSelectionCount: 4, matching: .images)
            .onChange(of: picked) { _, items in if !items.isEmpty { Task { await load(items) } } }
            .onChange(of: showChats) { _, open in KeyboardDone.quiet = !open }   // past chats keep their Done
            .onDisappear { KeyboardDone.quiet = false }
            .onAppear {
                KeyboardDone.quiet = true   // a chat box: the send button's right there, and scrolling or tapping away closes it
                live.open(fresh: !firstQuestion.isEmpty)
                if !firstQuestion.isEmpty && turns.isEmpty { text = firstQuestion; send() }
            }
        }
    }

    // MARK: bubbles

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
                bot(VStack(alignment: .leading, spacing: 8) { Text(t.text); trailLines(t.result?["trail"] as? [String] ?? []) })
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
            if let e = r["estimate"] as? JSON { estimateCard(e, turn: turn, meal: meal) }
        case "plan":
            if let p = r["plan"] as? JSON { planCard(p, turn: turn, meal: str(r["meal"]).isEmpty ? Meals.now : meal) }
        case "edit":
            if let e = r["edit"] as? JSON { editCard(e, turn: turn, meal: meal) }
        case "recipe":
            if let rc = r["recipe"] as? JSON { recipeCard(rc, turn: turn, meal: meal) }
        case "lighter":
            if let l = r["lighter"] as? JSON { lighterCard(l, turn: turn, meal: meal) }
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
            let parts = list(e["parts"]), checked = parts.filter { !["", "ai", "label", "them", "web"].contains(str($0["src"])) }.count
            let own = parts.filter { ["label", "them"].contains(str($0["src"])) }.count
            let web = parts.first { str($0["src"]) == "web" }
            ForEach(keyed(parts)) { entry in
                let i = entry.index, pt = entry.item, ok = !["", "ai"].contains(str(pt["src"])), key = "\(turn)-\(i)"
                Button { withAnimation(.snappy) { openPart = openPart == key ? nil : key } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: ok ? "checkmark.seal.fill" : "sparkles").font(.caption2).foregroundStyle(ok ? Color.green : .secondary)
                        Text(str(pt["name"])).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.leading)
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
                let picked = str(e["sizeAnswer"])
                VStack(alignment: .leading, spacing: 6) {
                    Text("How big was it?").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(["Small", "Regular", "Large"], id: \.self) { name in
                            let on = picked == name
                            Button { answerSize(turn, name) } label: {
                                Text(name).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: Self.control)
                                    .foregroundStyle(on ? Theme.onAccent : .primary)
                                    .background(on ? Theme.accent : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                // one clear Add, the full width left over; every control on the card 40 pt tall with the same corners
                Button {
                    var b = Assistant.basis(name: str(e["name"]), kcal: k, grams: num(e["portion_g"]), unit: str(e["unit"]).isEmpty ? "g" : str(e["unit"]), p: p, c: c, f: f)
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
                    SizeStepper(value: "\(Int(((num(e["portion_g"]) ?? start) / start * 100).rounded()))%",
                                less: { scale(turn, by: 0.75) }, more: { scale(turn, by: 1.3) })
                }
            }
        }
    }

    /// Every button on the estimate card is this tall, with 12 pt corners.
    static let control: CGFloat = 40

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
                SizeStepper(less: { setGrams(turn, index: i, to: g * 0.75) }, more: { setGrams(turn, index: i, to: g * 1.3) }) {
                    PartGrams(grams: g) { setGrams(turn, index: i, to: $0) }
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

    private func editCard(_ edit: JSON, turn: UUID, meal: String) -> some View {
        let acts = list(edit["actions"])
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
            Text("\(Fmt.one(portions)) portion\(portions == 1 ? "" : "s") · per portion:").font(.caption).foregroundStyle(.secondary)
            macros(total / portions, p / portions, c / portions, f / portions)
            ForEach(ings.indices, id: \.self) { i in
                HStack { Text(str(ings[i]["name"])).font(.caption); Spacer(); Text("\(Int(num(ings[i]["grams"]) ?? 0)) g · \(Int(num(ings[i]["kcal"]) ?? 0))").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            }
            let steps = rc["steps"] as? [String] ?? []
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) { ForEach(steps.indices, id: \.self) { i in Text("\(i + 1). \(steps[i])").font(.caption) } }.padding(.top, 4)
            }
            HStack {
                addButton("Save as a meal", key: "save", turn: turn) {
                    store.perform(["type": "saveMeal", "meal": ["id": uid(), "name": str(rc["name"]), "portions": portions, "items": items, "steps": steps, "saved": true, "updatedAt": ISO.now()] as JSON])
                }
                addButton("Add a portion", key: "portion", turn: turn) {
                    store.add(Assistant.basis(name: str(rc["name"]), kcal: total / portions, grams: nil, p: p / portions, c: c / portions, f: f / portions), kcal: total / portions, meal: meal)
                }
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

    // MARK: composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        // each photo by itself, removed by itself: a quick double tap can't take the wrong one or run past the end
                        ForEach(pending, id: \.self) { img in
                            Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) { Button { pending.removeAll { $0 === img } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black) }.offset(x: 5, y: -5) }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            HStack(spacing: 10) {
                Menu {
                    Button { camera = true } label: { Label("Take a photo", systemImage: "camera") }
                    Button { library = true } label: { Label("Choose photos", systemImage: "photo.on.rectangle") }
                } label: { Image(systemName: "camera.fill").font(.title3).foregroundStyle(Theme.accent).frame(width: 44, height: 44).composerGlass(Circle()) }
                // the whole box takes the tap (not just the line of text), so the keyboard and Paste come up first time
                TextField("Ask, or say what you ate", text: $text, axis: .vertical).lineLimit(1...5).focused($typing)
                    .accessibilityIdentifier("chatBox")
                    .submitLabel(.send).onSubmit { send() }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { typing = true } }   // behind the field, so its own cursor and Paste menu still work
                    .composerGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 38)).foregroundStyle(Theme.accent) }
                    .disabled(busy || (text.trimmingCharacters(in: .whitespaces).isEmpty && pending.isEmpty))
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .composerBar()
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for i in items { if let d = try? await i.loadTransferable(type: Data.self), let img = UIImage(data: d) { pending.append(img) } }
        picked = []
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !t.isEmpty || !pending.isEmpty else { return }
        // foods with their numbers typed in: logged straight away, no waiting for the AI
        if pending.isEmpty, let lines = QuickLog.instant(t) {
            let ids = lines.map { store.add(QuickLog.basis($0), kcal: $0.kcal, meal: meal) }
            if ids.count > 1 { store.undo = Store.Undo(ids: ids, label: "Added \(ids.count) foods", at: Date()) }
            turns.append(Assistant.Turn(me: true, text: t))
            let list = lines.map(QuickLog.summary).joined(separator: "\n")
            withAnimation(.snappy) { turns.append(Assistant.Turn(me: false, text: "Logged to \(meal.lowercased()):\n\(list)\nSwipe it on Today to change or delete.")) }
            text = ""; problem = nil
            store.perform(["type": "chat", "chat": Assistant.record(id: chatId, turns: turns)], syncAfter: 3)
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
                }
                let turn = Assistant.Turn(me: false, text: str(r["reply"]), result: r)
                withAnimation(.snappy) { turns.append(turn) }
                if str(r["kind"]) == "estimate", let e = r["estimate"] as? JSON {
                    busy = false
                    let checked = await Assistant.ground(e)
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
                store.perform(["type": "chat", "chat": Assistant.record(id: chatId, turns: turns)], syncAfter: 3)
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

/// A part's grams to type over; saved when the box loses focus or Done is tapped.
private struct PartGrams: View {
    let grams: Double
    let save: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 2) {
            TextField("–", text: $text).keyboardType(.numberPad).focused($focused).multilineTextAlignment(.trailing).fixedSize()
            Text("g").foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.bold)).monospacedDigit()
        .contentShape(Rectangle()).onTapGesture { focused = true }
            .onAppear { text = Fmt.int(grams) }
            .onChange(of: grams) { _, g in if !focused { text = Fmt.int(g) } }
            .onChange(of: focused) { _, on in if !on, let g = Fmt.typed(text) { save(g) } }
    }
}

/// A chat photo tapped: full screen on black, swipe between them, pinch or double-tap to zoom, swipe down or ✕ to close.
private struct PhotoViewer: View {
    let photos: Photos
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var drop: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(1 - min(abs(drop) / 400, 0.6)).ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(photos.images.indices, id: \.self) { i in
                    Image(uiImage: photos.images[i]).resizable().scaledToFit()
                        .scaleEffect(i == page ? zoom * pinch : 1)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.images.count > 1 ? .automatic : .never))
            .offset(y: drop)
            .gesture(MagnifyGesture().onChanged { pinch = $0.magnification }
                .onEnded { _ in zoom = min(max(zoom * pinch, 1), 4); pinch = 1 })
            .onTapGesture(count: 2) { withAnimation(.spring) { zoom = zoom > 1 ? 1 : 2.5 } }
            // swipe down to close, only when not zoomed in
            .simultaneousGesture(DragGesture().onChanged { v in if zoom == 1, abs(v.translation.height) > abs(v.translation.width) { drop = v.translation.height } }
                .onEnded { _ in if drop > 120 { dismiss() } else { withAnimation(.spring) { drop = 0 } } })
            .onChange(of: page) { _, _ in zoom = 1 }
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

/// The chat box: on iOS 26 it floats in the same glass as the keyboard; before that, a material bar.
private extension View {
    @ViewBuilder func composerGlass(_ shape: some Shape) -> some View {
        if #available(iOS 26, *) { glassEffect(.regular.interactive(), in: shape) }
        else { background(Color(.secondarySystemBackground), in: shape) }
    }
    @ViewBuilder func composerBar() -> some View {
        if #available(iOS 26, *) { self } else { background(.regularMaterial) }
    }
}
