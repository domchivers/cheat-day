import Observation
import SwiftUI

/// Where the editor's line is. Read only by what moves with it (22 Nov, "lets make sure things move super smoothly":
/// as the editor's own state, each move of a finger and each tick as it played made the whole editor again).
@Observable
final class EditPlayhead {
    var time = 0.0
}

/// A part of the editor that's made again by itself when what it reads of the playhead changes.
struct Live<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// Something worked out from some of the edit, kept until that's different.
final class Remembered<Key: Equatable, Value> {
    private var lastKey: Key?
    private var lastValue: Value?

    func get(for new: Key, make: () -> Value) -> Value {
        if let was = lastKey, let kept = lastValue, was == new { return kept }
        let made: Value = make()
        lastKey = new
        lastValue = made
        return made
    }
}
