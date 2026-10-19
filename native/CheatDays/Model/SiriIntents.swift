import AppIntents
import Foundation

/// Siri and Shortcuts: "How many calories have I got left in Cheat Days", "Log a flat white in Cheat Days",
/// "Weigh in on Cheat Days". They run in the app, so they use the same record and sync as tapping.

struct CaloriesLeftIntent: AppIntent {
    static var title: LocalizedStringResource = "Calories left today"
    static var description = IntentDescription("Says how many calories you have left today, and your protein so far.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = Store.shared
        let left = store.budgetToday - store.eaten
        let p = store.macros(store.todayItems).p
        let protein = store.proteinGoal.map { " and \(Int(p)) of \(Int($0)) grams of protein" } ?? ""
        let line = left >= 0 ? "You've got \(Fmt.int(left)) calories left today\(protein)." : "You're \(Fmt.int(-left)) calories over today\(protein)."
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

struct LogFoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a food"
    static var description = IntentDescription("Adds a food you've had before (or one from the food list) to today, at your usual amount.")

    @Parameter(title: "Food", requestValueDialog: "What did you have?")
    var food: String

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$food)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = Store.shared
        let q = food.trimmingCharacters(in: .whitespacesAndNewlines)
        // your own foods first (at the amount you usually have), then the food list at a typical serving
        if let mine = store.search(q).mine.first {
            store.add(mine.basis, kcal: mine.kcal, meal: Meals.now)
            return .result(dialog: IntentDialog(stringLiteral: "Added \(mine.name) to \(Meals.now.lowercased()), \(Fmt.int(mine.kcal)) calories."))
        }
        if let row = FoodsDB.search(q, limit: 1).first {
            let k = num(row["kcalPerServing"]) ?? (num(row["kcalPer100"]) ?? 0)
            store.add(row, kcal: k, meal: Meals.now)
            return .result(dialog: IntentDialog(stringLiteral: "Added \(str(row["name"])) to \(Meals.now.lowercased()), \(Fmt.int(k)) calories. You can change the amount in the app."))
        }
        return .result(dialog: IntentDialog(stringLiteral: "I couldn't find \(q). Open Cheat Days to search, scan it or ask the assistant."))
    }
}

struct WeighInIntent: AppIntent {
    static var title: LocalizedStringResource = "Weigh in"
    static var description = IntentDescription("Saves today's weight in kilograms.")

    @Parameter(title: "Weight in kg", requestValueDialog: "What do you weigh, in kilos?")
    var kg: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard kg > 20, kg < 400 else { return .result(dialog: "That doesn't look like a weight in kilos.") }
        Store.shared.weighIn(kg)
        return .result(dialog: IntentDialog(stringLiteral: "Saved \(Fmt.kg(kg)) kilos for today."))
    }
}

struct CheatDaysShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaloriesLeftIntent(), phrases: [
            "How many calories have I got left in \(.applicationName)",
            "Calories left in \(.applicationName)",
            "How am I doing in \(.applicationName)"
        ], shortTitle: "Calories left", systemImageName: "flame")
        AppShortcut(intent: LogFoodIntent(), phrases: [
            "Log food in \(.applicationName)",
            "Add food to \(.applicationName)"
        ], shortTitle: "Log a food", systemImageName: "fork.knife")
        AppShortcut(intent: WeighInIntent(), phrases: [
            "Weigh in on \(.applicationName)",
            "Log my weight in \(.applicationName)"
        ], shortTitle: "Weigh in", systemImageName: "scalemass")
    }
}
