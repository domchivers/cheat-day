import QuartzCore
import UIKit

/// What moves the timeline: a finger's slide, and the glide after it on the screen's own clock. None of it is the
/// editor's state, so none of it makes the editor again.
@MainActor
final class TimelineMotion: NSObject {
    /// Where this slide began, less the dead zone.
    var slip: CGFloat = 0
    private(set) var gliding = false
    private var link: CADisplayLink?
    private var velocity = 0.0
    private var began = 0.0
    private var move: ((Double) -> Bool)?
    private var ended: (() -> Void)?
    private var stoppedAt = 0.0
    private lazy var feedback = UISelectionFeedbackGenerator()

    /// A touch that stopped a glide is only that, not a tap on what was under it.
    var justStopped: Bool { CACurrentMediaTime() - stoppedAt < 0.35 }

    func ready() { feedback.prepare() }

    func tick() {
        feedback.selectionChanged()
        feedback.prepare()
    }

    /// 'move' is given how far it's gone (points) and says whether it can go further.
    func glide(velocity v: Double, move: @escaping (Double) -> Bool, ended: @escaping () -> Void) {
        end()
        velocity = min(TimelineGlide.fastest, max(-TimelineGlide.fastest, v))
        began = CACurrentMediaTime()
        self.move = move
        self.ended = ended
        gliding = true
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ l: CADisplayLink) {
        let gone: Double = max(0, l.targetTimestamp - began)
        let distance: Double = TimelineGlide.travel(velocity: velocity, after: gone)
        let further: Bool = move?(distance) ?? false
        if further, TimelineGlide.speed(velocity: velocity, after: gone) > TimelineGlide.stops { return }
        let finished: (() -> Void)? = ended
        end()
        finished?()
    }

    /// A finger on it: stopped where it is.
    func stopByTouch() {
        guard gliding else { return }
        stoppedAt = CACurrentMediaTime()
        end()
    }

    /// Stopped, and everything let go (the link and the closures hold the editor).
    func end() {
        link?.invalidate()
        link = nil
        move = nil
        ended = nil
        gliding = false
    }
}
