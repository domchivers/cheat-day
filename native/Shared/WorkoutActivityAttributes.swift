import ActivityKit
import Foundation

/// What the lock screen and Dynamic Island show for a gym session. Shared by the app and the widget.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the current rest ends, or nil when not resting (then the session clock shows).
        var restEnds: Date?
        /// "Lat pulldown · set 2 · 9×93 kg"
        var next: String
        var setsDone: Int
    }

    var name: String
    var startedAt: Date
}
