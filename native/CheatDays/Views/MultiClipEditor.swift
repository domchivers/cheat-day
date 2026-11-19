import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import SwiftUI

/// Several clips made into one video (19 Nov; design/multi-clip-editor-mockup.html): they play as one, along a strip
/// at the bottom, each as wide as it is long. Tap one to trim it, split it at the line, set its sound, copy or delete
/// it; hold and drag to move it; + for more. Next joins them (ClipJoin) and the editor carries on with the one video as
/// it does with any: text, stickers, the song and the look over all of it.
struct MultiClipEditor: View {
    @State var clips: [Clip]
    var limit: Double = ClipJoin.longest
    var close: () -> Void
    var done: (URL) -> Void

    @State private var selected: UUID?
    @State private var soundOf: UUID?          // one clip's sound over the whole video
    @State private var player = AVPlayer()
    @State private var now = 0.0               // where the preview is, in the joined video's seconds
    @State private var panel: Panel?
    @State private var joining = false
    @State private var history: [[Clip]] = []  // for Undo
    @State private var levels: [UUID: [Float]] = [:]
    @State private var watch: Any?
    @State private var adding = false
    @State private var picks: [PhotosPickerItem] = []
    private enum Panel { case trim, sound }
    private let perSecond: CGFloat = 14         // strip points a second

    private var total: Double { clips.reduce(0) { $0 + $1.duration } }
    private var index: Int? { clips.firstIndex { $0.id == selected } }
    private func startOf(_ i: Int) -> Double { clips[..<i].reduce(0) { $0 + $1.duration } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                top
                PlayerLayerView(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { if player.rate == 0 { player.play() } else { player.pause() } }
                bottom
            }
            if joining { Color.black.opacity(0.5).ignoresSafeArea(); ProgressView("Putting it together…").tint(.white).foregroundStyle(.white) }
        }
        .preferredColorScheme(.dark)
        // made again a moment after a change has settled (not for every step of a handle being dragged)
        .task(id: clips) { await settle() }
        .task(id: soundOf) { await settle() }
        .onDisappear { player.pause(); if let watch { player.removeTimeObserver(watch) } }
        // more from the library, onto the end, in the order picked
        .photosPicker(isPresented: $adding, selection: $picks, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: picks) { _, now in
            guard !now.isEmpty else { return }
            Task { let more = await Self.clips(from: now); picks = []; if !more.isEmpty { change { $0 + more } } } }
    }

    // MARK: top and bottom

    private var top: some View {
        HStack {
            Button { close() } label: { Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40).background(.white.opacity(0.12), in: Circle()) }
                .accessibilityLabel("Close")
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward").font(.headline).frame(width: 40, height: 40).background(.white.opacity(0.12), in: Circle()) }
                .disabled(history.isEmpty).opacity(history.isEmpty ? 0.4 : 1).accessibilityLabel("Undo")
            Spacer()
            Button(panel == nil ? "Next" : "Done") { if panel != nil { withAnimation(.snappy) { panel = nil } } else { finish() } }
                .font(.subheadline.weight(.bold)).padding(.horizontal, 18).frame(height: 40)
                .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
                .disabled(clips.isEmpty || joining)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).foregroundStyle(.white)
    }

    private var bottom: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Self.clock(now)).monospacedDigit()
                Spacer()
                Text("\(Self.clock(total)) of \(Self.clock(limit))").monospacedDigit().foregroundStyle(total > limit + 0.05 ? Theme.warn : .secondary)
            }
            .font(.caption)
            if total > limit + 0.05 { Text("Over \(Int(limit)) seconds: the end will be cut. Trim or take out a clip.").font(.caption).foregroundStyle(Theme.warn) }
            switch panel {
            case .trim: if let i = index { trimPanel(i) }
            case .sound: if let i = index { soundPanel(i) }
            case nil: strip; actions
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
        .background(Color(white: 0.05))
    }

    // MARK: the strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(clips) { c in
                    let on = c.id == selected
                    ClipThumb(clip: c)
                        .frame(width: max(30, CGFloat(c.duration) * perSecond), height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? Color.white : .clear, lineWidth: 2))
                        .overlay(alignment: .bottomLeading) {
                            HStack(spacing: 3) {
                                if !c.soundOn || c.still || (soundOf != nil && soundOf != c.id) { Image(systemName: "speaker.slash.fill") }
                                Text(Self.clock(c.duration))
                            }
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white).shadow(radius: 2).padding(4)
                        }
                        .onTapGesture { select(c.id) }
                        // hold and drag onto another to move it there
                        .draggable(c.id.uuidString)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let raw = ids.first, let from = clips.firstIndex(where: { $0.id.uuidString == raw }), let to = clips.firstIndex(of: c), from != to else { return false }
                            change { var all = $0; let moved = all.remove(at: from); all.insert(moved, at: to); return all }
                            return true
                        }
                        .accessibilityLabel("Clip \((clips.firstIndex(of: c) ?? 0) + 1), \(Self.clock(c.duration))")
                }
                Button { adding = true } label: {
                    Image(systemName: "plus").font(.title3).frame(width: 46, height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5])).foregroundStyle(.secondary))
                }
                .accessibilityLabel("Add clips")
            }
            .overlay(alignment: .leading) {
                // where the preview is
                Capsule().fill(.white).frame(width: 2, height: 70)
                    .offset(x: playheadX).allowsHitTesting(false)
            }
            .padding(.vertical, 6)
        }
    }

    /// The line's place on the strip: through the clips before it (with the gaps between them) and into this one.
    private var playheadX: CGFloat {
        var x: CGFloat = 0, left = now
        for c in clips {
            let w = max(30, CGFloat(c.duration) * perSecond)
            if left <= c.duration { return x + w * CGFloat(left / max(c.duration, 0.01)) }
            left -= c.duration; x += w + 4
        }
        return x
    }

    private var actions: some View {
        let has = index != nil
        return HStack {
            action("scissors", "Trim", on: has) { withAnimation(.snappy) { panel = .trim } }
            action("square.split.2x1", "Split", on: has) { splitHere() }
            action("speaker.wave.2", "Sound", on: has) { withAnimation(.snappy) { panel = .sound } }
            action("plus.square.on.square", "Copy", on: has) {
                guard let i = index else { return }
                change { var all = $0; var c = all[i]; c.id = UUID(); all.insert(c, at: i + 1); return all }
            }
            action("trash", "Delete", on: has && clips.count > 1) {
                guard let i = index else { return }
                change { var all = $0; all.remove(at: i); return all }
                selected = nil
            }
        }
        .padding(.top, 4)
    }

    private func action(_ icon: String, _ title: String, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 18)); Text(title).font(.caption2) }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain).foregroundStyle(.white).disabled(!on).opacity(on ? 1 : 0.35)
    }

    // MARK: trim and sound

    private func trimPanel(_ i: Int) -> some View {
        let c = clips[i]
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Clip \(i + 1)"); Spacer(); Text("\(Self.clock(c.duration)) of \(Self.clock(c.length))").monospacedDigit() }
                .font(.caption).foregroundStyle(.secondary)
            RangeBar(length: c.length, start: c.start, end: c.end, colour: Color(red: 1, green: 0.8, blue: 0.2), background: { ClipThumb(clip: c, whole: true) }) { s, e in
                clips[i].start = s; clips[i].end = e
                // its sound kept inside what's kept of the picture
                if let ss = clips[i].soundStart { clips[i].soundStart = max(s, min(ss, e)) }
                if let se = clips[i].soundEnd { clips[i].soundEnd = max(s, min(se, e)) }
            } began: { remember() }
            .frame(height: 58)
        }
    }

    private func soundPanel(_ i: Int) -> some View {
        let c = clips[i]
        return VStack(alignment: .leading, spacing: 10) {
            if c.still {
                Text("A photo has no sound of its own.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Toggle("Clip \(i + 1)'s sound", isOn: Binding(get: { clips[i].soundOn }, set: { v in remember(); clips[i].soundOn = v })).font(.subheadline)
                if c.soundOn {
                    // its sound as bars; the blue handles keep only part of it
                    RangeBar(length: c.length, start: c.heardStart, end: c.heardEnd, colour: Theme.accent, limits: c.start...c.end, background: { Bars(levels: levels[c.id] ?? []) }) { s, e in
                        clips[i].soundStart = s; clips[i].soundEnd = e
                    } began: { remember() }
                    .frame(height: 46)
                    .task(id: c.id) { if levels[c.id] == nil { levels[c.id] = await ClipJoin.levels(c) } }
                    HStack {
                        Text("Volume").font(.subheadline)
                        Slider(value: Binding(get: { Double(clips[i].volume) }, set: { clips[i].volume = Float($0) }), in: 0...1, onEditingChanged: { if $0 { remember() } })
                        Text("\(Int(clips[i].volume * 100))%").font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    HStack(spacing: 18) {
                        Toggle("Fade in", isOn: Binding(get: { clips[i].fadeIn }, set: { v in remember(); clips[i].fadeIn = v }))
                        Toggle("Fade out", isOn: Binding(get: { clips[i].fadeOut }, set: { v in remember(); clips[i].fadeOut = v }))
                    }
                    .font(.subheadline)
                    Toggle("Use this sound for the whole video", isOn: Binding(get: { soundOf == c.id }, set: { v in remember(); soundOf = v ? c.id : nil }))
                        .font(.subheadline.weight(.semibold)).tint(Theme.accent)
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: doing things

    private func select(_ id: UUID) {
        selected = selected == id ? nil : id
        if let i = clips.firstIndex(where: { $0.id == id }) { seek(startOf(i) + 0.01) }
    }

    /// The selected clip in two at the line (the line has to be inside it).
    private func splitHere() {
        guard let i = index else { return }
        let into = now - startOf(i)
        guard let (a, b) = ClipJoin.split(clips[i], at: into) else { return }
        change { var all = $0; all[i] = a; all.insert(b, at: i + 1); return all }
        selected = b.id
    }

    private func remember() { history.append(clips); if history.count > 30 { history.removeFirst() } }
    private func change(_ f: ([Clip]) -> [Clip]) { remember(); withAnimation(.snappy) { clips = f(clips) } }
    private func undo() { guard let last = history.popLast() else { return }; withAnimation(.snappy) { clips = last } }

    private func seek(_ s: Double) { player.seek(to: CMTime(seconds: max(0, s), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); now = s }

    /// The preview made again from the clips as they are now, kept where it was.
    @MainActor private func rebuild(play: Bool) async {
        guard let (comp, vc, mix) = await ClipJoin.compose(clips, soundOf: soundOf) else { return }
        let item = AVPlayerItem(asset: comp)
        item.videoComposition = vc; item.audioMix = mix
        let at = now
        player.replaceCurrentItem(with: item)
        if watch == nil {
            watch = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { t in
                MainActor.assumeIsolated {
                    now = t.seconds
                    // round again at the end
                    if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, t.seconds >= d - 0.05 { seek(0); player.play() }
                }
            }
        }
        seek(min(at, max(0, total - 0.05)))
        Sound.on(.moviePlayback)
        if play { player.play() }
    }

    private func settle() async {
        let first = player.currentItem == nil
        if !first { try? await Task.sleep(nanoseconds: 250_000_000) }
        guard !Task.isCancelled else { return }
        await rebuild(play: first)
    }

    private func finish() {
        joining = true; player.pause()
        let kept = clips, sound = soundOf
        Task {
            let url = await ClipJoin.join(kept, soundOf: sound)
            joining = false
            if let url { done(url) }
        }
    }

    /// Things picked from the library as clips, in the order picked: a video as it is, a photo as a short still.
    static func clips(from items: [PhotosPickerItem]) async -> [Clip] {
        var out: [Clip] = []
        for it in items {
            if it.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let m = try? await it.loadTransferable(type: PickedMovie.self) {
                if let c = await ClipJoin.clip(m.url) { out.append(c) }
            } else if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d), let url = await ClipJoin.still(img) {
                if let c = await ClipJoin.clip(url, still: true) { out.append(c) }
            }
        }
        return out
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(max(0, s)) / 60, Int(max(0, s)) % 60) }
}

/// A player's picture, filling its place.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class V: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> V { let v = V(); v.pl.videoGravity = .resizeAspect; v.pl.player = player; return v }
    func updateUIView(_ v: V, context: Context) { if v.pl.player !== player { v.pl.player = player } }
}

/// A clip's frames along it: what's kept of it, or `whole`, all of its file (under the trim handles).
struct ClipThumb: View {
    let clip: Clip
    var whole = false
    @State private var frames: [UIImage] = []
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(frames.indices, id: \.self) { i in
                    Image(uiImage: frames[i]).resizable().scaledToFill().frame(width: g.size.width / CGFloat(max(frames.count, 1)), height: g.size.height).clipped()
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .background(Color(white: 0.2))
            .task(id: "\(clip.source)|\(whole ? 0 : clip.start)|\(whole ? clip.length : clip.end)|\(Int(g.size.width))") {
                frames = await Self.frames(clip, whole: whole, count: max(1, min(8, Int(g.size.width / 40))))
            }
        }
    }
    static func frames(_ c: Clip, whole: Bool, count: Int) async -> [UIImage] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: c.source))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        let from = whole ? 0 : c.start, to = whole ? c.length : c.end
        var out: [UIImage] = []
        for i in 0..<count {
            let s = from + (to - from) * (Double(i) + 0.5) / Double(count)
            if let img = try? await gen.image(at: CMTime(seconds: s, preferredTimescale: 600)).image { out.append(UIImage(cgImage: img)) }
        }
        return out
    }
}

/// Bars for a clip's sound.
struct Bars: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.55)).frame(height: max(3, g.size.height * CGFloat(levels[i])))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(Color(white: 0.12))
    }
}

/// Two handles over something, setting a start and end inside `limits` (all of `length` unless said).
struct RangeBar<Back: View>: View {
    let length: Double
    let start: Double
    let end: Double
    let colour: Color
    var limits: ClosedRange<Double>? = nil
    @ViewBuilder var background: () -> Back
    let changed: (Double, Double) -> Void
    var began: () -> Void = {}
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, span = max(length, 0.01)
            let lo = limits?.lowerBound ?? 0, hi = limits?.upperBound ?? length
            let x0 = w * start / span, x1 = w * end / span
            ZStack(alignment: .leading) {
                background().frame(width: w, height: g.size.height).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Color.black.opacity(0.6).frame(width: max(0, x0))
                Color.black.opacity(0.6).frame(width: max(0, w - x1)).offset(x: x1)
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(colour, lineWidth: 3).frame(width: max(14, x1 - x0)).offset(x: x0)
                handle(at: x0) { x in changed(min(max(lo, x / w * span), end - 0.3), end) }
                handle(at: x1 - 12) { x in changed(start, max(min(hi, (x + 12) / w * span), start + 0.3)) }
            }
            .coordinateSpace(name: "range")   // the handles follow the finger along the bar
        }
    }

    private func handle(at x: CGFloat, move: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(colour).frame(width: 12)
            .overlay(Image(systemName: "line.3.horizontal").rotationEffect(.degrees(90)).font(.system(size: 8, weight: .bold)).foregroundStyle(.black))
            .offset(x: x)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("range"))
                .onChanged { v in if !dragging { dragging = true; began() }; move(v.location.x) }
                .onEnded { _ in dragging = false })
    }
}
