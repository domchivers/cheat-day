import SwiftUI

/// The once-a-day pop-up on Today: yesterday in two lines, then meals to try today (each opens its recipe).
/// Turned off in Settings; never shows on a cheat day.
struct DailyTipsSheet: View {
    let review: DailyReview
    @Environment(\.dismiss) private var dismiss
    @State private var open: IdeaRef?
    @State private var added: Set<String> = []
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
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
                    if let f = review.focus {
                        Eyebrow(text: "This week", color: Theme.heroLabel).padding(.top, 8)
                        line("🥗", f)
                    }
                    Text("You can turn these off in Settings.").font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Let's go") { dismiss() } } }
            .sheet(item: $open) { r in RecipeSheet(idea: r.idea) }
        }
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
