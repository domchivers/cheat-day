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
    @State private var leaving = false   // the cross tapped: asking before the edit is thrown away
    @State private var wasPlaying: Bool?   // while the scrub bar is dragged: whether it was playing before
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
        // (an alert, as the single editor asks: on iOS 26 a confirmation dialog hangs off its button)
        .alert("Discard this edit?", isPresented: $leaving) {
            Button("Discard", role: .destructive) { player.pause(); close() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("Your clips and the changes to them will be lost.") }
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

    // Laid out and drawn as the single video editor is (StoryEditor), so the two feel like one (19 Nov): round dark
    // buttons at the top, Done as its white pill, tools as its dark tiles, white trim handles and Next along the bottom.
    private var top: some View {
        HStack(spacing: 5) {
            // asked first: one tap on the cross threw the whole edit away (19 Nov)
            round("xmark", "Close") { if clips.isEmpty { close() } else { leaving = true } }
            if !history.isEmpty { round("arrow.uturn.backward", "Undo") { undo() } }
            Spacer()
            if panel != nil {
                Button { withAnimation(.snappy) { panel = nil } } label: {
                    Text("Done").font(.subheadline.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 16).frame(height: 34).background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func round(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var bottom: some View {
        VStack(spacing: 10) {
            // where it is and how long, said as the trim strip says it ("0:11 · 0:24 of 0:30")
            Text("\(Self.clock(now)) · \(Self.clock(total)) of \(Self.clock(limit))")
                .font(.caption.weight(.heavy)).monospacedDigit().foregroundStyle(total > limit + 0.05 ? Theme.warn : .white)
            if total > limit + 0.05 { Text("Over \(Int(limit)) seconds: the end will be cut. Trim or take out a clip.").font(.caption).foregroundStyle(Theme.warn) }
            switch panel {
            case .trim: if let i = index { trimPanel(i) }
            case .sound: if let i = index { soundPanel(i) }
            case nil:
                scrubBar; strip; actions
                Button { finish() } label: {
                    Text("Next").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 13).background(.white, in: Capsule())
                }
                .buttonStyle(.plain).disabled(clips.isEmpty || joining).padding(.top, 4)
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
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
        // the single editor's tool tile
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(height: 22)
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white).frame(maxWidth: 64).frame(height: 56)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).foregroundStyle(.white).disabled(!on).opacity(on ? 1 : 0.35)
    }

    // MARK: trim and sound

    private func trimPanel(_ i: Int) -> some View {
        let c = clips[i]
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Clip \(i + 1)"); Spacer(); Text("\(Self.clock(c.duration)) of \(Self.clock(c.length))").monospacedDigit() }
                .font(.caption).foregroundStyle(.secondary)
            RangeBar(length: c.length, start: c.start, end: c.end, colour: .white, background: { ClipThumb(clip: c, whole: true) }) { s, e in
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
                    RangeBar(length: c.length, start: c.heardStart, end: c.heardEnd, colour: .white, limits: c.start...c.end, background: { Bars(levels: levels[c.id] ?? []) }) { s, e in
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

    /// The whole video as one bar, a stretch for each clip, to drag along (19 Nov: it could only be played through or
    /// jumped to a clip's start, not scrubbed as a single video can). The preview follows the finger, held still;
    /// let go, it plays on if it was playing.
    private var scrubBar: some View {
        GeometryReader { g in
            let w = g.size.width, span = max(total, 0.01)
            ZStack(alignment: .leading) {
                // the clips' frames along it, as the single editor's strip shows its one clip's; the one picked lit
                HStack(spacing: 2) {
                    ForEach(clips) { c in
                        ClipThumb(clip: c)
                            .frame(width: max(2, w * CGFloat(c.duration / span) - 2), height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(c.id == selected || selected == nil ? 0 : 0.35)))
                    }
                }
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1))
                // where it is: yellow while a finger looks through it, as in the single editor; white as it plays
                Capsule().fill(wasPlaying != nil ? Color.yellow : Color.white).frame(width: 3.5, height: 52)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(x: min(max(0, w * CGFloat(now / span) - 1.75), w - 3.5))
            }
            .frame(width: w, height: 54)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if wasPlaying == nil { wasPlaying = player.rate != 0; player.pause() }
                    // (short of the very end, where the preview goes round to the start again)
                    let t = min(max(0, Double(v.location.x / max(w, 1)) * span), max(0, span - 0.12))
                    // close enough while the finger moves (a seek to the exact frame each time can't keep up), exact at the end
                    let near = CMTime(seconds: 0.04, preferredTimescale: 600)
                    player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: near, toleranceAfter: near)
                    now = t
                }
                .onEnded { _ in
                    seek(now)
                    if wasPlaying == true { player.play() }
                    wasPlaying = nil
                })
            .accessibilityElement()
            .accessibilityLabel("Where in the video")
            .accessibilityValue("\(Self.clock(now)) of \(Self.clock(total))")
            .accessibilityAdjustableAction { dir in
                seek(min(max(0, now + (dir == .increment ? 1 : -1)), max(0, total - 0.05)))
            }
        }
        .frame(height: 54)
    }

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
                // drawn as the single video editor's trim strip: dimmed outside what's kept, a light edge round it
                // all, white edges joining two white handles
                background().frame(width: w, height: g.size.height).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Color.black.opacity(0.6).frame(width: max(0, x0))
                Color.black.opacity(0.6).frame(width: max(0, w - x1)).offset(x: x1)
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1).frame(width: w, height: g.size.height).allowsHitTesting(false)
                Rectangle().fill(colour).frame(width: max(0, x1 - x0), height: 4).offset(x: x0, y: -g.size.height / 2 + 2).allowsHitTesting(false)
                Rectangle().fill(colour).frame(width: max(0, x1 - x0), height: 4).offset(x: x0, y: g.size.height / 2 - 2).allowsHitTesting(false)
                handle(at: x0, left: true) { x in changed(min(max(lo, x / w * span), end - 0.3), end) }
                handle(at: x1 - grip, left: false) { x in changed(start, max(min(hi, (x + grip) / w * span), start + 0.3)) }
            }
            .coordinateSpace(name: "range")   // the handles follow the finger along the bar
        }
    }

    private let grip: CGFloat = 18

    private func handle(at x: CGFloat, left: Bool, move: @escaping (CGFloat) -> Void) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 8 : 0, bottomLeadingRadius: left ? 8 : 0, bottomTrailingRadius: left ? 0 : 8, topTrailingRadius: left ? 0 : 8, style: .continuous)
            .fill(colour).frame(width: grip)
            .overlay(Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right").font(.system(size: 17, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
            // a thumb's width to catch it by, not just what shows
            .padding(.horizontal, 12).contentShape(Rectangle()).padding(.horizontal, -12)
            .offset(x: x)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("range"))
                .onChanged { v in if !dragging { dragging = true; began(); UISelectionFeedbackGenerator().selectionChanged() }; move(v.location.x) }
                .onEnded { _ in dragging = false })
            .accessibilityLabel(left ? "Start" : "End")
    }
}
