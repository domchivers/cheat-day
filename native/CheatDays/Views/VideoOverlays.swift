import SwiftUI

/// What's over the edit in the preview, to drag, size and tap (design/caption-move-mockup.html). A view of its own:
/// a drag makes only this again, not the editor (22 Nov).
struct VideoOverlays: View {
    let clock: EditPlayhead
    let texts: [EditText]
    let sounds: [EditSound]
    let pips: [EditPip]
    let frameSize: CGSize
    let selected: UUID?
    let selectedPip: UUID?
    let playing: Bool
    /// The video's corners rounded (over the caption panel).
    let rounded: Bool
    let held: (Bool) -> Void
    let pick: (UUID) -> Void
    let pickPip: (UUID) -> Void
    /// Let go: the caption, text or sticker as it's now placed, and what changed.
    let placed: (_ item: EditText, _ moved: Bool, _ sized: Bool) -> Void
    let setPip: (UUID, MoveKey) -> Void

    private struct Hold {
        var id: UUID
        var start: EditText
        var live: EditText
        var moved = false
        var sized = false
        var pinch: CGFloat = 1
        var middleX = false
        var middleY = false
    }
    private struct PipHold {
        var id: UUID
        var start: MoveKey
        var live: MoveKey
        var sized = false
        var pinch: CGFloat = 1
    }

    @State private var hold: Hold?
    @State private var pipHold: PipHold?
    @GestureState private var touching = false

    private static let space = "video"

    var body: some View {
        GeometryReader { g in
            layer(MultiClipEditor.fitted(frameSize, in: g.size), size: g.size)
        }
    }

    private func layer(_ r: CGRect, size: CGSize) -> some View {
        let t: Double = clock.time
        let items: [EditText] = drawn
        let held: UUID? = heldCaption
        // (all from the one top left corner)
        return ZStack(alignment: .topLeading) {
            if rounded { corners(r) }
            ForEach(pips) { (p: EditPip) in
                if shows(p, at: t) { pipBox(p, frame: r, at: t) }
            }
            ForEach(items) { (item: EditText) in
                if shows(item, at: t, held: held) { textBox(item, frame: r, at: t) }
            }
            if let h = hold, h.moved { guides(h, frame: r) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .onChange(of: touching) { (_: Bool, down: Bool) in
            // a drag cut short has no end of its own
            if !down { DispatchQueue.main.async { finish() } }
        }
    }

    /// As they're drawn: the one being dragged where the finger has it, never put over a voiceover's under it.
    private var drawn: [EditText] {
        var all: [EditText] = texts
        if let h = hold, let i = all.firstIndex(where: { (t: EditText) -> Bool in t.id == h.id }) {
            all[i].x = h.live.x
            all[i].y = h.live.y
            all[i].size = h.live.size
            all[i].byHand = true
        }
        return CaptionLayers.placed(all, sounds: sounds)
    }

    /// A caption picked and held up while paused: the others aren't drawn with it.
    private var heldCaption: UUID? {
        guard !playing, let id = selected else { return nil }
        let up: Bool = texts.contains { (x: EditText) -> Bool in x.id == id && x.kind == "caption" && x.hidden != true }
        return up ? id : nil
    }

    private func shows(_ p: EditPip, at t: Double) -> Bool {
        if p.id == selectedPip || p.id == pipHold?.id { return true }
        return t >= p.from && t < p.to
    }

    private func shows(_ item: EditText, at t: Double, held: UUID?) -> Bool {
        if item.id == hold?.id { return true }
        if item.id == selected && !playing { return true }
        guard t >= item.from, t < item.to else { return false }
        return !(item.kind == "caption" && held != nil)
    }

    // MARK: text, captions and stickers

    private func textBox(_ item: EditText, frame r: CGRect, at t: Double) -> some View {
        let on: Bool = item.id == selected || item.id == hold?.id
        let scale: CGFloat = max(0.01, r.width / EditOverlays.design * CGFloat(item.size))
        let least: CGFloat = 44 / scale
        let line: Color = on ? Color.white.opacity(0.9) : Color.clear
        let middle = CGPoint(x: r.minX + CGFloat(item.x) * r.width, y: r.minY + CGFloat(item.y) * r.height)
        // (a count held still shows its number, not the 0 it counts up from)
        let moment: Double = item.kind == "calories" && !playing ? max(t, item.from + 1.3) : t
        // a line and a dot as thin at any size: drawn that much the thinner, then sized with it
        return EditTextView(item: item, at: moment)
            .padding(8 / scale)
            .frame(minWidth: least, minHeight: least)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 3 / scale).stroke(line, lineWidth: 1 / scale).allowsHitTesting(false))
            .overlay(alignment: .bottomTrailing) {
                if on { sizeDot(item, middle: middle, scale: scale) }
            }
            .scaleEffect(scale)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .updating($touching) { _, down, _ in down = true }
                .onChanged { (v: DragGesture.Value) in dragged(item, v.translation, frame: r) }
                .onEnded { _ in dragEnded(item) })
            .simultaneousGesture(MagnificationGesture()
                .onChanged { (m: CGFloat) in pinched(item, m) }
                .onEnded { _ in finish() })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.kind == "sticker" ? "Sticker \(item.text)" : item.barLabel)
            .accessibilityHint("Double tap to change it; drag to move it")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pick(item.id) }
            .position(middle)
    }

    private func sizeDot(_ item: EditText, middle: CGPoint, scale: CGFloat) -> some View {
        let catchSize: CGFloat = 32 / scale
        return Circle().fill(Color.white).frame(width: 10 / scale, height: 10 / scale)
            .frame(width: catchSize, height: catchSize)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .updating($touching) { _, down, _ in down = true }
                .onChanged { (v: DragGesture.Value) in cornered(item, v, middle: middle) }
                .onEnded { _ in finish() })
            .offset(x: catchSize / 2, y: catchSize / 2)
    }

    private func begun(_ item: EditText) {
        guard hold?.id != item.id else { return }
        // from where it's drawn, which can be over a voiceover's
        hold = Hold(id: item.id, start: item, live: item)
        held(true)
    }

    private func dragged(_ item: EditText, _ by: CGSize, frame r: CGRect) {
        if hold == nil {
            guard hypot(by.width, by.height) > 2 else { return }
            begun(item)
        }
        guard var h = hold, h.id == item.id, !h.sized else { return }
        let to: OverlayDrag.Place = OverlayDrag.place(fromX: h.start.x, fromY: h.start.y,
                                                     dx: Double(by.width), dy: Double(by.height),
                                                     width: Double(r.width), height: Double(r.height))
        if (to.middleX && !h.middleX) || (to.middleY && !h.middleY) { UISelectionFeedbackGenerator().selectionChanged() }
        h.live.x = to.x
        h.live.y = to.y
        h.middleX = to.middleX
        h.middleY = to.middleY
        h.moved = true
        hold = h
    }

    private func dragEnded(_ item: EditText) {
        if hold == nil { pick(item.id) } else { finish() }
    }

    private func pinched(_ item: EditText, _ m: CGFloat) {
        if hold == nil || hold?.sized == false {
            begun(item)
            guard var h = hold, h.id == item.id else { return }
            // (sized from here, put back where it was if the first finger had nudged it)
            h.sized = true
            h.pinch = max(m, 0.01)
            h.moved = false
            h.live.x = h.start.x
            h.live.y = h.start.y
            hold = h
        }
        guard var h = hold, h.id == item.id else { return }
        h.live.size = min(3, max(0.4, h.start.size * Double(m / h.pinch)))
        hold = h
    }

    private func cornered(_ item: EditText, _ v: DragGesture.Value, middle: CGPoint) {
        begun(item)
        guard var h = hold, h.id == item.id, !h.moved else { return }
        let was: CGFloat = max(8, hypot(v.startLocation.x - middle.x, v.startLocation.y - middle.y))
        let far: CGFloat = hypot(v.location.x - middle.x, v.location.y - middle.y)
        h.sized = true
        h.live.size = min(3, max(0.4, h.start.size * Double(far / was)))
        hold = h
    }

    private func finish() {
        if let h = hold {
            hold = nil
            let sized: Bool = h.sized && abs(h.live.size - h.start.size) > 0.001
            let moved: Bool = h.moved && (h.live.x != h.start.x || h.live.y != h.start.y)
            if moved || sized { placed(h.live, moved, sized) }
            held(false)
        }
        if pipHold != nil {
            pipHold = nil
            held(false)
        }
    }

    // MARK: clips and photos over it (drawn in the video itself)

    private func pipBox(_ p: EditPip, frame r: CGRect, at t: Double) -> some View {
        let m: MoveKey = pipHold?.id == p.id ? (pipHold?.live ?? p.place(at: t)) : p.place(at: t)
        let w: CGFloat = r.width * CGFloat(m.size)
        let h: CGFloat = w / CGFloat(max(p.aspect, 0.1))
        let line: Color = p.id == selectedPip ? Color.white : Color.white.opacity(0.01)
        let middle = CGPoint(x: r.minX + CGFloat(m.x) * r.width, y: r.minY + CGFloat(m.y) * r.height)
        return RoundedRectangle(cornerRadius: 4).stroke(line, lineWidth: 1)
            .contentShape(Rectangle())
            .frame(width: w, height: h)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .updating($touching) { _, down, _ in down = true }
                .onChanged { (v: DragGesture.Value) in pipDragged(p, m, v.translation, frame: r) }
                .onEnded { _ in
                    if pipHold == nil { pickPip(p.id) } else { finish() }
                })
            .simultaneousGesture(MagnificationGesture()
                .onChanged { (s: CGFloat) in pipPinched(p, m, s) }
                .onEnded { _ in finish() })
            .accessibilityLabel("Overlay")
            .accessibilityHint("Double tap to change it; drag to move it")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pickPip(p.id) }
            .position(middle)
    }

    private func pipDragged(_ p: EditPip, _ m: MoveKey, _ by: CGSize, frame r: CGRect) {
        if pipHold == nil {
            guard hypot(by.width, by.height) > 2 else { return }
            pipHold = PipHold(id: p.id, start: m, live: m)
            held(true)
        }
        guard var h = pipHold, h.id == p.id, !h.sized else { return }
        h.live.x = min(1, max(0, h.start.x + Double(by.width / max(r.width, 1))))
        h.live.y = min(1, max(0, h.start.y + Double(by.height / max(r.height, 1))))
        pipHold = h
        setPip(p.id, h.live)
    }

    private func pipPinched(_ p: EditPip, _ m: MoveKey, _ s: CGFloat) {
        if pipHold == nil {
            pipHold = PipHold(id: p.id, start: m, live: m)
            held(true)
        }
        guard var h = pipHold, h.id == p.id else { return }
        if !h.sized {
            h.sized = true
            h.pinch = max(s, 0.01)
        }
        h.live.size = min(1, max(0.12, h.start.size * Double(s / h.pinch)))
        pipHold = h
        setPip(p.id, h.live)
    }

    // MARK: what shows while it's dragged

    private func guides(_ h: Hold, frame r: CGRect) -> some View {
        let red: Color = Color.red.opacity(0.2)
        return ZStack(alignment: .topLeading) {
            // where a post's buttons and words cover it
            Path { (p: inout Path) in
                p.addRect(CGRect(x: r.maxX - r.width * 0.14, y: r.minY + r.height * 0.43, width: r.width * 0.14, height: r.height * 0.4))
                p.addRect(CGRect(x: r.minX, y: r.minY + r.height * 0.83, width: r.width, height: r.height * 0.17))
            }
            .fill(red)
            if h.middleX {
                Rectangle().fill(Color.yellow).frame(width: 1, height: r.height).offset(x: r.midX - 0.5, y: r.minY)
            }
            if h.middleY {
                Rectangle().fill(Color.yellow).frame(width: r.width, height: 1).offset(x: r.minX, y: r.midY - 0.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func corners(_ r: CGRect) -> some View {
        Path { (p: inout Path) in
            p.addRect(r)
            p.addRoundedRect(in: r, cornerSize: CGSize(width: 8, height: 8), style: .continuous)
        }
        .fill(Color.black, style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }
}

/// Picking a colour from the video: drag over it, the colour under the loupe taken as it goes.
struct VideoDropper: View {
    let engine: PreviewEngine
    let frameSize: CGSize
    let pick: (String) -> Void
    @State private var point: CGPoint?
    @State private var hex: String?

    var body: some View {
        GeometryReader { g in
            pad(MultiClipEditor.fitted(frameSize, in: g.size), size: g.size)
        }
    }

    private func pad(_ r: CGRect, size: CGSize) -> some View {
        let at: CGPoint = point ?? CGPoint(x: r.midX, y: r.minY + r.height * 0.4)
        return ZStack(alignment: .topLeading) {
            Color.clear
            loupe.position(x: min(max(40, at.x), max(40, size.width - 40)), y: max(52, at.y - 66))
            Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 12, height: 12).position(at)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { (v: DragGesture.Value) in moved(v.location, frame: r) })
        .accessibilityLabel("Drag to pick a colour from the video")
    }

    private var loupe: some View {
        let fill: Color = hex.map { (h: String) -> Color in StoryArt.color(h) } ?? Color.white.opacity(0.2)
        return VStack(spacing: 5) {
            Circle().fill(fill).frame(width: 62, height: 62)
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                .shadow(color: Color.black.opacity(0.5), radius: 6, y: 3)
            Text(hex ?? "Drag").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        }
        .allowsHitTesting(false)
    }

    private func moved(_ to: CGPoint, frame r: CGRect) {
        let p = CGPoint(x: min(r.maxX - 1, max(r.minX, to.x)), y: min(r.maxY - 1, max(r.minY, to.y)))
        point = p
        let fx: CGFloat = (p.x - r.minX) / max(r.width, 1)
        let fy: CGFloat = (p.y - r.minY) / max(r.height, 1)
        guard let found = engine.colour(x: fx, y: fy), found != hex else { return }
        hex = found
        pick(found)
    }
}
