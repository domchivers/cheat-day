import Foundation
import Observation

/// The colours saved for captions and text, with their opacity, the same in every video.
@Observable
final class SavedColours {
    struct Saved: Codable, Hashable {
        var hex: String
        var alpha: Double
    }

    static let shared = SavedColours()
    private static let key = "editor.colours.1"
    private(set) var list: [Saved]

    private init() {
        let first: [Saved] = ["yellow", "green", "red", "blue", "white"].map { (name: String) -> Saved in
            Saved(hex: ColourCode.hex(named: name), alpha: 1)
        }
        if let data = UserDefaults.standard.data(forKey: Self.key), let kept = try? JSONDecoder().decode([Saved].self, from: data) {
            list = kept
        } else {
            list = first
        }
    }

    /// Saved at the front; one already there comes to it.
    func add(hex: String, alpha: Double) {
        let new = Saved(hex: hex, alpha: (alpha * 100).rounded() / 100)
        var all: [Saved] = list.filter { (s: Saved) -> Bool in s != new }
        all.insert(new, at: 0)
        list = Array(all.prefix(30))
        store()
    }

    func remove(_ saved: Saved) {
        list.removeAll { (s: Saved) -> Bool in s == saved }
        store()
    }

    private func store() {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
