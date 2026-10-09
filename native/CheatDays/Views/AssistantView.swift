import PhotosUI
import SwiftUI

/// The assistant: a chat that can log a plate from a photo or words, plan the rest of the day, fix today's list,
/// write a recipe to save as a meal, or find a lighter version. Chats are kept, without photos.
struct AssistantView: View {
    let meal: String
    var firstQuestion = ""
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [Assistant.Turn] = []
    @State private var chatId = uid()
    @State private var text = ""
    @State private var pending: [UIImage] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var camera = false
    @State private var busy = false
    @State private var problem: String?
    @State private var done: [UUID: String] = [:]
    @State private var showChats = false
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }

    private let chips = ["What fits the rest of today?", "A recipe under 600 kcal", "Make my favourite takeaway lighter", "I only had half of that"]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        bot(Text("**Ask me anything about your day.** Photograph a plate and tell me what it is, ask for a plan for the rest of today, a recipe that fits, a lighter version of something, or tell me what you actually ate and I'll fix the list."))
                        if turns.isEmpty {
                            Flow { ForEach(chips, id: \.self) { c in Chip(text: c, on: false) { text = c; send() } } }
                        }
                        ForEach(turns) { t in turnView(t).id(t.id) }
                        if busy { bot(HStack(spacing: 8) { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }).id("busy") }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 4) }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) } }
                .onChange(of: busy) { _, b in if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Assistant")
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
            .onChange(of: picked) { _, items in Task { await load(items) } }
            .onAppear { if !firstQuestion.isEmpty && turns.isEmpty { text = firstQuestion; send() } }
        }
    }

    // MARK: bubbles

    private func bot<C: View>(_ content: C) -> some View {
        content.font(.subheadline).padding(12)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func turnView(_ t: Assistant.Turn) -> some View {
        if t.me {
            VStack(alignment: .trailing, spacing: 6) {
                if !t.images.isEmpty {
                    HStack { ForEach(t.images.indices, id: \.self) { i in Image(uiImage: t.images[i]).resizable().scaledToFill().frame(width: 70, height: 70).clipShape(RoundedRectangle(cornerRadius: 12)) } }
                }
                Text(t.text).font(.subheadline).padding(12).foregroundStyle(.black)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                bot(Text(t.text))
                if let r = t.result { card(r, turn: t.id) }
            }
        }
    }

    @ViewBuilder private func card(_ r: JSON, turn: UUID) -> some View {
        switch str(r["kind"]) {
        case "estimate":
            if let e = r["estimate"] as? JSON { estimateCard(e, turn: turn) }
        case "plan":
            if let p = r["plan"] as? JSON { planCard(p, turn: turn) }
        case "edit":
            if let e = r["edit"] as? JSON { editCard(e, turn: turn) }
        case "recipe":
            if let rc = r["recipe"] as? JSON { recipeCard(rc, turn: turn) }
        case "lighter":
            if let l = r["lighter"] as? JSON { lighterCard(l, turn: turn) }
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
        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(.black)
        .disabled(done[turn, default: ""].contains(tag))
    }

    private func estimateCard(_ e: JSON, turn: UUID) -> some View {
        let k = num(e["kcal_total"]) ?? 0, p = num(e["protein_g"]) ?? 0, c = num(e["carbs_g"]) ?? 0, f = num(e["fat_g"]) ?? 0
        return panel {
            Text(str(e["name"])).font(.headline)
            Text("\(Fmt.int(num(e["portion_g"]) ?? 0)) \(str(e["unit"]).isEmpty ? "g" : str(e["unit"]))").font(.caption).foregroundStyle(.secondary)
            macros(k, p, c, f)
            let parts = list(e["parts"]), checked = parts.filter { ["list", "usda"].contains(str($0["src"])) }.count
            ForEach(parts.indices, id: \.self) { i in
                let pt = parts[i], ok = ["list", "usda"].contains(str(pt["src"]))
                HStack(spacing: 6) {
                    Image(systemName: ok ? "checkmark.seal.fill" : "sparkles").font(.caption2).foregroundStyle(ok ? Color.green : .secondary)
                    Text(str(pt["name"])).font(.caption)
                    Spacer()
                    Text("\(Int(num(pt["grams"]) ?? 0)) g · \(Int(num(pt["kcal"]) ?? 0))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(checked > 0 ? "\(checked) of \(parts.count) parts checked against food databases\(num(e["aiKcal"]).map { " (the AI first said \(Int($0)) kcal)" } ?? ""). An estimate, not a label."
                             : "The AI's estimate: none of the parts could be checked against a food database.")
                .font(.caption2).foregroundStyle(.secondary)
            addButton("Add to \(meal.lowercased())", key: "est", turn: turn) {
                store.add(Assistant.basis(name: str(e["name"]), kcal: k, grams: num(e["portion_g"]), unit: str(e["unit"]).isEmpty ? "g" : str(e["unit"]), p: p, c: c, f: f), kcal: k, meal: meal)
            }
        }
    }

    private func planCard(_ plan: JSON, turn: UUID) -> some View {
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
                        store.add(Assistant.basis(name: str(s["name"]), kcal: k, grams: nil, p: num(s["protein_g"]) ?? 0, c: num(s["carbs_g"]) ?? 0, f: num(s["fat_g"]) ?? 0), kcal: k, meal: Meals.now)
                    }
                }
                if i < list(plan["suggestions"]).count - 1 { Divider() }
            }
        }
    }

    private func editCard(_ edit: JSON, turn: UUID) -> some View {
        let acts = list(edit["actions"])
        return panel {
            ForEach(acts.indices, id: \.self) { i in
                let a = acts[i]
                Label(describe(a), systemImage: ["add": "plus.circle", "remove": "minus.circle", "update": "pencil.circle", "workout": "figure.walk"][str(a["action"])] ?? "circle")
                    .font(.subheadline)
            }
            let key = "edit"
            Button {
                let result = Assistant.apply(edit, meal: meal, store: store)
                withAnimation { done[turn, default: ""] += "|\(turn)-\(key)|" + result.joined(separator: ". ") }
            } label: {
                Label(done[turn, default: ""].contains("\(turn)-\(key)") ? "Done" : "Make these changes", systemImage: done[turn, default: ""].contains("\(turn)-\(key)") ? "checkmark" : "checkmark.circle.fill").font(.subheadline.weight(.bold))
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(.black)
            .disabled(done[turn, default: ""].contains("\(turn)-\(key)"))
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

    private func recipeCard(_ rc: JSON, turn: UUID) -> some View {
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

    private func lighterCard(_ l: JSON, turn: UUID) -> some View {
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
                        ForEach(pending.indices, id: \.self) { i in
                            Image(uiImage: pending[i]).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) { Button { pending.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black) }.offset(x: 5, y: -5) }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            HStack(spacing: 10) {
                Menu {
                    Button { camera = true } label: { Label("Take a photo", systemImage: "camera") }
                    PhotosPicker(selection: $picked, maxSelectionCount: 4, matching: .images) { Label("Choose photos", systemImage: "photo.on.rectangle") }
                } label: { Image(systemName: "camera.fill").font(.title3).foregroundStyle(Theme.accent).frame(width: 38, height: 38).background(Theme.hero, in: Circle()) }
                TextField("Ask, or say what you ate", text: $text, axis: .vertical).lineLimit(1...4).focused($typing)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .submitLabel(.send).onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.accent) }
                    .disabled(busy || (text.trimmingCharacters(in: .whitespaces).isEmpty && pending.isEmpty))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for i in items { if let d = try? await i.loadTransferable(type: Data.self), let img = UIImage(data: d) { pending.append(img) } }
        picked = []
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !t.isEmpty || !pending.isEmpty else { return }
        turns.append(Assistant.Turn(me: true, text: t.isEmpty ? "What's this?" : t, images: pending))
        text = ""; pending = []; problem = nil; busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await Assistant.ask(turns, store: store)
                withAnimation(.snappy) { turns.append(Assistant.Turn(me: false, text: str(r["reply"]), result: r)) }
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
                ForEach(chats.indices, id: \.self) { i in
                    let c = chats[i]
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
