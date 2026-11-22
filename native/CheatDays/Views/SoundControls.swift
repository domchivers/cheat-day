import SwiftUI

/// One keyframe on a strip: how far along it, and how loud, both 0 to 1.
struct StripKey: Equatable {
    var at: Double
    var level: Double
}

/// A sound along a strip with its keyframes and the line they make; drag along it to move the line, held on a
/// keyframe when it's near one.
struct KeyframeStrip: View {
    let levels: [Float]
    let colour: Color
    let keys: [StripKey]
    let line: Double?
    let scrub: (Double) -> Void
    @State private var held: Double?

    var body: some View {
        GeometryReader { g in
            strip(g.size)
        }
        .frame(height: 36)
        .accessibilityLabel("Drag to move the line along the sound")
    }

    private func strip(_ size: CGSize) -> some View {
        let w: CGFloat = max(size.width, 1), h: CGFloat = size.height
        let sorted: [StripKey] = keys.sorted { (a: StripKey, b: StripKey) -> Bool in a.at < b.at }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(white: 0.125))
            ProWave(levels: levels, colour: colour)
            levelLine(sorted, width: w, height: h)
            ForEach(sorted.indices, id: \.self) { (i: Int) in
                diamond.position(x: min(max(5, w * CGFloat(sorted[i].at)), w - 5), y: Self.y(sorted[i].level, height: h))
            }
            if let line {
                Rectangle().fill(Color.white).frame(width: 2, height: h + 6)
                    .offset(x: min(max(0, w * CGFloat(line) - 1), w - 2), y: -3)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { (v: DragGesture.Value) in moved(v.location.x, width: w, keys: sorted) }
            .onEnded { _ in held = nil })
    }

    private var diamond: some View {
        Rectangle().fill(ProInk.key).frame(width: 8, height: 8).rotationEffect(.degrees(45))
    }

    private static func y(_ level: Double, height: CGFloat) -> CGFloat {
        5 + (height - 10) * CGFloat(1 - min(1, max(0, level)))
    }

    private func levelLine(_ sorted: [StripKey], width w: CGFloat, height h: CGFloat) -> some View {
        Path { (p: inout Path) in
            guard let first = sorted.first, let last = sorted.last else { return }
            p.move(to: CGPoint(x: 0, y: Self.y(first.level, height: h)))
            for k in sorted { p.addLine(to: CGPoint(x: w * CGFloat(k.at), y: Self.y(k.level, height: h))) }
            p.addLine(to: CGPoint(x: w, y: Self.y(last.level, height: h)))
        }
        .stroke(Color.white, lineWidth: 1.2)
    }

    private func moved(_ x: CGFloat, width w: CGFloat, keys: [StripKey]) {
        var f: Double = Double(min(1, max(0, x / w)))
        let reach: Double = Double(10 / w)
        let near: StripKey? = keys.min { (a: StripKey, b: StripKey) -> Bool in abs(a.at - f) < abs(b.at - f) }
        if let near, abs(near.at - f) <= reach {
            f = near.at
            if held != f { UISelectionFeedbackGenerator().selectionChanged() }
            held = f
        } else if held != nil {
            held = nil
        }
        scrub(f)
    }
}

/// A fine wave across all the room there is.
struct ProWave: View {
    let levels: [Float]
    let colour: Color

    var body: some View {
        Canvas { (ctx: inout GraphicsContext, size: CGSize) in
            guard size.width > 2 else { return }
            let n: Int = max(1, Int(size.width / 3))
            for j in 0..<n {
                var level: CGFloat = 0
                if !levels.isEmpty { level = CGFloat(levels[min(levels.count - 1, j * levels.count / n)]) }
                let h: CGFloat = max(1, size.height * min(1, level))
                let bar = CGRect(x: CGFloat(j) * 3, y: (size.height - h) / 2, width: 1.5, height: h)
                ctx.fill(Path(bar), with: .color(colour))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A sound with its fades drawn on it, as they're dragged.
struct FadeWave: View {
    let levels: [Float]
    let colour: Color
    let fadeIn: Double      // parts of it, 0 to 1
    let fadeOut: Double

    var body: some View {
        ProWave(levels: levels, colour: colour)
            .overlay {
                GeometryReader { g in
                    shade(g.size)
                }
            }
            .frame(height: 30)
    }

    private func shade(_ size: CGSize) -> some View {
        let w: CGFloat = size.width, h: CGFloat = size.height
        return Path { (p: inout Path) in
            if fadeIn > 0.001 {
                p.move(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: w * CGFloat(min(1, fadeIn)), y: 0))
                p.addLine(to: .zero)
                p.closeSubpath()
            }
            if fadeOut > 0.001 {
                p.move(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: w * CGFloat(1 - min(1, fadeOut)), y: 0))
                p.addLine(to: CGPoint(x: w, y: 0))
                p.closeSubpath()
            }
        }
        .fill(ProInk.back.opacity(0.85))
        .allowsHitTesting(false)
    }
}

/// A sound's wave as it plays in the edit, a song's round again as it goes round.
struct SoundWaveLoader<Content: View>: View {
    let sound: EditSound
    @ViewBuilder let content: ([Float]) -> Content
    @State private var part: [Float] = []

    private static var count: Int { 180 }

    var body: some View {
        content(laid)
            .task(id: source) { await load() }
    }

    /// The part of its file that's read: all of a song's part, or what plays of anything else.
    private var bounds: (start: Double, end: Double) {
        if let first = sound.loopStart { return (first, sound.full) }
        let end: Double = sound.full > 0 ? min(sound.full, sound.fileTime(sound.to)) : sound.fileTime(sound.to)
        return (sound.start, end)
    }

    private var source: String {
        let b: (start: Double, end: Double) = bounds
        return "\(sound.url?.path ?? "")|\(b.start)|\(b.end)"
    }

    private func load() async {
        // (a moment first: trimmed, it's a different part at each step)
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, let url = sound.url else { return }
        let b: (start: Double, end: Double) = bounds
        guard b.end - b.start > 0.02 else { return }
        let read = Clip(source: url, length: b.end, start: b.start, end: b.end)
        let made: [Float] = await ClipJoin.levels(read, count: Self.count)
        if !Task.isCancelled { part = made }
    }

    private var laid: [Float] {
        let b: (start: Double, end: Double) = bounds
        return sound.waveAcross(part, from: b.start, to: b.end, count: Self.count)
    }
}

/// A song's beats along it: the ones that'll be cut on, tall and yellow.
struct BeatStrip: View {
    let levels: [Float]
    let beats: [Double]     // parts of it, 0 to 1
    let every: Int

    var body: some View {
        Canvas { (ctx: inout GraphicsContext, size: CGSize) in
            let step: Int = max(1, every)
            for (i, beat) in beats.enumerated() {
                let cut: Bool = i % step == 0
                let h: CGFloat = cut ? size.height : 9
                let tick = CGRect(x: size.width * CGFloat(beat), y: size.height - h, width: 1, height: h)
                ctx.fill(Path(tick), with: .color(cut ? ProInk.key : ProInk.key.opacity(0.5)))
            }
        }
        .background { ProWave(levels: levels, colour: Color(red: 0.42, green: 0.27, blue: 0.33)) }
        .frame(height: 40)
        .allowsHitTesting(false)
    }
}
