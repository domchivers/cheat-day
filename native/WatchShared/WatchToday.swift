import Foundation

/// What the phone and the watch say to each other (25 Nov, design/watch-app-v5-mockup.html). The phone keeps the
/// watch's Today up to date; the watch asks the phone's assistant, since the AI lives on the phone. Each is sent as
/// JSON under its key in a WatchConnectivity message.
enum WatchKey {
    /// Today for the watch (WatchToday): in the application context, and asked for when the watch app opens.
    static let today = "today"
    /// The watch asks what a food or meal adds up to ("a flat white and a banana"): a WatchEstimate comes back.
    static let food = "food"
    /// The watch asks the assistant anything, with the chat so far (WatchChat): a WatchAnswer comes back.
    static let ask = "ask"
    /// The watch adds an estimate it was shown, by its id: Today comes back.
    static let add = "add"
    /// Something went wrong on the phone: what to show.
    static let error = "error"
}

/// Today as the watch shows it: the Left to eat panel, the meals and their foods, and the app's colours.
struct WatchToday: Codable, Equatable {
    var date: String
    var budget: Double
    var eaten: Double
    var protein: Double
    var proteinGoal: Double?
    var meals: [Meal]
    var colours: Colours

    struct Meal: Codable, Equatable, Identifiable {
        var name: String
        var kcal: Double
        var foods: [Food]
        var id: String { name }
    }

    struct Food: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var kcal: Double
        /// "1 wrap", "120 g", or empty.
        var amount: String
        /// The bundled icon's asset name (FoodIcons.xcassets), e.g. "food-1f34c".
        var icon: String
    }

    /// The theme picked on the phone, as its dark-mode colours (hex, "aab2f8").
    struct Colours: Codable, Equatable {
        var accent: String
        var onAccent: String
        var hero: String
        var heroLabel: String
        var track: String
        /// Breakfast, Lunch, Dinner, Snacks.
        var meals: [String: String]
    }

    var left: Double { budget - eaten }

    /// Before the phone has sent anything.
    static let empty = WatchToday(date: "", budget: 0, eaten: 0, protein: 0, proteinGoal: nil, meals: [],
                                  colours: Colours(accent: "aab2f8", onAccent: "10141a", hero: "1c1f48", heroLabel: "aab1ec", track: "2a2e5c",
                                                   meals: ["Breakfast": "fac766", "Lunch": "5cd19e", "Dinner": "aab2f8", "Snacks": "ed8cb3"]))
}

/// What a food or meal said on the watch adds up to, ready to add.
struct WatchEstimate: Codable, Equatable {
    var id: String
    var name: String
    /// Where Add puts it: Breakfast, Lunch, Dinner or Snacks.
    var meal: String
    var kcal: Double
    var protein: Double
    var parts: [WatchToday.Food]
}

/// One line of a chat on the watch.
struct WatchLine: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var me: Bool
    var text: String
}

/// The chat so far, sent with each question.
struct WatchChat: Codable {
    var lines: [WatchLine]
}

/// The assistant's answer, and a food to add when it made one.
struct WatchAnswer: Codable, Equatable {
    var text: String
    var estimate: WatchEstimate?
}

enum WatchCoding {
    static func data<T: Encodable>(_ v: T) -> Data? { try? JSONEncoder().encode(v) }
    static func value<T: Decodable>(_ type: T.Type, _ d: Any?) -> T? {
        guard let d = d as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
}
