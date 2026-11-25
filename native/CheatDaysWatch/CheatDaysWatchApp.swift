import SwiftUI

/// Cheat Days on Apple Watch (25 Nov, design/watch-app-v5-mockup.html). This first build: Today's Left to eat panel and
/// meals, Add food by voice, and Ask the assistant. Gym and runs come next.
@main
struct CheatDaysWatchApp: App {
    @StateObject private var model = WatchModel.shared
    init() { WatchModel.shared.start() }
    var body: some Scene {
        WindowGroup {
            NavigationStack { HomeView() }
                .environmentObject(model)
                .fontDesign(.rounded)
                .tint(Color(hex: model.today.colours.accent))
        }
    }
}

/// Where a round button goes.
enum WatchPage: Hashable {
    case gym, run, addFood(String?), ask
}

struct HomeView: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let t: WatchToday = model.today
        let theme = WatchTheme(c: t.colours)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                LeftPanel(today: t)
                HStack {
                    RoundButton(symbol: "dumbbell.fill", label: "Gym", on: true, theme: theme, page: .gym)
                    Spacer(minLength: 0)
                    RoundButton(symbol: "figure.run", label: "Run", on: false, theme: theme, page: .run)
                    Spacer(minLength: 0)
                    RoundButton(symbol: "fork.knife", label: "Add food", on: false, theme: theme, page: .addFood(nil))
                    Spacer(minLength: 0)
                    RoundButton(symbol: "bubble.left.fill", label: "Ask", on: false, theme: theme, page: .ask)
                }
                ForEach(t.meals) { (m: WatchToday.Meal) in
                    MealBlock(meal: m, theme: theme)
                }
                if t.meals.isEmpty && !t.date.isEmpty {
                    Text("Nothing logged yet today.").font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
        .navigationTitle("Today")
        .navigationDestination(for: WatchPage.self) { (p: WatchPage) in
            switch p {
            case .gym: SoonView(symbol: "dumbbell.fill", title: "Gym", text: "Gym sessions on your watch come in the next build. Start one on your iPhone for now.")
            case .run: SoonView(symbol: "figure.run", title: "Run", text: "Runs, rides, walks and hikes on your watch come soon. Start one on your iPhone for now.")
            case .addFood(let meal): AddFoodView(meal: meal)
            case .ask: AskView()
            }
        }
        .onChange(of: phase) { _, now in if now == .active { model.refresh() } }
        .onAppear { model.refresh() }
    }
}

/// Today's Left to eat panel, as on the phone: the big number, the bar in each meal's colour, eaten, protein, budget.
struct LeftPanel: View {
    let today: WatchToday
    var body: some View {
        let theme = WatchTheme(c: today.colours)
        let left: Double = today.left
        let scale: Double = max(today.budget, today.eaten, 1)
        VStack(alignment: .leading, spacing: 5) {
            Text(left >= 0 ? "LEFT TO EAT" : "OVER TODAY").font(.system(size: 11, weight: .heavy)).tracking(0.8).foregroundStyle(theme.heroLabel)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Num.int(abs(left))).font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text("kcal").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    theme.track
                    HStack(spacing: 2) {
                        ForEach(today.meals) { (m: WatchToday.Meal) in
                            theme.meal(m.name).frame(width: max(3, g.size.width * m.kcal / scale - 2))
                        }
                    }
                }
            }
            .frame(height: 8).clipShape(Capsule())
            HStack {
                stat(Num.int(today.eaten), "eaten")
                Spacer(minLength: 2)
                stat(today.proteinGoal.map { "\(Num.int(today.protein))/\(Num.int($0))g" } ?? "\(Num.int(today.protein))g", "protein")
                Spacer(minLength: 2)
                stat(Num.int(today.budget), "budget")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.hero, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Num.int(abs(left))) kcal \(left >= 0 ? "left to eat" : "over today"). \(Num.int(today.eaten)) eaten, \(Num.int(today.protein)) grams of protein.")
    }
    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.system(size: 13, weight: .heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

/// One of the four round buttons under the panel: the phone's own icons, the first in the accent.
struct RoundButton: View {
    let symbol: String, label: String, on: Bool
    let theme: WatchTheme
    let page: WatchPage
    var body: some View {
        NavigationLink(value: page) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? theme.onAccent : .white)
                .frame(width: 40, height: 40)
                .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(WatchTheme.card), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A meal: its name and calories, its foods in a card with their icons, and Add at the foot.
struct MealBlock: View {
    let meal: WatchToday.Meal
    let theme: WatchTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(meal.name).font(.headline.weight(.heavy))
                Spacer()
                Text("\(Num.int(meal.kcal)) kcal").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.top, 6).padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(meal.foods) { (f: WatchToday.Food) in
                    FoodLine(food: f)
                    Divider().opacity(0.4)
                }
                NavigationLink(value: WatchPage.addFood(meal.name)) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .heavy)).foregroundStyle(theme.onAccent)
                            .frame(width: 20, height: 20).background(theme.accent, in: Circle())
                        Text("Add \(meal.name.lowercased())").font(.footnote.weight(.semibold)).foregroundStyle(theme.accent)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 9)
            .background(WatchTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// A food: its icon (the phone's Fluent icons), name, amount and calories.
struct FoodLine: View {
    let food: WatchToday.Food
    var body: some View {
        HStack(spacing: 7) {
            FoodIcon(asset: food.icon, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(food.name).font(.footnote.weight(.semibold)).lineLimit(2)
                if !food.amount.isEmpty { Text(food.amount).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Text(Num.int(food.kcal)).font(.footnote.weight(.heavy)).monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct FoodIcon: View {
    let asset: String
    var size: CGFloat = 20
    var body: some View {
        // (the phone only sends icons that are bundled: FoodIcons.xcassets is in both apps)
        Image(asset).resizable().scaledToFit().frame(width: size, height: size)
    }
}

/// Gym and runs, until they're built on the watch.
struct SoonView: View {
    let symbol: String, title: String, text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .semibold))
            Text(text).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .navigationTitle(title)
    }
}
