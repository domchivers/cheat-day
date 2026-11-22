import Foundation

/// The record button: tap to start and tap to stop, or hold to talk (design/editor-panels-mockup.html, 3).
struct VoicePress: Equatable {
    enum Phase: Equatable { case idle, down, counting, held, going }
    enum Act: Equatable { case none, start, count, stopCount, stop }

    /// A press this long is a hold.
    static let hold = 0.35

    private(set) var phase = Phase.idle
    private(set) var countdown = false

    /// A finger on it.
    mutating func pressed(countdown: Bool) -> Act {
        switch phase {
        case .idle:
            self.countdown = countdown
            phase = .down
            // (no countdown: at once, so a hold loses none of the first word)
            return countdown ? .none : .start
        case .counting:
            phase = .idle
            return .stopCount
        case .going:
            phase = .idle
            return .stop
        default:
            return .none
        }
    }

    /// The finger's been on it long enough to be holding it.
    mutating func heldLong() -> Act {
        guard phase == .down else { return .none }
        phase = .held
        return countdown ? .start : .none
    }

    /// The finger off it.
    mutating func released() -> Act {
        switch phase {
        case .down:
            phase = countdown ? .counting : .going
            return countdown ? .count : .none
        case .held:
            phase = .idle
            return .stop
        default:
            return .none
        }
    }

    /// The countdown's over.
    mutating func counted() -> Act {
        guard phase == .counting else { return .none }
        phase = .going
        return .start
    }

    mutating func reset() {
        phase = .idle
    }
}

/// How loud the microphone's hearing it, the last few seconds: written as it records, read as it's drawn.
final class VoiceMeter: @unchecked Sendable {
    static let room = 120
    private let lock = NSLock()
    private var levels: [Float] = []

    func clear() {
        lock.lock()
        levels = []
        lock.unlock()
    }

    func add(_ peak: Float) {
        lock.lock()
        levels.append(Self.shown(peak))
        if levels.count > Self.room { levels.removeFirst(levels.count - Self.room) }
        lock.unlock()
    }

    /// Every place across the meter, those still to come at nothing.
    func snapshot() -> [Float] {
        lock.lock()
        let now: [Float] = levels
        lock.unlock()
        return now + [Float](repeating: 0, count: max(0, Self.room - now.count))
    }

    /// A peak as tall as it's shown: talking isn't near full, so its root.
    static func shown(_ peak: Float) -> Float {
        min(1, max(0, peak).squareRoot())
    }
}
