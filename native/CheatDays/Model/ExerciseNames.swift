import Foundation

/// Exercise names that are probably one exercise spelled two ways ("Cheat flies" and "Chest flies"). The app only ever
/// asks: "Leg curl" and "Leg curls" merge if you say so, and stay apart for good if you say they're different.
enum ExerciseNames {
    /// A name's plain form: lower case, spaces tidied, no plural on any word.
    private static func plain(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { w -> String in
            w.count > 3 && w.hasSuffix("es") ? String(w.dropLast(2)) : w.count > 3 && w.hasSuffix("s") ? String(w.dropLast()) : String(w)
        }.joined(separator: " ")
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in a.indices {
            var last = row[0]
            row[0] = i + 1
            for j in b.indices {
                let was = row[j + 1]
                row[j + 1] = min(was + 1, row[j] + 1, last + (a[i] == b[j] ? 0 : 1))
                last = was
            }
        }
        return row[b.count]
    }

    /// One slip in a short name, two in a long one. A different number is a different exercise ("Row 1" and "Row 2").
    static func similar(_ a: String, _ b: String) -> Bool {
        let x = plain(a), y = plain(b)
        guard x != y || a.lowercased() != b.lowercased(), min(x.count, y.count) >= 5 else { return false }
        if x.filter(\.isNumber) != y.filter(\.isNumber) { return false }
        return distance(x, y) <= (min(x.count, y.count) >= 10 ? 2 : 1)
    }

    /// Pairs you've said are different, kept on this phone.
    private static let keptApartKey = "exercise.keptApart"
    private static func pair(_ a: String, _ b: String) -> String { [a.lowercased(), b.lowercased()].sorted().joined(separator: "|") }
    static func keptApart(_ a: String, _ b: String) -> Bool { UserDefaults.standard.stringArray(forKey: keptApartKey)?.contains(pair(a, b)) == true }
    static func keepApart(_ a: String, _ b: String) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: keptApartKey) ?? []) + [pair(a, b)], forKey: keptApartKey)
    }

    /// The first two names that look like one exercise, and haven't been answered yet.
    static func firstPair(in names: [String]) -> (String, String)? {
        for (i, a) in names.enumerated() { for b in names[(i + 1)...] where similar(a, b) && !keptApart(a, b) { return (a, b) } }
        return nil
    }
}

extension Store {
    /// The names you've logged, most recently used first.
    var exerciseNames: [String] {
        dict(doc["exercises"]).values.compactMap { $0 as? JSON }.sorted { str($0["lastUsed"]) > str($1["lastUsed"]) }.map { str($0["name"]) }.filter { !$0.isEmpty }
    }

    /// A name being typed that isn't one you've used, but looks very like one that is.
    func exerciseItMayMean(_ name: String) -> String? {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, exercise(typed) == nil else { return nil }
        return exerciseNames.first { ExerciseNames.similar(typed, $0) && !ExerciseNames.keptApart(typed, $0) }
    }

    func mergeExercise(_ from: String, into to: String) { perform(["type": "renameExercise", "from": from, "to": to], syncAfter: 1) }
}
