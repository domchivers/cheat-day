import Foundation

/// Undo and Redo for the whole edit (22 Nov audit: text, stickers, overlays, the shape and some deletes weren't in
/// it). It's told when something's changed and records it once that's settled, so a drag, a slider or a spell of
/// typing is one step, and one that ended where it began is none.
struct EditHistory<State: Equatable> {
    private(set) var base: State?
    private(set) var past: [State] = []
    private(set) var future: [State] = []
    /// Something's changed since the last step, not yet recorded.
    private(set) var changed = false
    private let most = 50

    var canUndo: Bool { changed || !past.isEmpty }
    var canRedo: Bool { !changed && !future.isEmpty }

    mutating func start(_ state: State) {
        base = state
        changed = false
    }

    mutating func touched() {
        if base != nil { changed = true }
    }

    /// A step: the edit as it is now, if it's different from the last.
    mutating func record(_ state: State) {
        changed = false
        guard let was = base, was != state else { return }
        past.append(was)
        if past.count > most { past.removeFirst() }
        future = []
        base = state
    }

    /// What follows from an Undo or Redo by itself: no step of its own.
    mutating func absorb(_ state: State) {
        base = state
        changed = false
    }

    mutating func undo(from state: State) -> State? {
        record(state)
        guard let last = past.popLast() else { return nil }
        future.append(state)
        base = last
        return last
    }

    mutating func redo(from state: State) -> State? {
        record(state)
        guard let next = future.popLast() else { return nil }
        past.append(state)
        base = next
        return next
    }
}

/// A meal, recipe or workout as Undo keeps it: compared by what's in it.
struct SameJSON: Equatable {
    var value: JSON?

    static func == (a: SameJSON, b: SameJSON) -> Bool {
        switch (a.value, b.value) {
        case (nil, nil): return true
        case let (x?, y?): return (x as NSDictionary).isEqual(y as NSDictionary)
        default: return false
        }
    }
}
