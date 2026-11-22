import SwiftUI

/// A template's words over its video as it plays, the slot being changed outlined.
struct TemplateWords: View {
    let clock: EditPlayhead
    let words: [EditText]
    let sounds: [EditSound]
    let frameSize: CGSize
    let outlined: Bool

    var body: some View {
        GeometryReader { g in
            layer(MultiClipEditor.fitted(frameSize, in: g.size), size: g.size)
        }
        .allowsHitTesting(false)
    }

    private func layer(_ r: CGRect, size: CGSize) -> some View {
        let t: Double = clock.time
        let placed: [EditText] = CaptionLayers.placed(words, sounds: sounds)
        let shown: [EditText] = placed.filter { (w: EditText) -> Bool in t >= w.from && t < w.to }
        return ZStack(alignment: .topLeading) {
            ForEach(shown) { (word: EditText) in drawn(word, frame: r, at: t) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func drawn(_ word: EditText, frame r: CGRect, at t: Double) -> some View {
        let scale: CGFloat = max(0.01, r.width / EditOverlays.design * CGFloat(word.size))
        let line: Color = outlined && word.part == "template" ? Color.white : Color.clear
        return EditTextView(item: word, at: t)
            .overlay(RoundedRectangle(cornerRadius: 12 / scale).stroke(line, lineWidth: 1 / scale))
            .scaleEffect(scale)
            .position(x: r.minX + CGFloat(word.x) * r.width, y: r.minY + CGFloat(word.y) * r.height)
    }
}

/// One slot along the sheet: its clip, how long it plays, what it's for.
struct TemplateSlotTile: View {
    let name: String
    let seconds: Double
    let clip: Clip?
    let on: Bool
    let pick: () -> Void
    let empty: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let line: Color = on ? Color.white : Color.clear
        return ZStack(alignment: .bottomLeading) {
            if let clip {
                ClipThumb(clip: clip)
            } else {
                shape.strokeBorder(Color(white: 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            Text(name).font(.system(size: 11, weight: .bold)).lineLimit(1)
                .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Color.clear, Color.black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: 84, height: 68)
        .clipShape(shape)
        .overlay(shape.strokeBorder(line, lineWidth: 1.5))
        .overlay(alignment: .topLeading) {
            Text(String(format: "%.1f", seconds)).font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
        .contentShape(Rectangle())
        .onTapGesture { pick() }
        .accessibilityElement()
        .accessibilityLabel(clip == nil ? "\(name), empty" : name)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
        .overlay(alignment: .topTrailing) {
            if on && clip != nil { emptyButton }
        }
    }

    private var emptyButton: some View {
        Button(action: empty) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .heavy))
                .frame(width: 18, height: 18).background(Color.black.opacity(0.7), in: Circle())
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Empty this slot")
    }
}

/// One of the clips to fill with, numbered by the slot it's in.
struct TemplateClipTile: View {
    let clip: Clip
    let number: Int?
    let on: Bool
    let pick: () -> Void
    @State private var picture: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let line: Color = on ? Color.white : Color.clear
        return Button(action: pick) {
            ZStack(alignment: .topTrailing) {
                ProInk.tile
                FillPicture(image: picture)
                if let number { numberBadge(number) }
                if !clip.still { length }
            }
            .frame(width: 62, height: 84)
            .clipShape(shape)
            .overlay(shape.strokeBorder(line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(number.map { (n: Int) -> String in "Clip in slot \(n)" } ?? "Clip")
        .task(id: "\(clip.source.path)|\(clip.start)") {
            let made: CGImage? = await PreviewArt.still(clip, at: clip.start)
            if !Task.isCancelled { picture = made }
        }
    }

    private func numberBadge(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 11, weight: .black)).foregroundStyle(Color.black)
            .frame(width: 18, height: 18).background(ProInk.key, in: Circle()).padding(4)
    }

    private var length: some View {
        Text(EditFlow.clock(clip.length)).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

/// Which moment of a clip plays in its slot: a window as long as the slot, dragged along the whole clip.
struct MomentWindow: View {
    let clip: Clip          // the whole of it
    let start: Double
    let lasts: Double       // of the file
    let held: (Bool) -> Void
    let moved: (Double) -> Void
    @State private var from: Double?
    @GestureState private var touching = false

    var body: some View {
        GeometryReader { g in
            strip(g.size)
        }
        .frame(height: 52)
        .accessibilityElement()
        .accessibilityLabel("Which part plays")
        .accessibilityValue("From \(EditFlow.clock(start))")
        .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
            held(true)
            moved(direction == .increment ? start + 0.5 : start - 0.5)
            held(false)
        }
    }

    private func strip(_ size: CGSize) -> some View {
        let w: CGFloat = max(size.width, 1), h: CGFloat = size.height
        let length: Double = max(clip.length, 0.01)
        let wide: CGFloat = min(w, max(22, w * CGFloat(min(1, lasts / length))))
        let room: Double = max(length - lasts, 0.001)
        let perPoint: Double = room / Double(max(w - wide, 1))
        let x: CGFloat = (w - wide) * CGFloat(min(1, max(0, start / room)))
        let dark = Color.black.opacity(0.65)
        return ZStack(alignment: .topLeading) {
            ClipThumb(clip: clip, whole: true).frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            dark.frame(width: x, height: h)
            dark.frame(width: max(0, w - x - wide), height: h).offset(x: x + wide)
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white, lineWidth: 3)
                .frame(width: wide, height: h + 4).offset(x: x, y: -2)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, on, _ in on = true }
            .onChanged { (v: DragGesture.Value) in dragged(v, x: x, wide: wide, perPoint: perPoint) }
            .onEnded { _ in letGo() })
        .onChange(of: touching) { (_: Bool, on: Bool) in
            if !on { letGo() }
        }
        .onDisappear { letGo() }
    }

    private func dragged(_ v: DragGesture.Value, x: CGFloat, wide: CGFloat, perPoint: Double) {
        if from == nil {
            let inside: Bool = v.startLocation.x >= x - 10 && v.startLocation.x <= x + wide + 10
            // (outside the window: it comes to the finger)
            from = inside ? start : Double(v.startLocation.x - wide / 2) * perPoint
            held(true)
        }
        moved((from ?? start) + Double(v.translation.width) * perPoint)
    }

    private func letGo() {
        guard from != nil else { return }
        from = nil
        held(false)
    }
}
