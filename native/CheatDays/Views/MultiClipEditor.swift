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
    /// The draft it was opened from (EditDrafts): saving goes over it.
    var draftID: String? = nil
    /// One clip's sound over everything, as the draft had it.
    var startSoundOf: UUID? = nil
    var close: () -> Void
    var done: (URL) -> Void
    /// The draft it's auto-saved as (a new edit gets one of its own once it's saved the first time).
    var autosaved: (String) -> Void = { _ in }
    /// Whoever opened it keeps the draft once it's made into a video (Make an edit lets it go when it's shared);
    /// otherwise the auto-saved draft is let go then.
    var keepsDraft = false

    @State private var selected: UUID?
    @State private var soundOf: UUID?          // one clip's sound over the whole video
    @State private var player = AVPlayer()
    @State private var now = 0.0               // where the preview is, in the joined video's seconds
    @State private var panel: Panel?
    @State private var joining = false
    @State private var history: [[Clip]] = []  // for Undo
    @State private var future: [[Clip]] = []   // for Redo: what was undone
    @State private var autoID: String?           // the draft it's kept in as it goes (Stage A1)
    @State private var opened: [Clip]?           // as it was when opened from a draft: Discard goes back to it
    @State private var levels: [UUID: [Float]] = [:]
    @State private var watch: Any?
    @State private var adding = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var leaving = false   // the cross tapped: asking before the edit is thrown away
    @State private var wasPlaying: Bool?   // while the scrub bar is dragged: whether it was playing before
    @State private var soundTool: SoundTool = .volume   // which sound tool is open
    private enum SoundTool { case volume, fade }
    private enum Panel { case trim, sound, speed }
    private let perSecond: CGFloat = 14         // strip points a second

    private var total: Double { clips.reduce(0) { $0 + $1.span } }
    private var index: Int? { clips.firstIndex { $0.id == selected } }
    private func startOf(_ i: Int) -> Double { clips[..<i].reduce(0) { $0 + $1.span } }

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
        // keep it for later, let it go, or carry on (as Instagram asks when a post is left part done)
        .alert("Save this edit?", isPresented: $leaving) {
            Button("Save draft") {
                player.pause()
                let id = autoID ?? draftID, kept = clips, sound = soundOf
                EditDrafts.queue.async { EditDrafts.save(id: id, clips: kept, soundOf: sound) }
                close()
            }
            Button("Discard", role: .destructive) {
                player.pause()
                let id = autoID ?? draftID, was = opened, sound = startSoundOf
                EditDrafts.queue.async {
                    guard let id else { return }
                    if let was { EditDrafts.save(id: id, clips: was, soundOf: sound) } else { EditDrafts.delete(id) }
                }
                close()
            }
            Button("Keep editing", role: .cancel) {}
        } message: { Text(opened == nil ? "Keep it as a draft to finish later, or let it go." : "Save the changes to this draft, or leave it as it was.") }
        .onAppear {
            if soundOf == nil, let s = startSoundOf { soundOf = s }
            if autoID == nil { autoID = draftID }
            if draftID != nil, opened == nil { opened = clips }
        }
        // made again a moment after a change has settled (not for every step of a handle being dragged)
        .task(id: clips) { await settle(); await autosave() }
        .task(id: soundOf) { await settle(); await autosave() }
        .onDisappear {
            player.pause(); if let watch { player.removeTimeObserver(watch) }
            // the sound given back (19 Nov: left on, the feed's videos went on stopping their Spotify after an edit)
            Sound.off()
        }
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
            if !future.isEmpty { round("arrow.uturn.forward", "Redo") { redo() } }
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
            HStack(spacing: 14) {
                frameStep(-1)
                Text("\(Self.clock(now)) · \(Self.clock(total)) of \(Self.clock(limit))")
                    .font(.caption.weight(.heavy)).monospacedDigit().foregroundStyle(total > limit + 0.05 ? Theme.warn : .white)
                frameStep(1)
            }
            if total > limit + 0.05 { Text("Over \(Int(limit)) seconds: the end will be cut. Trim or take out a clip.").font(.caption).foregroundStyle(Theme.warn) }
            switch panel {
            case .trim: if let i = index { trimPanel(i) }
            case .sound: if let i = index { scrubBar; soundPanel(i) }
            case .speed: if let i = index { scrubBar; speedPanel(i) }
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
        HStack(spacing: 8) {
            allSound
            stripClips
        }
    }

    /// Every clip's sound off, or back on, at once (CapCut's "Mute clip audio" at the start of its timeline).
    private var allSound: some View {
        let any = clips.contains { $0.soundOn && !$0.still }
        return Button {
            remember()
            withAnimation(.snappy(duration: 0.2)) { for i in clips.indices where !clips[i].still { clips[i].soundOn = !any } }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: any ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Clip sound").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain).accessibilityLabel(any ? "Turn every clip's sound off" : "Turn every clip's sound on")
    }

    private var stripClips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(clips) { c in
                    let on = c.id == selected
                    // its picture, and its sound under it as a wave: green while it's heard, grey when it isn't (as CapCut shows it)
                    let heard = c.soundOn && !c.still && (soundOf == nil || soundOf == c.id)
                    VStack(spacing: 3) {
                        ClipThumb(clip: c)
                            .frame(height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? Color.white : .clear, lineWidth: 2))
                        Bars(levels: c.still ? [] : (levels[c.id] ?? []), colour: heard ? Theme.walk : Color.white.opacity(0.25))
                            .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .task(id: "\(c.id)|\(c.start)|\(c.end)") { if !c.still { levels[c.id] = await ClipJoin.levels(c, count: 24) } }
                    }
                    .frame(width: max(30, CGFloat(c.span) * perSecond))
                        .overlay(alignment: .bottomLeading) {
                            HStack(spacing: 3) {
                                if !c.soundOn || c.still || (soundOf != nil && soundOf != c.id) { Image(systemName: "speaker.slash.fill") }
                                if abs(c.speed - 1) > 0.001 { Text(Self.speedText(c.speed)) }
                                Text(Self.clock(c.span))
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
                        .accessibilityLabel("Clip \((clips.firstIndex(of: c) ?? 0) + 1), \(Self.clock(c.span))")
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
            let w = max(30, CGFloat(c.span) * perSecond)
            if left <= c.span { return x + w * CGFloat(left / max(c.span, 0.01)) }
            left -= c.span; x += w + 4
        }
        return x
    }

    private var actions: some View {
        let has = index != nil
        let moving = index.map { !clips[$0].still } ?? false
        return ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
            action("scissors", "Trim", on: has) { withAnimation(.snappy) { panel = .trim } }
            action("square.split.2x1", "Split", on: has) { splitHere() }
            action("gauge.with.dots.needle.67percent", "Speed", on: moving) { withAnimation(.snappy) { panel = .speed } }
            action("snowflake", "Freeze", on: moving) { freezeHere() }
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
        } }
        .padding(.top, 4)
    }

    private func action(_ icon: String, _ title: String, on: Bool, _ run: @escaping () -> Void) -> some View {
        // the single editor's tool tile
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(height: 22)
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white).frame(width: 60, height: 56)
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

    /// A clip's sound, as CapCut and Edits lay it out (19 Nov; design/edit-sound-drafts-mockup.html): the tools along
    /// the top (Volume, Fade, Mute, Use for all), the one picked open below.
    private func soundPanel(_ i: Int) -> some View {
        let c = clips[i]
        return VStack(spacing: 12) {
            if c.still {
                Text("A photo has no sound of its own.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                HStack(spacing: 8) {
                    soundTile("speaker.wave.2.fill", "Volume", on: soundTool == .volume) { soundTool = .volume }
                    soundTile("waveform.path", "Fade", on: soundTool == .fade) { soundTool = .fade }
                    soundTile(c.soundOn ? "speaker.slash" : "speaker.slash.fill", c.soundOn ? "Mute" : "Muted", on: !c.soundOn) {
                        remember(); clips[i].soundOn.toggle()
                    }
                    soundTile("music.note", "Use for all", on: soundOf == c.id) { remember(); soundOf = soundOf == c.id ? nil : c.id }
                }
                if !c.soundOn {
                    Text("This clip's sound is off. Tap Mute again to bring it back.").font(.caption).foregroundStyle(.secondary)
                } else if soundTool == .volume {
                    volumePanel(i)
                } else {
                    fadePanel(i)
                }
            }
        }
        .task(id: c.id) { if levels[c.id] == nil { levels[c.id] = await ClipJoin.levels(c) } }
    }

    /// The tool tile, white when it's the one picked (the single editor's tile otherwise).
    private func soundTile(_ icon: String, _ title: String, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button { UISelectionFeedbackGenerator().selectionChanged(); withAnimation(.snappy(duration: 0.2)) { run() } } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).frame(height: 22)
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Color.black : Color.white).frame(maxWidth: .infinity).frame(height: 56)
            .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.55)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Where the line is in the clip's own file, if the line is inside it.
    private func fileTime(_ i: Int) -> Double? {
        let into = now - startOf(i)
        guard into >= -0.01, into <= clips[i].span + 0.01 else { return nil }
        return clips[i].start + min(max(0, into) * clips[i].speed, clips[i].duration)
    }

    /// Volume: one big number and a slider; with keyframes, the number and slider are the level at the line, and
    /// the diamond adds one there (or takes away the one it's on), as CapCut's does.
    private func volumePanel(_ i: Int) -> some View {
        let c = clips[i], at = fileTime(i)
        let near = at.flatMap { t in c.keys.firstIndex { abs($0.at - t) < 0.15 } }
        let shown = c.keys.isEmpty ? c.volume : (at.map { c.level(at: $0) } ?? c.volume)
        return VStack(spacing: 8) {
            Text("\(Int((shown * 100).rounded()))").font(.system(size: 34, weight: .black, design: .rounded)).monospacedDigit()
            HStack(spacing: 12) {
                Slider(value: Binding(get: { Double(shown) }, set: { v in setVolume(i, Float(v)) }), in: 0...1,
                       onEditingChanged: { if $0 { remember() } })
                Button {
                    guard let at else { return }
                    remember()
                    if let near { clips[i].keys.remove(at: near) }
                    else { clips[i].keys.append(VolumeKey(at: at, volume: c.keys.isEmpty ? c.volume : c.level(at: at))) }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: near != nil ? "diamond.fill" : "diamond").font(.system(size: 18, weight: .bold))
                        .foregroundStyle(near != nil ? Color.yellow : Color.white).frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain).disabled(at == nil).opacity(at == nil ? 0.4 : 1)
                .accessibilityLabel(near != nil ? "Remove the keyframe here" : "Add a keyframe here")
            }
            // the clip's sound, its keyframes on it and the line where it is: tap a diamond to go to it
            GeometryReader { g in
                let w = g.size.width, span = max(c.duration, 0.01)
                ZStack(alignment: .leading) {
                    Bars(levels: levels[c.id] ?? []).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    ForEach(c.keys.indices, id: \.self) { k in
                        let x = w * CGFloat((c.keys[k].at - c.start) / span)
                        Image(systemName: "diamond.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.yellow)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .position(x: min(max(6, x), w - 6), y: g.size.height / 2)
                            .onTapGesture { seek(startOf(i) + (c.keys[k].at - c.start) / max(c.speed, 0.01)) }
                    }
                    if let at {
                        Capsule().fill(.white).frame(width: 2.5, height: g.size.height + 6)
                            .offset(x: min(max(0, w * CGFloat((at - c.start) / span) - 1.25), w - 2.5)).allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 34)
            Text(c.keys.isEmpty ? "Move the line along the bar above, then tap the diamond to set the volume at that moment."
                 : "\(c.keys.count) keyframe\(c.keys.count == 1 ? "" : "s"): the volume eases between them.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// The slider moved: the clip's volume, or with keyframes the one at the line (made there if there isn't one).
    private func setVolume(_ i: Int, _ v: Float) {
        guard !clips[i].keys.isEmpty, let at = fileTime(i) else { clips[i].volume = v; return }
        if let k = clips[i].keys.firstIndex(where: { abs($0.at - at) < 0.15 }) { clips[i].keys[k].volume = v }
        else { clips[i].keys.append(VolumeKey(at: at, volume: v)) }
    }

    /// Fade: how long it fades in and out, each up to 3 seconds (and never past half the clip).
    private func fadePanel(_ i: Int) -> some View {
        let most = max(0.1, min(3, clips[i].duration / 2))
        return VStack(spacing: 14) {
            fadeRow("Fade in", value: Binding(get: { min(clips[i].fadeIn, most) }, set: { clips[i].fadeIn = $0 }), most: most)
            fadeRow("Fade out", value: Binding(get: { min(clips[i].fadeOut, most) }, set: { clips[i].fadeOut = $0 }), most: most)
        }
        .padding(.top, 4)
    }

    private func fadeRow(_ title: String, value: Binding<Double>, most: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(value.wrappedValue < 0.05 ? "Off" : String(format: "%.1f s", value.wrappedValue)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...most, onEditingChanged: { if $0 { remember() } }).tint(.white)
        }
    }


    // MARK: doing things

    private func select(_ id: UUID) {
        selected = selected == id ? nil : id
        if let i = clips.firstIndex(where: { $0.id == id }) { seek(startOf(i) + 0.01) }
    }

    /// The selected clip in two at the line (the line has to be inside it).
    private func splitHere() {
        guard let i = index else { return }
        let into = (now - startOf(i)) * clips[i].speed
        guard let (a, b) = ClipJoin.split(clips[i], at: into) else { return }
        change { var all = $0; all[i] = a; all.insert(b, at: i + 1); return all }
        selected = b.id
    }

    private func remember() { history.append(clips); future = []; if history.count > 30 { history.removeFirst() } }
    private func change(_ f: ([Clip]) -> [Clip]) { remember(); withAnimation(.snappy) { clips = f(clips) } }
    private func undo() { guard let last = history.popLast() else { return }; future.append(clips); withAnimation(.snappy) { clips = last } }
    private func redo() { guard let next = future.popLast() else { return }; history.append(clips); withAnimation(.snappy) { clips = next } }

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
                            .frame(width: max(2, w * CGFloat(c.span / span) - 2), height: 40)
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
        item.audioTimePitchAlgorithm = .spectral
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

    /// Kept as a draft as it goes (Stage A1: a crash or a call loses nothing), a second after a change has settled.
    private func autosave() async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled, !clips.isEmpty else { return }
        let id = autoID ?? UUID().uuidString.lowercased(), kept = clips, sound = soundOf
        if autoID == nil { autoID = id; autosaved(id) }
        EditDrafts.queue.async { EditDrafts.save(id: id, clips: kept, soundOf: sound, tidy: false) }
    }

    /// A frame back or on (a 30th of a second), held still.
    private func frameStep(_ dir: Double) -> some View {
        Button {
            player.pause()
            seek(min(max(0, now + dir / 30), max(0, total - 0.05)))
        } label: {
            Image(systemName: dir < 0 ? "backward.frame.fill" : "forward.frame.fill").font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white).frame(width: 34, height: 28).background(.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(dir < 0 ? "A frame back" : "A frame on")
    }

    /// Speed (design/editor-all-tools-mockup.html): a quarter to four times, the clip on the strip as long as it now lasts.
    private func speedPanel(_ i: Int) -> some View {
        let c = clips[i]
        // the slider runs evenly through the halvings and doublings: 0.25, 0.5, 1, 2, 4
        let place = Binding<Double>(get: { log2(max(0.25, min(4, clips[i].speed))) }, set: { v in
            var x = (pow(2.0, v) * 20).rounded() / 20
            for stop in [0.25, 0.5, 1, 2, 4] where abs(log2(x) - log2(stop)) < 0.08 { x = stop }
            clips[i].speed = max(0.25, min(4, x))
        })
        return VStack(spacing: 6) {
            Text("Clip \(i + 1) speed").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(Self.speedText(c.speed)).font(.system(size: 34, weight: .black, design: .rounded)).monospacedDigit()
            Slider(value: place, in: -2...2, onEditingChanged: { if $0 { remember() } }).tint(.white)
            HStack { ForEach(["0.25×", "0.5×", "1×", "2×", "4×"], id: \.self) { Text($0) }.frame(maxWidth: .infinity) }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(String(format: "%.1f", c.duration)) s → \(String(format: "%.1f", c.span)) s · its sound keeps its pitch")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        }
    }

    /// The frame at the line held for 2 seconds, as a clip of its own put in there (the clip split round it).
    private func freezeHere() {
        guard let i = index, let at = fileTime(i) else { return }
        let c = clips[i], into = at - c.start
        joining = true; player.pause()
        Task {
            defer { joining = false }
            guard let img = await ClipJoin.frame(c, at: at), let url = await ClipJoin.still(img, seconds: 2),
                  let still = await ClipJoin.clip(url, still: true) else { return }   // (a still has no sound)
            if let (a, b) = ClipJoin.split(c, at: into) {
                change { var all = $0; all[i] = a; all.insert(contentsOf: [still, b], at: i + 1); return all }
            } else {
                // at an end of the clip: before it or after it
                let to = into < c.duration / 2 ? i : i + 1
                change { var all = $0; all.insert(still, at: to); return all }
            }
            selected = still.id
        }
    }

    static func speedText(_ x: Double) -> String {
        let r = (x * 100).rounded() / 100
        if r == r.rounded() { return "\(Int(r))×" }
        return (r * 10 == (r * 10).rounded() ? String(format: "%.1f", r) : String(format: "%.2f", r)) + "×"
    }

    private func finish() {
        joining = true; player.pause()
        let kept = clips, sound = soundOf
        Task {
            let url = await ClipJoin.join(kept, soundOf: sound)
            joining = false
            guard let url else { return }
            if !keepsDraft, let id = autoID { EditDrafts.queue.async { EditDrafts.delete(id) } }
            done(url)
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
    var colour: Color = Color.white.opacity(0.55)
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule().fill(colour).frame(height: max(3, g.size.height * CGFloat(levels[i])))
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
