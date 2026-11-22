import Foundation

/// The timeline gliding on after a flick and slowing as a scroll view's does (22 Nov, "smoothly too like capcut": it
/// stopped dead as the finger left it).
enum TimelineGlide {
    /// A scroll view's normal rate, 0.998 a thousandth of a second, as a second's decay.
    static let decay: Double = -log(0.998) * 1000
    /// Slower than this (points a second) as it's let go, it doesn't glide.
    static let starts = 80.0
    /// Slower than this, it's stopped.
    static let stops = 10.0
    static let fastest = 5000.0
    /// How far off a clip's edge, let go still, it settles on it (points).
    static let settles = 4.0

    /// How far it's gone, so long after it was let go.
    static func travel(velocity: Double, after seconds: Double) -> Double {
        velocity * (1 - exp(-decay * seconds)) / decay
    }

    static func speed(velocity: Double, after seconds: Double) -> Double {
        abs(velocity) * exp(-decay * seconds)
    }

    /// Whether a move of the line went over, or onto, one of these.
    static func crossed(_ edges: [Double], from old: Double, to new: Double) -> Bool {
        guard old != new else { return false }
        let low: Double = min(old, new), high: Double = max(old, new)
        return edges.contains { (edge: Double) -> Bool in edge >= low && edge <= high && edge != old }
    }

    /// The first move of a slide without the dead zone in it: that was a jump.
    static func slip(_ dx: Double, deadZone: Double) -> Double {
        min(deadZone, max(-deadZone, dx))
    }
}
