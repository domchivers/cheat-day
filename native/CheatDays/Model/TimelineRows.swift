import Foundation

/// The clip editor's rows of bars, by id, and what a bar dropped on another row does to them.
enum TimelineRows {
    /// How near, in points, an edge comes before it's held on a target; and how far a finger goes before it moves or
    /// trims anything (a click isn't a drag).
    static let snapReach: CGFloat = 5, dragStarts: CGFloat = 5

    /// What a dragged edge is held on: the clips' edges and the line (the fixed ones), and the other bars' ends. Not
    /// what's switched off; and captions only for a caption (22 Nov recording: every few points along there was a
    /// caption's edge, so a voiceover's handle could stop nowhere else, and jumped from one to the next).
    static func snapTargets(fixed: [Double], bars: [(from: Double, to: Double, caption: Bool, off: Bool)], movingCaption: Bool) -> [Double] {
        var out: [Double] = fixed
        for b in bars where !b.off && (movingCaption || !b.caption) {
            out.append(b.from)
            out.append(b.to)
        }
        return out
    }

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
