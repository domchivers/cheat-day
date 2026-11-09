import SwiftUI

/// A pop-up on Today (MealPop): the morning, before lunch or dinner, or after one. Plan a meal's look: cards, the meal's
/// numbers with an example that changes every few seconds, cooking time as one button, and the assistant's chat box.
/// Before a meal, what's typed goes to Plan a meal for ideas; after one, to the assistant. Turned off in Settings.
struct MealPopSheet: View {
    enum Route { case plan(meal: String, text: String, cooking: String), ask(meal: String, text: String, camera: Bool) }
    let pop: MealPop
    var go: (Route) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var cooking = ""
    @State private var exampleAt = 0
    @State private var open: IdeaRef?
    @State private var added: Set<String> = []
    @State private var speech = Speech()
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }

    private static let cookChoices = ["No cooking", "Quick, 15 min", "Happy to cook"]
    private var planning: Bool { pop.kind != .after }
    /// After lunch the chat's about dinner; after dinner, the evening.
    private var nextMeal: String { pop.kind != .after ? pop.meal : pop.meal == "Lunch" ? "Dinner" : "Snacks" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(pop.title).font(.largeTitle.bold())
                        if let meta = pop.meta { Text(meta).font(.subheadline).foregroundStyle(.secondary).padding(.top, -6) }
                        if !pop.stats.isEmpty { stats.padding(.top, 2) }
                        ForEach(pop.parts.indices, id: \.self) { i in part(pop.parts[i]) }
                        if planning {
                            Eyebrow(text: pop.meal, color: Theme.heroLabel).padding(.top, 4)
                            intro
                        }
                        ForEach(pop.ideas.indices, id: \.self) { i in idea(pop.ideas[i]) }
                        Text("You can turn these off in Settings.").font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
                composer
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(planning ? "Close" : "Got it") { dismiss() }.fontWeight(.semibold) } }
            // a chat box: no Done bar (the send button's right there); a recipe keeps its own
            .sheet(item: $open, onDismiss: { KeyboardDone.quiet = true }) { r in RecipeSheet(idea: r.idea) }
            .onChange(of: open == nil) { _, none in if !none { KeyboardDone.quiet = false } }
            .onAppear {
                KeyboardDone.quiet = true
                if cooking.isEmpty {
                    switch str(store.habits["cook"]) { case "love": cooking = Self.cookChoices[2]; case "hate": cooking = Self.cookChoices[0]; default: cooking = Self.cookChoices[1] }
                }
            }
            .onDisappear { speech.stop(); KeyboardDone.quiet = false }
        }
    }

    private func color(_ t: MealPop.Tone) -> Color {
        switch t { case .good: return Theme.walk; case .warn: return Theme.warn; case .accent: return Theme.heroLabel; case .plain: return .primary }
    }

    /// Protein, the meal against its size, and what's left today.
    private var stats: some View {
        HStack(spacing: 8) {
            ForEach(pop.stats.indices, id: \.self) { i in
                let s = pop.stats[i]
                VStack(spacing: 2) {
                    Text(s.value).font(.title3.bold()).foregroundStyle(color(s.tone)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(s.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    /// A heading and its lines in one card.
    private func part(_ p: MealPop.Part) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(text: p.title, color: color(p.tone)).padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(p.lines.indices, id: \.self) { i in
                    if i > 0 { Divider().opacity(0.5) }
                    HStack(alignment: .top, spacing: 12) {
                        FluentIcon(emoji: p.lines[i].icon, size: 24)
                        Text(p.lines[i].text).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var examples: [String] {
        let style = (store.habits["cuisines"] as? [String])?.first.map { ", \($0) style" } ?? ""
        return pop.meal == "Breakfast" ? ["Something high protein, ready in 10 minutes.", "Something high protein\(style)."]
            : ["Something high protein\(style).", "Any healthy \(pop.meal.lowercased()) spots near me?"]
    }

    /// The meal's numbers and how to ask, as Plan a meal starts.
    private var intro: some View {
        let t = store.mealTarget(pop.meal), protein = ((t.protein ?? 25) / 5).rounded() * 5
        let left = pop.kind == .morning ? " (\(Fmt.int(max(0, store.budgetToday - store.eaten))) left today)" : ""
        return VStack(alignment: .leading, spacing: 8) {
            Text("About \(Fmt.int(t.kcal)) kcal and \(Int(protein)) g protein").bold() + Text("\(left). What do you fancy?")
            // all laid out at once, so the card keeps the tallest one's height as they fade
            let all = examples, at = exampleAt % all.count
            ZStack(alignment: .topLeading) {
                ForEach(all.indices, id: \.self) { i in
                    Text("For example: “\(all[i])”").italic().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(i == at ? 1 : 0).accessibilityHidden(i != at)
                }
            }
            Menu {
                Picker("Cooking", selection: $cooking) { ForEach(Self.cookChoices, id: \.self) { Text($0).tag($0) } }
            } label: {
                Label { Text(cooking) + Text(" ") + Text(Image(systemName: "chevron.down")).font(.caption2) } icon: { Image(systemName: "timer") }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Color(.tertiarySystemFill), in: Capsule())
            }
            .accessibilityLabel("Cooking: \(cooking)")
        }
        .font(.subheadline).padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if text.isEmpty && !Task.isCancelled { withAnimation(.easeInOut(duration: 0.5)) { exampleAt += 1 } }
            }
        }
    }

    private func idea(_ m: JSON) -> some View {
        let name = str(m["name"]), meal = str(m["meal"]).isEmpty ? pop.meal : str(m["meal"])
        let kcal = (num(m["kcal"]) ?? 0).rounded(), p = Int((num(m["protein"]) ?? 0).rounded())
        return HStack(spacing: 12) {
            Button { open = IdeaRef(id: name, idea: m) } label: {
                HStack(spacing: 12) {
                    FoodDot(name: name, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        Text(planning ? "From your food plan · \(Fmt.int(kcal)) kcal · recipe" : "\(p) g protein · \(Fmt.int(kcal)) kcal · recipe")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if planning {
                Button {
                    store.add(Assistant.basis(name: name, kcal: kcal, grams: nil, p: num(m["protein"]) ?? 0, c: num(m["carbs"]) ?? 0, f: num(m["fat"]) ?? 0), kcal: kcal, meal: meal)
                    withAnimation { _ = added.insert(name) }
                } label: {
                    Image(systemName: added.contains(name) ? "checkmark.circle.fill" : "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.borderless).disabled(added.contains(name))
                .accessibilityLabel("Add \(name) to \(meal.lowercased())")
            } else {
                // for next time: adding it to today would count a meal on top of the one just had
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: the chat box

    private var composer: some View {
        let empty = text.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            TextField(pop.placeholder, text: $text, axis: .vertical).lineLimit(1...6).focused($typing)
                .submitLabel(.send).onSubmit { send() }
                .padding(.horizontal, 8).padding(.top, 4)
            HStack(spacing: 8) {
                Button { speech.stop(); go(.ask(meal: nextMeal, text: text, camera: true)) } label: { round("plus") }
                    .buttonStyle(.plain).accessibilityLabel(planning ? "Snap your fridge" : "Snap a photo")
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
                        Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .frame(width: 40, height: 40).background(Theme.accent.opacity(empty ? 0.4 : 1), in: Circle())
                    }
                    .buttonStyle(.plain).disabled(empty).accessibilityLabel("Send")
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
        guard !t.isEmpty else { return }
        speech.stop(); typing = false
        go(planning ? .plan(meal: pop.meal, text: t, cooking: cooking) : .ask(meal: nextMeal, text: t, camera: false))
    }
}
