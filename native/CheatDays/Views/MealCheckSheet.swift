import SwiftUI

/// The word after lunch or dinner: what the meal was short on, a fix for next time, and two meals to try (each opens
/// its recipe). In the same style as the morning tips; turned off with them in Settings.
struct MealCheckSheet: View {
    let check: MealCheck
    /// Opens the planner, for when the ideas aren't in the cupboard.
    var plan: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var open: IdeaRef?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("About your \(check.meal.lowercased())").font(.largeTitle.bold())
                    Eyebrow(text: "\(check.foods) · \(Fmt.int(check.kcal)) kcal", color: Theme.heroLabel).padding(.top, 4)
                    ForEach(check.lines.indices, id: \.self) { i in line(check.lines[i].icon, check.lines[i].text) }
                    if !check.ideas.isEmpty {
                        Eyebrow(text: check.meal == "Dinner" ? "Easy dinners to try" : "Try next time", color: Theme.heroLabel).padding(.top, 8)
                        ForEach(check.ideas.indices, id: \.self) { i in idea(check.ideas[i]) }
                    }
                    if let plan {
                        Button(action: plan) {
                            HStack(spacing: 12) {
                                FluentIcon(emoji: "🛒", size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Don't have these in?").font(.subheadline.weight(.bold))
                                    Text("Plan something from what's in your cupboard").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Once after lunch and dinner, only when there's something to help with. You can turn these off in Settings.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Got it") { dismiss() }.fontWeight(.bold) } }
            .sheet(item: $open) { r in RecipeSheet(idea: r.idea) }
        }
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
        let name = str(m["name"]), kcal = (num(m["kcal"]) ?? 0).rounded(), p = Int((num(m["protein"]) ?? 0).rounded())
        return HStack(spacing: 12) {
            Button { open = IdeaRef(id: name, idea: m) } label: {
                HStack(spacing: 12) {
                    FoodDot(name: name, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.bold)).multilineTextAlignment(.leading)
                        Text("\(p) g protein · \(Fmt.int(kcal)) kcal · see the recipe").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // no + here: it's for next time, and adding it to today would count a meal on top of the one just had
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
