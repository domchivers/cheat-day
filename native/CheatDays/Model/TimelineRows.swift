import Foundation

/// The clip editor's rows of bars, by id, and what a bar dropped on another row does to them.
enum TimelineRows {
    /// The most rows the timeline shows (8 since captions came in layers: six were full with a voiceover's and music).
    static let most = 8

    /// Whether a bar can have a new row under the last. Not one that has the last to itself: the row it left would
    /// close up, and it would be back where it was (22 Nov: "can't go to a new line?").
    static func canAddRow(for id: UUID, rows: [[UUID]]) -> Bool {
        guard rows.count < most, let last = rows.last else { return false }
        return last != [id]
    }

    /// The rows with a bar taken from row `from` to row `to` (as many as there are: a new one under the last). Where it
    /// doesn't fit it has a row of its own there: past that one going down, over it going up. Empty rows close up.
    static func moved(_ id: UUID, from: Int, to: Int, rows: [[UUID]], fits: Bool) -> [[UUID]] {
        var out = rows
        out[from].removeAll { $0 == id }
        if to >= out.count { out.append([id]) }
        else if fits { out[to].append(id) }
        else { out.insert([id], at: to >= from ? to + 1 : to) }
        return out.filter { !$0.isEmpty }
    }
}
