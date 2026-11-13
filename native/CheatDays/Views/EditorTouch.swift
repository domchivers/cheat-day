import SwiftUI
import UIKit

/// What a finger (or two) has hold of in the editor, and what they've done to it since they took hold: carried it,
/// made it bigger or smaller, turned it. One of these is shared by everything on the story. Only the thing held
/// reads the numbers, so only it redraws as they change; the editor itself hears nothing until the fingers lift.
@Observable final class Grab {
    /// An item's place in the list, -1 for the picture behind, nil for nothing.
    var target: Int?
    var move = CGSize.zero
    var size: CGFloat = 1
    /// Degrees to the right.
    var turn: Double = 0
    var fingers = 0
    /// Each item's own size on screen before it's made bigger or turned, for finding which one a finger landed on.
    @ObservationIgnored var sizes: [Int: CGSize] = [:]

    func letGo() { target = nil; move = .zero; size = 1; turn = 0; fingers = 0 }
}

/// The fingers' own readings from one hold, written down for measuring what shakes: on only while a text reading
/// "touchlog" is held. When the fingers lift it's put on the clipboard (a buzz says so), to be pasted and sent.
/// Each line: thousandths of a second since the first finger, how many fingers this reading moved, how many
/// in-between readings the phone had for the first finger, then each finger's place.
@MainActor enum TouchLog {
    static var on = false
    static var head = ""
    static var lines: [String] = []
    static var t0: TimeInterval = 0
    static func note(_ what: String, _ touches: Set<UITouch>, _ down: [UITouch], _ event: UIEvent?, in view: UIView) {
        guard on, lines.count < 4000 else { return }
        let ms = Int(((event?.timestamp ?? t0) - t0) * 1000)
        let co = down.first.flatMap { event?.coalescedTouches(for: $0)?.count } ?? 0
        let at = down.prefix(2).map { t -> String in let q = t.preciseLocation(in: view); return String(format: "%.2f %.2f", q.x, q.y) }.joined(separator: " ")
        lines.append("\(what) \(ms) \(touches.count) \(co) \(at)")
    }
    static func finish() {
        guard on else { return }
        on = false
        guard lines.count > 30 else { return }
        UIPasteboard.general.string = ([head] + lines).joined(separator: "\n")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// The whole story as one surface for fingers. Moving, sizing and turning were three separate gestures before, each
/// deciding for itself when it had begun: a pinch would start a beat after the drag and the turn a beat after
/// that, each arriving with a jump, and they measured against the very thing they were moving. Here it's the
/// fingers themselves that are followed, against the story, which stays put. One finger carries; two carry, size
/// and turn together. The second finger can land anywhere, not only on the thing held.
///
/// Two things keep it steady, both found by measuring a recording of big text shaking as it was pinched:
/// - The thing held is sized and turned about the point between the fingers, not about its own middle. What's
///   under the fingers stays under them. About its own middle, a text many times the screen's size, held near
///   one end, swung that end by several points for every tenth of a degree or thousandth of a size the fingers
///   wavered by: the farther its middle from the fingers, the worse it shook.
/// - The fingers' spread, angle and middle are each taken as the mean of the last two readings. The two fingers
///   are read a moment apart, which puts a small to-and-fro on all three from one reading to the next; the mean
///   of two neighbours cancels exactly that, for about four thousandths of a second's delay.
struct EditorTouch: UIViewRepresentable {
    /// A finger has come down, here. The answer is the middle of whatever it has hold of (in this view's own
    /// points), for sizing and turning it about the fingers; nil, and it's just carried.
    var began: (CGPoint) -> CGPoint?
    /// Since then: its middle carried this far, it made this many times the size, turned this far (radians, to the
    /// right; a twist's first 8 degrees count for nothing, as two fingers pinching always turn a little), with
    /// this many fingers down.
    var changed: (CGSize, CGFloat, CGFloat, Int) -> Void
    /// The last finger has lifted: whether anything was moved (if not, it was a tap), and where it began.
    var ended: (Bool, CGPoint) -> Void

    func makeUIView(context: Context) -> Pad {
        let v = Pad()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        return v
    }
    func updateUIView(_ v: Pad, context: Context) { v.began = began; v.changed = changed; v.ended = ended }

    final class Pad: UIView {
        var began: ((CGPoint) -> CGPoint?)?
        var changed: ((CGSize, CGFloat, CGFloat, Int) -> Void)?
        var ended: ((Bool, CGPoint) -> Void)?
        private var down: [UITouch] = []
        // the last raw reading, and the last steadied one (the mean of two raw neighbours)
        private var rawMiddle = CGPoint.zero, rawApart: CGFloat = 1, rawAngle: CGFloat = 0, wound: CGFloat = 0
        private var lastMiddle = CGPoint.zero, lastApart: CGFloat = 1, lastWound: CGFloat = 0
        // what the fingers have done since they came down
        private var size: CGFloat = 1, twist: CGFloat = 0, turn: CGFloat = 0
        private var middle: CGPoint?            // the middle of the thing held, as it's carried, sized and turned
        private var middleAtStart = CGPoint.zero
        private var carried = CGSize.zero       // with nothing's middle to follow: how far the fingers have gone
        private var start = CGPoint.zero, moved = false
        private static let slack: CGFloat = 8 * .pi / 180

        private var move: CGSize {
            middle.map { CGSize(width: $0.x - middleAtStart.x, height: $0.y - middleAtStart.y) } ?? carried
        }

        /// Where the fingers are now: their middle, how far apart, and the angle of the line between them.
        private func read() -> (middle: CGPoint, apart: CGFloat, angle: CGFloat) {
            let p = down.prefix(2).map { $0.location(in: self) }
            if p.count >= 2 {
                return (CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2), max(1, hypot(p[1].x - p[0].x, p[1].y - p[0].y)), atan2(p[1].y - p[0].y, p[1].x - p[0].x))
            }
            return (p.first ?? .zero, 1, 0)
        }
        /// From here on, measured from where the fingers are now: a finger arriving or leaving changes their middle,
        /// and that mustn't count as a move.
        private func rebase() {
            let r = read()
            rawMiddle = r.middle; rawApart = r.apart; rawAngle = r.angle; wound = 0
            lastMiddle = r.middle; lastApart = r.apart; lastWound = 0
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let first = down.isEmpty
            for t in touches where down.count < 2 { down.append(t) }
            rebase()
            if first { TouchLog.lines = []; TouchLog.t0 = event?.timestamp ?? 0 }
            defer { TouchLog.note("B", touches, down, event, in: self) }
            if first {
                // two fingers at once is never a tap, however still their middle stays
                size = 1; twist = 0; turn = 0; carried = .zero; moved = down.count >= 2; start = lastMiddle
                middle = began?(start)
                middleAtStart = middle ?? .zero
            } else {
                moved = true
                changed?(move, size, turn, down.count)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard !down.isEmpty else { return }
            TouchLog.note("M", touches, down, event, in: self)
            let r = read(), two = down.count >= 2
            // the angle wound on from the last reading, so a turn through north doesn't jump by a whole circle
            var step = r.angle - rawAngle
            if step > .pi { step -= 2 * .pi } else if step < -.pi { step += 2 * .pi }
            let nowWound = wound + step
            // With two fingers each steadied reading is the mean of this raw one and the one before. One finger is
            // followed exactly: there's no to-and-fro between fingers to cancel, and the mean left the thing half a
            // step short of where the finger stopped.
            let m = two ? CGPoint(x: (r.middle.x + rawMiddle.x) / 2, y: (r.middle.y + rawMiddle.y) / 2) : r.middle
            let apart = (r.apart + rawApart) / 2, around = (nowWound + wound) / 2
            rawMiddle = r.middle; rawApart = r.apart; rawAngle = r.angle; wound = nowWound
            advance(to: m, apart: apart, around: around, two: two)

            if !moved {
                // one finger that's barely shifted is a tap; what it has travelled by then is kept
                guard two || hypot(r.middle.x - start.x, r.middle.y - start.y) > 4 else { return }
                moved = true
            }
            changed?(move, size, turn, down.count)
        }

        /// The thing held, taken on from the last steadied reading to this one.
        private func advance(to m: CGPoint, apart: CGFloat, around: CGFloat, two: Bool) {
            var grew: CGFloat = 1, turned: CGFloat = 0
            if two {
                grew = apart / lastApart
                size *= grew
                twist += around - lastWound
                let steady = abs(twist) < Self.slack ? 0 : twist - (twist > 0 ? Self.slack : -Self.slack)
                turned = steady - turn
                turn = steady
            }
            if let c = middle {
                // about the point between the fingers: the thing's middle swings and draws in or out round it
                let vx = (c.x - lastMiddle.x) * grew, vy = (c.y - lastMiddle.y) * grew
                let cs = cos(turned), sn = sin(turned)
                middle = CGPoint(x: m.x + vx * cs - vy * sn, y: m.y + vx * sn + vy * cs)
            } else {
                carried.width += m.x - lastMiddle.x; carried.height += m.y - lastMiddle.y
            }
            lastMiddle = m; lastApart = apart; lastWound = around
        }

        private func lifted(_ touches: Set<UITouch>) {
            TouchLog.note("E", touches, down, nil, in: self)
            // The last word before a finger goes: the fingers exactly as last read, not the mean of the last two
            // readings. With nothing further to average against, the mean stopped half a step short for good.
            if moved, !down.isEmpty {
                advance(to: rawMiddle, apart: rawApart, around: wound, two: down.count >= 2)
                changed?(move, size, turn, down.count)
            }
            down.removeAll { touches.contains($0) }
            if down.isEmpty { TouchLog.finish(); ended?(moved, start) } else { rebase(); changed?(move, size, turn, down.count) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lifted(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lifted(touches) }
    }
}

/// A turn of the picture behind, between -180 and 180, and caught by upright, on its side and upside down when
/// within 6 degrees of them: two fingers pinching always turn a little, and that little mustn't tilt the picture.
func clipSettled(_ deg: Double) -> Double {
    var d = deg.truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
    for stop in [0.0, 90, -90, 180, -180] where abs(d - stop) < 6 { return stop == -180 ? 180 : stop }
    return d
}

/// The picture behind, kept where it's allowed to be. A photo (not `free`) lying straight stays inside its own
/// edges, at its plain size or bigger. A post's clip (`free`) can be smaller than the frame and anywhere in it, but
/// catches at the frame's middle and at its own edges. Turned, either goes where it's put, its middle in reach.
func clipClamped(_ sc: CGFloat, _ off: CGSize, _ deg: Double, fill: CGSize, cw: CGFloat, ch: CGFloat, free: Bool) -> (scale: CGFloat, offset: CGSize) {
    var s = min(10, max(free ? 0.25 : 1, sc))
    if free, abs(s - 1) < 0.03 { s = 1 }   // caught at exactly filling the frame
    let ex = max(0, (fill.width * s - cw) / 2), ey = max(0, (fill.height * s - ch) / 2)
    let rx = (fill.width * s + cw) / 4, ry = (fill.height * s + ch) / 4
    func place(_ v: CGFloat, _ edge: CGFloat, _ reach: CGFloat) -> CGFloat {
        if deg != 0 { return min(reach, max(-reach, v)) }
        if !free || abs(v) <= edge { return min(edge, max(-edge, v)) }
        if abs(v) - edge < 12 { return v > 0 ? edge : -edge }
        return min(reach, max(-reach, v))
    }
    return (s, CGSize(width: place(off.width, ex, rx), height: place(off.height, ey, ry)))
}

/// The photo or clip behind the editor's frame, shown where the editor has it, or, while fingers have hold of it,
/// where they've taken it.
struct MovableClip<Content: View>: View {
    let cw: CGFloat
    let ch: CGFloat
    /// Its size when it just fills the frame.
    let fill: CGSize
    let scale: CGFloat
    let offset: CGSize
    /// How far it's turned, in degrees to the right.
    var spin: Double = 0
    var movable: Bool
    /// A post's clip: free of the frame's edges (see `clipClamped`).
    var free = false
    /// A photo: one finger only moves it once it's zoomed in or turned (at its plain size a swipe changes the filter).
    var photo = false
    var grab: Grab
    @ViewBuilder var content: () -> Content

    /// Whether one finger carries it: shared with the editor, which has to agree when the fingers lift.
    static func pans(photo: Bool, scale: CGFloat, deg: Double, fingers: Int) -> Bool { !photo || abs(scale - 1) > 0.01 || deg != 0 || fingers >= 2 }
    /// Whether it may sit smaller than the frame and be put anywhere in it: a clip always, a photo once it's been
    /// pinched smaller (a photo that still fills the frame keeps to its edges, as before).
    static func loose(photo: Bool, scale: CGFloat) -> Bool { !photo || scale < 0.995 }

    var body: some View {
        let mine = movable && grab.target == -1
        let deg = mine ? clipSettled(spin + grab.turn) : spin
        let s = scale * (mine ? grab.size : 1)
        let carried = mine && Self.pans(photo: photo, scale: s, deg: deg, fingers: grab.fingers)
        let at = carried ? CGSize(width: offset.width + grab.move.width, height: offset.height + grab.move.height) : offset
        let live = mine ? clipClamped(s, at, deg, fill: fill, cw: cw, ch: ch, free: free || (photo && Self.loose(photo: true, scale: s))) : (scale: scale, offset: offset)
        content()
            .scaleEffect(live.scale)
            .rotationEffect(.degrees(deg))
            // not .offset: that lands on whole pixels, so the picture went in steps of a third of a point (measured)
            .transformEffect(CGAffineTransform(translationX: live.offset.width, y: live.offset.height))
            .frame(width: cw, height: ch).clipped()
            .allowsHitTesting(false)
    }
}

/// One thing placed on the story. It's drawn where the editor has it; while fingers have hold of it, where they've
/// taken it, and only it redraws as they go.
struct PlacedItem: View {
    let o: JSON
    let index: Int
    let cw: CGFloat
    let ch: CGFloat
    var hidden: Bool
    var dim: Bool
    var grab: Grab
    var lookKey: String
    var tap: () -> Void
    // the sticker drawn as a picture at the size it's shown: scaled up as it was, it went soft and fuzzy
    @State private var sharp: UIImage?
    @State private var sharpFor = ""
    @Environment(\.displayScale) private var displayScale

    /// What it looks like and how big, for knowing when to draw it again (where it is and its turn don't matter).
    /// Worked out by the editor when the item changes: worked out here, it was done afresh for every move of a
    /// finger, a hundred times a second, and that alone made dragging stutter.
    static func lookKey(_ o: JSON, _ cw: CGFloat) -> String {
        var look = o
        for k in ["x", "y", "rotation"] { look[k] = nil }
        let data = (try? JSONSerialization.data(withJSONObject: look, options: [.sortedKeys])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "") + "\(cw)"
    }

    private var drawn: Bool { str(o["type"]) != "gif" }   // a GIF moves, so it stays live

    private func draw() -> UIImage? {
        let r = ImageRenderer(content: StoryItem(o: o).environment(\.colorScheme, .dark))
        r.proposedSize = ProposedViewSize(width: StoryArt.design, height: nil)
        r.scale = min(12, displayScale * max(1, (num(o["scale"]) ?? 1) * cw / StoryArt.design))
        return r.uiImage
    }

    /// Where an item is, how big and how turned, with what the fingers have done to it: the same sum for showing it
    /// while they're on it and for writing it down when they lift, so it never shifts as they let go. One finger
    /// catches it at the story's middle; a turn is caught at straight (every quarter) within 4 degrees.
    static func resting(_ o: JSON, move: CGSize, size: CGFloat, turn: Double, fingers: Int, cw: CGFloat, ch: CGFloat)
        -> (x: Double, y: Double, scale: Double, rotation: Double, sx: Bool, sy: Bool, straight: Bool) {
        var x = (num(o["x"]) ?? 0.5) + Double(move.width / cw), y = (num(o["y"]) ?? 0.5) + Double(move.height / ch)
        // not with two fingers on it: their middle wanders as they pinch, and it kept catching and letting go
        let sx = fingers == 1 && abs(x - 0.5) < 0.025, sy = fingers == 1 && abs(y - 0.5) < 0.02
        if sx { x = 0.5 }; if sy { y = 0.5 }
        let deg = (num(o["rotation"]) ?? 0) + turn, quarter = (deg / 90).rounded() * 90
        let straight = abs(deg - quarter) < 2.5
        return (min(9, max(-8, x)), min(9, max(-8, y)), min(60, max(0.15, (num(o["scale"]) ?? 1) * Double(size))), straight ? quarter : deg, sx, sy, straight)
    }

    var body: some View {
        let mine = grab.target == index
        let r = Self.resting(o, move: mine ? grab.move : .zero, size: mine ? grab.size : 1, turn: mine ? grab.turn : 0, fingers: mine ? grab.fingers : 0, cw: cw, ch: ch)
        let eff = r.scale * Double(cw / StoryArt.design)
        Group {
            if drawn, let sharp, sharpFor == lookKey { Image(uiImage: sharp) } else { StoryItem(o: o) }
        }
            // its own size, for the editor to know when a finger has landed on it
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { grab.sizes[index] = g.size }
                    .onChange(of: g.size) { _, s in grab.sizes[index] = s }
                    .onChange(of: index) { _, i in grab.sizes[i] = g.size }
            })
            .scaleEffect(eff * (dim ? 0.55 : 1))   // over the bin it draws in, about to go
            .rotationEffect(.degrees(r.rotation))
            .accessibilityElement(children: .ignore).accessibilityIdentifier("placed-" + str(o["type"])).accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            // Laid out at the story's middle, which never changes, and carried from there by a plain transform. Put
            // in its place with .position it landed on whole pixels, a third of a point apart, and so moved in
            // little steps (measured off the screen: up to 0.16 of a point out, against 0.002 this way).
            .position(x: cw / 2, y: ch / 2)
            .transformEffect(CGAffineTransform(translationX: (r.x - 0.5) * cw, y: (r.y - 0.5) * ch))
            .opacity(hidden ? 0 : (dim ? 0.45 : 1))
            .animation(.snappy(duration: 0.18), value: dim)
            .task(id: lookKey) { if drawn { let k = lookKey; sharp = draw(); sharpFor = k } }
            .allowsHitTesting(false)
    }
}

/// A picture to pinch bigger and carry about (a photo being cropped): the same following of the fingers the story
/// editor has, for anything that keeps a zoom and a place. Laid over the picture, under any buttons. With a drag and
/// a pinch as two separate gestures, as these screens had, the pinch began a beat late with a jump and the picture
/// shook as two fingers moved, the same faults the editor had.
struct PinchPanPad: View {
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    var range: ClosedRange<CGFloat> = 1...5
    /// Where the picture's allowed to be at a zoom (so it can't be carried past its own edges).
    var clamp: (CGSize, CGFloat) -> CGSize = { o, _ in o }
    var moving: (Bool) -> Void = { _ in }
    @State private var fromScale: CGFloat = 1
    @State private var fromOffset: CGSize = .zero

    var body: some View {
        EditorTouch(began: { _ in fromScale = scale; fromOffset = offset; return nil },
                    changed: { move, size, _, _ in
                        moving(true)
                        let s = min(range.upperBound, max(range.lowerBound, fromScale * size))
                        scale = s
                        offset = clamp(CGSize(width: fromOffset.width + move.width, height: fromOffset.height + move.height), s)
                    },
                    ended: { _, _ in moving(false) })
    }
}
