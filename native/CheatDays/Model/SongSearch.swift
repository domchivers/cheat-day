import Foundation

/// The songs as the editor's picker lists them, and the part of one that's chosen.
enum SongSearch {
    static let all = "All"

    /// Those in a mood with every word looked for. Looked for, they're looked for in every mood.
    static func find(_ songs: [Song], mood: String, words: String) -> [Song] {
        let wanted: [String] = words.lowercased().split(separator: " ").map { (s: Substring) -> String in String(s) }
        return songs.filter { (s: Song) -> Bool in
            if wanted.isEmpty { return mood == all || s.mood == mood }
            let held: String = "\(s.title) \(s.artist ?? "") \(s.mood)".lowercased()
            return wanted.allSatisfy { (w: String) -> Bool in held.contains(w) }
        }
    }

    /// A song's stored wave, a digit a level.
    static func levels(_ wave: String) -> [Float] {
        wave.compactMap { (c: Character) -> Float? in
            c.wholeNumberValue.map { (n: Int) -> Float in max(0.06, Float(n) / 9) }
        }
    }

    /// Where the part can start: all of it inside the song.
    static func start(_ wanted: Double, length: Double) -> Double {
        let last: Double = max(0, length - Song.part)
        return (min(last, max(0, wanted)) * 10).rounded() / 10
    }
}
