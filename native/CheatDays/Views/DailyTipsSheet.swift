import SwiftUI

/// The once-a-day pop-up on Today: yesterday in two lines, meals to try today (each opens its recipe), and a hand with
/// the next meal: how much cooking you fancy and what's in the fridge, then the assistant suggests what to make.
/// Turned off in Settings; never shows on a cheat day.
struct DailyTipsSheet: View {
    let review: DailyReview
    var ask: ((_ meal: String, _ question: String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var open: IdeaRef?
    @State private var added: Set<String> = []
    @State private var cooking = ""
    @AppStorage("pantry") private var pantry = ""   // kept for next time: the fridge doesn't change that much
    @FocusState private var typing: Bool
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(greeting).font(.largeTitle.bold())
                    if review.afterCheat {
                        line("🎉", "Hope you enjoyed your cheat day. Back to normal today, nothing to make up for.")
                    } else if review.good != nil || review.improve != nil {
                        Eyebrow(text: "Yesterday", color: Theme.heroLabel).padding(.top, 4)
                        if let g = review.good { line("🏆", g) }
                        if let i = review.improve { line("🎯", i) }
                    }
                    if !review.ideas.isEmpty {
                        Eyebrow(text: "Try today", color: Theme.heroLabel).padding(.top, 8)
                        ForEach(review.ideas.indices, id: \.self) { i in idea(review.ideas[i]) }
                    }
                    if ask != nil { help }
                    if let f = review.focus {
                        Eyebrow(text: "This week", color: Theme.heroLabel).padding(.top, 8)
                        line("🥗", f)
                    }
                    Text("You can turn these off in Settings.").font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: typing) { _, t in
                guard t else { return }
                // the keyboard would cover the button under the box: bring it up with the box
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { proxy.scrollTo("go", anchor: .bottom) } }
            }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Let's go") { dismiss() } } }
            .onAppear { if cooking.isEmpty { cooking = Self.cookChoice(str(store.habits["cook"])) } }
            .sheet(item: $open) { r in RecipeSheet(idea: r.idea) }
        }
    }

    // MARK: a hand with the next meal

    private static let cookChoices = ["No cooking", "Quick, 15 min", "Happy to cook"]
    private static func cookChoice(_ level: String) -> String {
        switch level { case "love": return cookChoices[2]; case "hate": return cookChoices[0]; default: return cookChoices[1] }
    }

    /// The meal it's time to think about; snacks aren't worth planning, so it's dinner then.
    private var nextMeal: String {
        let m = Meals.byTime(Calendar.current.component(.hour, from: Date()))
        return m == "Snacks" ? "Dinner" : m
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FluentIcon(emoji: "🍽️", size: 26)
                Text("Need a hand with \(nextMeal.lowercased())?").font(.headline)
            }
            Text("How much cooking?").font(.subheadline).foregroundStyle(.secondary)
            Flow { ForEach(Self.cookChoices, id: \.self) { c in Chip(text: c, on: cooking == c) { cooking = c } } }
            Text("What's in your fridge and cupboard?").font(.subheadline).foregroundStyle(.secondary)
            TextField("e.g. eggs, chicken, rice, peppers, cheese", text: $pantry, axis: .vertical)
                .lineLimit(2...4).focused($typing)
                .padding(12).background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button {
                typing = false
                ask?(nextMeal, question)
            } label: {
                Label(pantry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give me ideas" : "What can I make?", systemImage: "sparkles")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(.black)
            .id("go")
            Text("Leave the fridge empty for ideas from anything. You can also snap your fridge in the chat.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 8)
    }

    private var question: String {
        let meal = nextMeal.lowercased()
        let cook = cooking == Self.cookChoices[0] ? "I don't want to cook: nothing more than assembling or a microwave."
                 : cooking == Self.cookChoices[2] ? "I'm happy to cook properly."
                 : "Something quick, 15 minutes or so."
        let have = pantry.trimmingCharacters(in: .whitespacesAndNewlines)
        let usual = store.mealHistory(nextMeal).prefix(12).map(\.name).joined(separator: ", ")
        let style = usual.isEmpty ? "" : " Lately I've had \(usual) for \(meal): keep to that sort of food, just better."
        return (have.isEmpty
            ? "Help me with \(meal). \(cook) Give me 2 or 3 ideas that fit what I've got left today, with the calories and protein for each."
            : "Help me with \(meal). \(cook) I've got: \(have). Give me 2 or 3 things I can make mostly from that (staples like oil, salt and spices are fine), that fit what I've got left today, with calories, protein and a short method.") + style
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FluentIcon(emoji: icon, size: 26)
            Text(text).font(.body)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func idea(_ m: JSON) -> some View {
        let name = str(m["name"]), meal = str(m["meal"]), kcal = (num(m["kcal"]) ?? 0).rounded()
        return HStack(spacing: 12) {
            Button { open = IdeaRef(id: name, idea: m) } label: {
                HStack(spacing: 12) {
                    FoodDot(name: name, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        Text("\(meal) · \(Fmt.int(kcal)) kcal · recipe").font(.caption).foregroundStyle(.secondary)
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
            .buttonStyle(.borderless)
            .disabled(added.contains(name))
            .accessibilityLabel("Add \(name) to \(meal.lowercased())")
        }
        .padding(12)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
