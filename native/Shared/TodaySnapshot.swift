import Foundation

/// What the home-screen widget shows, written by the app into the shared app group and read by the widget.
struct TodaySnapshot: Codable, Equatable {
    static let group = "group.com.cheatdays.app"
    private static let key = "today.snapshot"

    var date: String          // the day these numbers are for (yyyy-MM-dd)
    var budget: Double
    var eaten: Double
    var protein: Double
    var proteinGoal: Double?
    var tomorrowBudget: Double
    var cheatDayName: String? // e.g. "Saturday", when there's a cheat day this week
    var cheatToday = false

    var left: Double { budget - eaten }
    var share: Double { budget > 0 ? min(1, eaten / budget) : 0 }

    static func load() -> TodaySnapshot? {
        guard let d = UserDefaults(suiteName: group)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: d)
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.group)?.set(d, forKey: Self.key)
    }

    static var placeholder: TodaySnapshot {
        TodaySnapshot(date: "", budget: 2000, eaten: 1240, protein: 95, proteinGoal: 150, tomorrowBudget: 2000, cheatDayName: "Saturday")
    }
}
