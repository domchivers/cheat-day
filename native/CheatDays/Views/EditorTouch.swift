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

/// The whole story as one surface for fingers. Moving, sizing and turning were three separate gestures before, each
/// deciding for itself when it had begun: a pinch would start a beat after the drag and the turn a beat after
/// that, each arriving with a jump, and they measured against the very thing they were moving. Here it's the
/// fingers themselves that are followed, against the story, which stays put. One finger carries; two carry, size
/// and turn together, from the line between them. The second finger can land anywhere, not only on the thing held.
struct EditorTouch: UIViewRepresentable {
    /// A finger has come down, here.
    var began: (CGPoint) -> Void
    /// Since then: carried this far, made this many times the size, turned this far (radians, to the right), with this many fingers down.
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
        var began: ((CGPoint) -> Void)?
        var changed: ((CGSize, CGFloat, CGFloat, Int) -> Void)?
        var ended: ((Bool, CGPoint) -> Void)?
        private var down: [UITouch] = []
        private var lastMiddle = CGPoint.zero, lastApart: CGFloat = 1, lastAngle: CGFloat = 0
        private var move = CGSize.zero, size: CGFloat = 1, turn: CGFloat = 0
        private var start = CGPoint.zero, moved = false

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
        private func rebase() { let r = read(); lastMiddle = r.middle; lastApart = r.apart; lastAngle = r.angle }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let first = down.isEmpty
            for t in touches where down.count < 2 { down.append(t) }
            rebase()
            if first {
                // two fingers at once is never a tap, however still their middle stays
                move = .zero; size = 1; turn = 0; moved = down.count >= 2; start = lastMiddle
                began?(start)
            } else {
                moved = true
                changed?(move, size, turn, down.count)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard !down.isEmpty else { return }
            let r = read()
            move.width += r.middle.x - lastMiddle.x; move.height += r.middle.y - lastMiddle.y
            if down.count >= 2 {
                size *= r.apart / lastApart
                var d = r.angle - lastAngle
                if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                turn += d
            }
            lastMiddle = r.middle; lastApart = r.apart; lastAngle = r.angle
            if !moved {
                // one finger that's barely shifted is a tap. (Only its travel was looked at before, so two fingers
                // spreading evenly about a still middle counted as a tap, and a pinch on text opened it for typing.)
                // What it has travelled by then is kept: thrown away, the thing trailed the finger by that much.
                guard down.count >= 2 || hypot(move.width, move.height) > 4 else { return }
                moved = true
            }
            changed?(move, size, turn, down.count)
        }

        private func lifted(_ touches: Set<UITouch>) {
            down.removeAll { touches.contains($0) }
            if down.isEmpty { ended?(moved, start) } else { rebase(); changed?(move, size, turn, down.count) }
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
    static func pans(photo: Bool, scale: CGFloat, deg: Double, fingers: Int) -> Bool { !photo || scale > 1.01 || deg != 0 || fingers >= 2 }

    var body: some View {
        let mine = movable && grab.target == -1
        let deg = mine ? clipSettled(spin + grab.turn) : spin
        let s = scale * (mine ? grab.size : 1)
        let carried = mine && Self.pans(photo: photo, scale: s, deg: deg, fingers: grab.fingers)
        let at = carried ? CGSize(width: offset.width + grab.move.width, height: offset.height + grab.move.height) : offset
        let live = mine ? clipClamped(s, at, deg, fill: fill, cw: cw, ch: ch, free: free) : (scale: scale, offset: offset)
        content()
            .scaleEffect(live.scale)
            .rotationEffect(.degrees(deg))
            .offset(live.offset)
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
        return (min(1, max(0, x)), min(1, max(0, y)), min(60, max(0.15, (num(o["scale"]) ?? 1) * Double(size))), straight ? quarter : deg, sx, sy, straight)
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
            .position(x: r.x * cw, y: r.y * ch)
            .opacity(hidden ? 0 : (dim ? 0.45 : 1))
            .animation(.snappy(duration: 0.18), value: dim)
            .task(id: lookKey) { if drawn { let k = lookKey; sharp = draw(); sharpFor = k } }
            .allowsHitTesting(false)
    }
}
