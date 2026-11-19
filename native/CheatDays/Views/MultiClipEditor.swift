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
    /// The frame's shape and fill, as the draft had it.
    var startLook: EditLook? = nil
    /// Its text, stickers and captions, and what's attached (a recipe, a workout), as the draft had them.
    var startTexts: [EditText]? = nil
    var startAttached: JSON? = nil
    /// Its voiceovers and sound effects, as the draft had them.
    var startSounds: [EditSound]? = nil
    /// The clips and photos over it, as the draft had them.
    var startPips: [EditPip]? = nil
    var close: () -> Void
    var done: (URL) -> Void
    /// The draft it's auto-saved as (a new edit gets one of its own once it's saved the first time).
    var autosaved: (String) -> Void = { _ in }
    /// Whoever opened it keeps the draft once it's made into a video (Make an edit lets it go when it's shared);
    /// otherwise the auto-saved draft is let go then.
    var keepsDraft = false
    /// A meal, recipe or workout picked in the editor (recipe and workout mode, the calorie count): for the post to carry.
    var attach: (JSON?) -> Void = { _ in }

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
    @State private var look = EditLook()          // the frame's shape and fill (Stage A2)
    @State private var proxies: [URL: URL] = [:]  // smaller copies of 4K clips, for the preview
    @State private var proxied: Set<URL> = []     // asked for already
    @State private var joinAt = 0                  // the join between this clip and the next being set
    @State private var progress: Float?            // how far the finished video's got, while it's made
    @State private var making: Task<Void, Never>?
    @State private var replacing = false
    @State private var replacePicks: [PhotosPickerItem] = []
    @State private var snapped: Double?            // the clip edge the line's held on while scrubbing
    @State private var lookTool = "Filters"
    @State private var tune = "b"
    @State private var texts: [EditText] = []       // over the edit, each for part of it (Stage B)
    @State private var selectedText: UUID?
    @State private var frameSize = CGSize(width: 1080, height: 1920)
    @State private var moveFrom: (Double, Double)?
    @State private var sizeFrom: Double?
    @State private var barGrab: BarGrab?
    @State private var attached: JSON?
    @State private var attachMode: String?           // "recipe", "workout", "calories": the picker open for it
    @State private var note: String?
    @State private var sounds: [EditSound] = []       // voiceovers and sound effects (Stage C)
    @State private var selectedSound: UUID?
    @State private var recorder = VoiceRecorder()
    @State private var recording = false
    @State private var holding = false
    @State private var recordFrom = 0.0
    @State private var clearVoice = true
    @State private var pips: [EditPip] = []             // clips and photos over it (Stage D)
    @State private var selectedPip: UUID?
    @State private var pipPicking = false
    @State private var pipPicks: [PhotosPickerItem] = []
    @State private var pipFrom: MoveKey?
    @State private var stripZoom: CGFloat = 1             // the strip pinched wider or narrower (Stage D)
    @State private var stripZoomFrom: CGFloat?
    @State private var choosingSong = false               // Stage E
    @State private var beatEvery = 2
    @State private var tip: Int?                          // the first-time tip showing
    private struct BarGrab { var id: UUID; var mode: Int; var from: Double; var to: Double; var words: [EditText.Word]?; var start = 0.0 }   // mode: 0 move, 1 start, 2 end
    /// One bar on the timeline: a text, sticker or caption, or a voiceover or sound effect.
    /// kind: 0 over the picture (text, stickers, captions), 1 a sound, 2 a clip or photo over it.
    private struct BarItem: Identifiable { let id: UUID; let from: Double; let to: Double; let label: String; let colour: Color; let kind: Int }
    private enum Panel { case trim, sound, speed, join, look, shape, text, stickers, voice, effects, soundItem, pip, motion, beats, templates }
    private var perSecond: CGFloat { 14 * stripZoom }   // strip points a second, pinched wider or narrower

    private var total: Double { ClipJoin.total(clips) }
    private var index: Int? { clips.firstIndex { $0.id == selected } }
    private func startOf(_ i: Int) -> Double { ClipJoin.starts(clips)[i] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                top
                PlayerLayerView(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { if player.rate == 0 { player.play() } else { player.pause() } }
                    .overlay { overlayLayer }
                    .overlay(alignment: .bottom) { if let tip { tipCard(tip) } }
                    .overlay(alignment: .top) {
                        if let note {
                            Text(note).font(.subheadline.weight(.semibold)).foregroundStyle(.black).multilineTextAlignment(.center)
                                .padding(.horizontal, 16).padding(.vertical, 10).background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .padding(.horizontal, 20).padding(.top, 8).transition(.opacity)
                        }
                    }
                bottom
                    // (kept on a view of its own, apart from the Add picker)
                    .photosPicker(isPresented: $replacing, selection: $replacePicks, maxSelectionCount: 1, matching: .any(of: [.images, .videos]))
            }
            if let progress {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 14) {
                    Text("Putting it together… \(Int((progress * 100).rounded()))%").font(.subheadline.weight(.semibold)).monospacedDigit()
                    ProgressView(value: Double(progress)).tint(.white).frame(width: 220)
                    Button("Cancel") { making?.cancel(); making = nil; self.progress = nil; joining = false }
                        .font(.subheadline.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 18).frame(height: 36).background(.white, in: Capsule())
                }
                .foregroundStyle(.white)
            } else if joining {
                Color.black.opacity(0.5).ignoresSafeArea(); ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        // (an alert, as the single editor asks: on iOS 26 a confirmation dialog hangs off its button)
        // keep it for later, let it go, or carry on (as Instagram asks when a post is left part done)
        .alert("Save this edit?", isPresented: $leaving) {
            Button("Save draft") {
                player.pause()
                let id = autoID ?? draftID, kept = clips, sound = soundOf, shape = look, over = texts, with = Self.data(attached), laid = sounds, on = pips
                EditDrafts.queue.async { EditDrafts.save(id: id, clips: kept, soundOf: sound, look: shape, texts: over, attached: with, sounds: laid, pips: on) }
                close()
            }
            Button("Discard", role: .destructive) {
                player.pause()
                let id = autoID ?? draftID, was = opened, sound = startSoundOf, shape = startLook, over = startTexts, with = Self.data(startAttached), laid = startSounds, on = startPips
                EditDrafts.queue.async {
                    guard let id else { return }
                    if let was { EditDrafts.save(id: id, clips: was, soundOf: sound, look: shape, texts: over, attached: with, sounds: laid, pips: on) } else { EditDrafts.delete(id) }
                }
                close()
            }
            Button("Keep editing", role: .cancel) {}
        } message: { Text(opened == nil ? "Keep it as a draft to finish later, or let it go." : "Save the changes to this draft, or leave it as it was.") }
        .onAppear {
            if soundOf == nil, let s = startSoundOf { soundOf = s }
            if let l = startLook, opened == nil { look = l }
            if let t = startTexts, opened == nil, texts.isEmpty { texts = t }
            if let v = startSounds, opened == nil, sounds.isEmpty { sounds = v }
            if let p = startPips, opened == nil, pips.isEmpty { pips = p }
            if let a = startAttached, attached == nil { attached = a; attach(a) }
            if autoID == nil { autoID = draftID }
            if draftID != nil, opened == nil { opened = clips }
        }
        // made again a moment after a change has settled (not for every step of a handle being dragged)
        .task(id: clips) { await settle(); await autosave() }
        .task(id: soundOf) { await settle(); await autosave() }
        .task(id: look) { await settle(); await autosave() }
        .task(id: texts) { await autosave() }
        .task(id: sounds) { await settle(); await autosave() }
        .task(id: pips) { await settle(); await autosave() }
        .sheet(isPresented: $choosingSong) { SongPicker { s in Task { @MainActor in await addSong(s) } } }
        .onAppear { if !UserDefaults.standard.bool(forKey: "editor.tips.1") { tip = 0 } }
        .onChange(of: pipPicks) { _, now in
            guard !now.isEmpty else { return }
            Task { let got = await Self.clips(from: now); pipPicks = []; if let c = got.first { await addPip(c) } }
        }
        .sheet(isPresented: Binding(get: { attachMode != nil }, set: { if !$0 { attachMode = nil } })) {
            AttachPicker(start: attachMode == "workout" ? 2 : (attachMode == "recipe" ? 1 : 0)) { picked($0) }
        }
        // a 4K clip played from a smaller copy while it's edited (the finished video's made from the file itself)
        .task(id: Set(clips.map { $0.source })) {
            for src in Set(clips.map { $0.source }) where !proxied.contains(src) {
                proxied.insert(src)
                if let p = await ClipJoin.proxy(src) { proxies[src] = p }
            }
        }
        .task(id: proxies.count) { if !proxies.isEmpty { await settle() } }
        .onDisappear {
            player.pause(); if let watch { player.removeTimeObserver(watch) }
            // the sound given back (19 Nov: left on, the feed's videos went on stopping their Spotify after an edit)
            Sound.off()
        }
        // more from the library, onto the end, in the order picked
        .photosPicker(isPresented: $adding, selection: $picks, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: replacePicks) { _, now in
            guard !now.isEmpty else { return }
            Task { let got = await Self.clips(from: now); replacePicks = []; if let c = got.first { replaceSelected(with: c) } }
        }
        .onChange(of: picks) { _, now in
            guard !now.isEmpty else { return }
            Task { let more = await Self.clips(from: now); picks = []; if !more.isEmpty { change { $0 + more } } } }
    }

    // MARK: top and bottom

    // Laid out and drawn as the single video editor is (StoryEditor), so the two feel like one (19 Nov): round dark
    // buttons at the top, Done as its white pill, tools as its dark tiles, white trim handles and Next along the bottom.
    private var top: some View {
        topRow
            // (on a view of its own, apart from the other pickers)
            .photosPicker(isPresented: $pipPicking, selection: $pipPicks, maxSelectionCount: 1, matching: .any(of: [.images, .videos]))
    }

    private var topRow: some View {
        HStack(spacing: 5) {
            // asked first: one tap on the cross threw the whole edit away (19 Nov)
            round("xmark", "Close") { if clips.isEmpty { close() } else { leaving = true } }
            if !history.isEmpty { round("arrow.uturn.backward", "Undo") { undo() } }
            if !future.isEmpty { round("arrow.uturn.forward", "Redo") { redo() } }
            Spacer()
            if panel == nil { round("aspectratio", "Shape and background") { withAnimation(.snappy) { panel = .shape } } }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// The open panel's bar (design/panel-tick-mockup.html): what it is, which clip, and a ✓ that closes it, as CapCut's.
    private var panelBar: some View {
        HStack(spacing: 6) {
            Text(panelTitle).font(.subheadline.weight(.bold)).foregroundStyle(.white)
            if !panelSub.isEmpty { Text(panelSub).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button {
                withAnimation(.snappy) { panel = nil; selectedText = nil; selectedSound = nil; selectedPip = nil }
            } label: {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 38, height: 38).background(.white, in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Done")
        }
        .padding(.horizontal, 2)
    }

    private var panelTitle: String {
        switch panel {
        case .trim: return "Trim"
        case .sound: return "Sound"
        case .speed: return "Speed"
        case .join: return "Transition"
        case .look: return "Filters"
        case .shape: return "Shape"
        case .text: return texts.first(where: { $0.id == selectedText })?.kind == "caption" ? "Caption" : "Text"
        case .stickers: return "Stickers"
        case .voice: return "Voiceover"
        case .effects: return "Sound effects"
        case .soundItem: return sounds.first(where: { $0.id == selectedSound })?.name ?? "Sound"
        case .pip: return "Overlay"
        case .motion: return "Motion"
        case .beats: return "Beats"
        case .templates: return "Templates"
        case nil: return ""
        }
    }

    /// Which clip (or join) the panel is for, when it's for one.
    private var panelSub: String {
        switch panel {
        case .trim, .sound, .speed, .look, .motion: return index.map { "Clip ($0 + 1)" } ?? ""
        case .join: return "Clips (joinAt + 1) and (joinAt + 2)"
        default: return ""
        }
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
            // each panel under its bar, whose ✓ closes it (20 Nov: Done at the top was too far away to find)
            case .trim: panelBar; if let i = index { trimPanel(i) }
            case .sound: scrubBar; panelBar; if let i = index { soundPanel(i) }
            case .speed: scrubBar; panelBar; if let i = index { speedPanel(i) }
            case .join: panelBar; if joinAt + 1 < clips.count { strip; joinPanel(joinAt) }
            case .look: scrubBar; panelBar; if let i = index { lookPanel(i) }
            case .shape: scrubBar; panelBar; shapePanel
            case .text: scrubBar; panelBar; if let k = texts.firstIndex(where: { $0.id == selectedText }) { bars; textPanel(k) }
            case .stickers: scrubBar; panelBar; stickerPanel
            case .voice: scrubBar; panelBar; bars; voicePanel
            case .effects: scrubBar; panelBar; effectsPanel
            case .soundItem: scrubBar; panelBar; if let k = sounds.firstIndex(where: { $0.id == selectedSound }) { bars; soundItemPanel(k) }
            case .pip: scrubBar; panelBar; if let k = pips.firstIndex(where: { $0.id == selectedPip }) { bars; pipPanel(k) }
            case .motion: scrubBar; panelBar; if let i = index { motionPanel(i) }
            case .beats: scrubBar; panelBar; strip; beatsPanel
            case .templates: panelBar; templatesPanel
            case nil:
                scrubBar
                if !texts.isEmpty || !sounds.isEmpty || !pips.isEmpty { bars }
                strip
                if selected == nil { addTools } else { actions }
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
                    let at = clips.firstIndex(of: c) ?? 0
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
                        .overlay(alignment: .trailing) { if at + 1 < clips.count { joinSquare(at).offset(x: 13) } }
                        .zIndex(Double(clips.count - at))
                }
                Button { adding = true } label: {
                    Image(systemName: "plus").font(.title3).frame(width: 46, height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5])).foregroundStyle(.secondary))
                }
                .accessibilityLabel("Add clips")
            }
            .simultaneousGesture(MagnificationGesture()
                .onChanged { m in
                    if stripZoomFrom == nil { stripZoomFrom = stripZoom }
                    stripZoom = min(4, max(0.4, (stripZoomFrom ?? 1) * m))
                }
                .onEnded { _ in stripZoomFrom = nil })
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
        let starts = ClipJoin.starts(clips)
        var x: CGFloat = 0
        for (i, c) in clips.enumerated() {
            let w = max(30, CGFloat(c.span) * perSecond)
            let next = i + 1 < clips.count ? starts[i + 1] : .infinity
            if now < next || i + 1 == clips.count { return x + w * CGFloat(min(1, max(0, (now - starts[i]) / max(c.span, 0.01)))) }
            x += w + 4
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
            action("backward.fill", "Reverse", on: moving) { reverseSelected() }
            action("camera.filters", "Filters", on: has) { withAnimation(.snappy) { panel = .look } }
            action("arrow.up.left.and.arrow.down.right", "Motion", on: has) { withAnimation(.snappy) { panel = .motion } }
            action("speaker.wave.2", "Sound", on: has) { withAnimation(.snappy) { panel = .sound } }
            action("arrow.triangle.2.circlepath", "Replace", on: has) { replacing = true }
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
                    soundTile("waveform.badge.magnifyingglass", "Clearer", on: c.clean != nil) { clearer(i) }
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
        selectedText = nil; selectedSound = nil; selectedPip = nil
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
                let starts = ClipJoin.starts(clips)
                ZStack(alignment: .leading) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                        ClipThumb(clip: c)
                            .frame(width: max(2, w * CGFloat(c.span / span) - 2), height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(c.id == selected || selected == nil ? 0 : 0.35)))
                            .offset(x: w * CGFloat(starts[i] / span))
                    }
                }
                .frame(width: w, height: 40, alignment: .leading).clipped()
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1))
                // the song's beats, as yellow ticks (Stage E)
                ForEach(songBeats.indices, id: \.self) { b in
                    Rectangle().fill(Color.yellow.opacity(0.8)).frame(width: 1, height: 10)
                        .offset(x: w * CGFloat(songBeats[b] / span), y: 22).allowsHitTesting(false)
                }
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
                    var t = min(max(0, Double(v.location.x / max(w, 1)) * span), max(0, span - 0.12))
                    // held on a clip's edge when it's near one, with a tick, as CapCut's line snaps
                    let reach = Double(10 / max(w, 1)) * span
                    let edges = ClipJoin.starts(clips).dropFirst()
                    if let e = edges.min(by: { abs($0 - t) < abs($1 - t) }), abs(e - t) < reach {
                        t = e
                        if snapped != e { snapped = e; UISelectionFeedbackGenerator().selectionChanged() }
                    } else { snapped = nil }
                    // close enough while the finger moves (a seek to the exact frame each time can't keep up), exact at the end
                    let near = CMTime(seconds: 0.04, preferredTimescale: 600)
                    player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: near, toleranceAfter: near)
                    now = t
                }
                .onEnded { _ in
                    snapped = nil
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
        guard let (comp, vc, mix) = await ClipJoin.compose(clips, soundOf: soundOf, look: look, swap: proxies, sounds: sounds, pips: pips) else { return }
        let item = AVPlayerItem(asset: comp)
        item.videoComposition = vc; item.audioMix = mix
        item.audioTimePitchAlgorithm = .spectral
        frameSize = vc.renderSize
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
        let id = autoID ?? UUID().uuidString.lowercased(), kept = clips, sound = soundOf, shape = look, over = texts, with = Self.data(attached), laid = sounds, on = pips
        if autoID == nil { autoID = id; autosaved(id) }
        EditDrafts.queue.async { EditDrafts.save(id: id, clips: kept, soundOf: sound, look: shape, texts: over, attached: with, sounds: laid, pips: on, tidy: false) }
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
        joining = true; progress = 0; player.pause()
        let kept = clips, sound = soundOf, shape = look, laid = sounds, on = pips
        let over = EditOverlays.pieces(texts, frame: frameSize)
        making = Task {
            let url = await ClipJoin.join(kept, soundOf: sound, look: shape, overlays: over, sounds: laid, pips: on) { p in if progress != nil { progress = p } }
            guard !Task.isCancelled else { return }
            joining = false; progress = nil; making = nil
            guard let url else { return }
            if !keepsDraft, let id = autoID { EditDrafts.queue.async { EditDrafts.delete(id) } }
            done(url)
        }
    }

    // MARK: Stage B: over the video

    /// Where the video is drawn in the preview (fitted, as the player draws it).
    static func fitted(_ frame: CGSize, in box: CGSize) -> CGRect {
        let aspect = frame.width / max(frame.height, 1)
        guard box.width > 0, box.height > 0 else { return .zero }
        if box.width / box.height > aspect {
            let w = box.height * aspect
            return CGRect(x: (box.width - w) / 2, y: 0, width: w, height: box.height)
        }
        let h = box.width / aspect
        return CGRect(x: 0, y: (box.height - h) / 2, width: box.width, height: h)
    }

    /// The overlays showing now, drawn as they'll be in the video; drag one to move it, pinch to size it, tap to change it.
    private var overlayLayer: some View {
        GeometryReader { g in
            let r = Self.fitted(frameSize, in: g.size), k = r.width / EditOverlays.design
            // a clip or photo over it: drawn in the video itself; here, something to drag and pinch where it is
            ForEach(pips) { p in
                if now >= p.from && now < p.to || p.id == selectedPip {
                    let m = p.place(at: now)
                    let w = r.width * m.size, h = w / max(p.aspect, 0.1)
                    RoundedRectangle(cornerRadius: 4).stroke(p.id == selectedPip ? Color.white : Color.white.opacity(0.01), lineWidth: 2)
                        .contentShape(Rectangle())
                        .frame(width: w, height: h)
                        .position(x: r.minX + m.x * r.width, y: r.minY + m.y * r.height)
                        .onTapGesture { selectPip(p.id) }
                        .accessibilityLabel("Overlay").accessibilityHint("Double tap to change it; drag to move it")
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { v in
                                if pipFrom == nil { pipFrom = m }
                                let start = pipFrom ?? m
                                setPip(p.id) { $0.x = min(1, max(0, start.x + Double(v.translation.width / max(r.width, 1))))
                                               $0.y = min(1, max(0, start.y + Double(v.translation.height / max(r.height, 1)))) }
                            }
                            .onEnded { _ in pipFrom = nil })
                        .simultaneousGesture(MagnificationGesture()
                            .onChanged { s in
                                if pipFrom == nil { pipFrom = m }
                                let start = pipFrom ?? m
                                setPip(p.id) { $0.size = min(1, max(0.12, start.size * Double(s))) }
                            }
                            .onEnded { _ in pipFrom = nil })
                }
            }
            ForEach(texts) { item in
                let on = item.id == selectedText
                if on || (now >= item.from && now < item.to) {
                    EditTextView(item: item, at: now).padding(24)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6])).foregroundStyle(on ? Color.white : Color.clear).padding(14))
                        .scaleEffect(k)
                        .position(x: r.minX + item.x * r.width, y: r.minY + item.y * r.height)
                        .onTapGesture { selectText(item.id) }
                        .accessibilityLabel(item.kind == "sticker" ? "Sticker \(item.text)" : item.barLabel)
                        .accessibilityHint("Double tap to change it; drag to move it")
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { v in
                                guard let i = texts.firstIndex(where: { $0.id == item.id }) else { return }
                                if moveFrom == nil { moveFrom = (texts[i].x, texts[i].y) }
                                let start = moveFrom ?? (item.x, item.y)
                                texts[i].x = min(0.95, max(0.05, start.0 + Double(v.translation.width / max(r.width, 1))))
                                texts[i].y = min(0.95, max(0.05, start.1 + Double(v.translation.height / max(r.height, 1))))
                            }
                            .onEnded { _ in moveFrom = nil })
                        .simultaneousGesture(MagnificationGesture()
                            .onChanged { m in
                                guard let i = texts.firstIndex(where: { $0.id == item.id }) else { return }
                                if sizeFrom == nil { sizeFrom = texts[i].size }
                                texts[i].size = min(3, max(0.4, (sizeFrom ?? 1) * Double(m)))
                            }
                            .onEnded { _ in sizeFrom = nil })
                }
            }
        }
    }

    private func selectText(_ id: UUID) {
        selected = nil
        selectedText = id
        player.pause()
        if let t = texts.first(where: { $0.id == id }), now < t.from || now >= t.to { seek(t.from + 0.01) }
        withAnimation(.snappy) { panel = .text }
    }

    /// What can be put over the video, when no clip is picked (the mockup's bottom row).
    private var addTools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                action("textformat", "Text", on: true) { addText() }
                action("face.smiling", "Stickers", on: true) { withAnimation(.snappy) { panel = .stickers } }
                action("captions.bubble", "Captions", on: true) { makeCaptions() }
                action("fork.knife", "Recipe", on: true) { attachMode = "recipe" }
                action("dumbbell", "Workout", on: true) { attachMode = "workout" }
                action("flame", "Calories", on: true) { attachMode = "calories" }
                action("mic.fill", "Voice", on: true) { withAnimation(.snappy) { panel = .voice } }
                action("sparkles", "Effects", on: true) { withAnimation(.snappy) { panel = .effects } }
                action("rectangle.inset.topright.filled", "Overlay", on: true) { pipPicking = true }
                action("music.note", "Music", on: true) { choosingSong = true }
                action("metronome", "Beats", on: true) { if songBeats.isEmpty { choosingSong = true } else { withAnimation(.snappy) { panel = .beats } } }
                action("square.grid.2x2", "Templates", on: true) { withAnimation(.snappy) { panel = .templates } }
            }
        }
        .padding(.top, 4)
    }

    /// Everything laid over the video as bars, in rows so none covers another: drag one along, or by an end for when it
    /// starts and stops; tap it to change it. Text and stickers, then the sounds.
    private var barItems: [BarItem] {
        texts.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: $0.barLabel, colour: $0.barColour, kind: 0) }
            + sounds.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: Self.soundMark($0.kind) + $0.name, colour: Self.soundColour($0.kind), kind: 1) }
            + pips.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: "▣ Overlay" + ($0.keys.isEmpty ? "" : " · ◆"), colour: Color(red: 0.36, green: 0.82, blue: 0.56), kind: 2) }
    }

    private var bars: some View {
        var rows: [[BarItem]] = []
        for t in barItems.sorted(by: { $0.from < $1.from }) {
            if let r = rows.firstIndex(where: { ($0.last?.to ?? 0) <= t.from + 0.01 && $0.last?.kind == t.kind }) { rows[r].append(t) } else { rows.append([t]) }
        }
        let shownRows = rows
        return GeometryReader { g in
            let w = g.size.width, span = max(total, 0.01)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(shownRows.indices, id: \.self) { r in
                        ZStack(alignment: .leading) {
                            ForEach(shownRows[r]) { item in bar(item, w: w, span: span) }
                        }
                        .frame(width: w, height: 18, alignment: .leading)
                    }
                }
            }
        }
        .frame(height: min(60, CGFloat(shownRows.count) * 21))
    }

    private func bar(_ item: BarItem, w: CGFloat, span: Double) -> some View {
        let x0 = w * CGFloat(min(item.from, span) / span), x1 = w * CGFloat(min(item.to, span) / span)
        let width = max(16, x1 - x0), on = item.id == selectedText || item.id == selectedSound || item.id == selectedPip
        return Text(item.label).font(.system(size: 9, weight: .heavy)).lineLimit(1).foregroundStyle(.black.opacity(0.8))
            .padding(.horizontal, 6).frame(width: width, height: 18, alignment: .leading)
            .background(item.colour, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(on ? Color.white : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture {
                switch item.kind {
                case 1: selectSound(item.id)
                case 2: selectPip(item.id)
                default: selectText(item.id)
                }
            }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if barGrab == nil {
                        // by its ends, or the middle to move it
                        let mode = v.startLocation.x < 12 ? 1 : (v.startLocation.x > width - 12 ? 2 : 0)
                        if item.kind == 1, let s = sounds.first(where: { $0.id == item.id }) {
                            barGrab = BarGrab(id: item.id, mode: mode, from: s.from, to: s.to, words: nil, start: s.start)
                        } else if item.kind == 2, let p = pips.first(where: { $0.id == item.id }) {
                            barGrab = BarGrab(id: item.id, mode: mode, from: p.from, to: p.to, words: nil, start: p.start)
                        } else if let t = texts.first(where: { $0.id == item.id }) {
                            barGrab = BarGrab(id: item.id, mode: mode, from: t.from, to: t.to, words: t.words)
                        }
                    }
                    guard let g = barGrab else { return }
                    let dt = Double(v.translation.width / max(w, 1)) * span
                    switch item.kind {
                    case 1: dragSound(g, dt, span: span)
                    case 2: dragPip(g, dt, span: span)
                    default: dragText(g, dt, span: span)
                    }
                }
                .onEnded { _ in barGrab = nil })
            .offset(x: x0)
            .accessibilityElement()
            .accessibilityLabel("\(item.label), \(Self.clock(item.from)) to \(Self.clock(item.to))")
            .accessibilityHint("Double tap to change it")
            .accessibilityAddTraits(.isButton)
    }

    private func dragText(_ g: BarGrab, _ dt: Double, span: Double) {
        guard let i = texts.firstIndex(where: { $0.id == g.id }) else { return }
        let length = g.to - g.from
        switch g.mode {
        case 1: texts[i].from = min(max(0, g.from + dt), g.to - 0.3)
        case 2: texts[i].to = max(min(span, g.to + dt), g.from + 0.3)
        default:
            let start = min(max(0, g.from + dt), max(0, span - length))
            texts[i].from = start; texts[i].to = start + length
            if let words = g.words {
                // a caption's words move with it
                let shift = start - g.from
                texts[i].words = words.map { EditText.Word(text: $0.text, at: $0.at + shift) }
            }
        }
        seek(g.mode == 2 ? max(0, texts[i].to - 0.05) : texts[i].from)
    }

    /// A sound's bar: moved along, its front trimmed off (its start in its own sound moving with it), or its end.
    private func dragSound(_ g: BarGrab, _ dt: Double, span: Double) {
        guard let i = sounds.firstIndex(where: { $0.id == g.id }) else { return }
        let length = g.to - g.from, whole = sounds[i].full > 0 ? sounds[i].full : g.start + length
        switch g.mode {
        case 1:
            let d = min(max(-g.start, dt), length - 0.3)
            sounds[i].from = max(0, g.from + d); sounds[i].start = g.start + d; sounds[i].length = length - d
        case 2:
            sounds[i].length = max(0.3, min(length + dt, whole - g.start, span - g.from))
        default:
            sounds[i].from = min(max(0, g.from + dt), max(0, span - 0.3))
        }
        seek(g.mode == 2 ? max(0, sounds[i].to - 0.05) : sounds[i].from)
    }

    // MARK: Stage C: voice and sound

    private func selectSound(_ id: UUID) {
        selected = nil; selectedText = nil
        selectedSound = id
        if let x = sounds.first(where: { $0.id == id }) { seek(x.from) }
        withAnimation(.snappy) { panel = .soundItem }
    }

    /// Voiceover: hold the button and talk; it records from the line while the video plays (its sound off, so the
    /// microphone hears only you), and lands as a bar.
    private var voicePanel: some View {
        VStack(spacing: 10) {
            Toggle("Clear voice (less background noise)", isOn: $clearVoice).font(.subheadline).tint(Theme.walk).disabled(recording)
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 66, height: 66)
                RoundedRectangle(cornerRadius: recording ? 8 : 24, style: .continuous).fill(Color(red: 1, green: 0.3, blue: 0.3))
                    .frame(width: recording ? 28 : 48, height: recording ? 28 : 48)
            }
            .frame(width: 80, height: 80).contentShape(Circle())
            .onLongPressGesture(minimumDuration: 100, maximumDistance: 80, perform: {}, onPressingChanged: { pressing in
                if pressing { startVoice() } else { stopVoice() }
            })
            .accessibilityLabel(recording ? "Recording: let go to stop" : "Hold to record a voiceover")
            Text(recording ? "Recording from \(Self.clock(recordFrom))… let go to stop" : "Hold to record from the line. The clips' sound dips while you talk.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func startVoice() {
        holding = true
        player.pause()
        Task {
            guard await VoiceRecorder.allowed() else { holding = false; flash("Voiceovers need the microphone: allow it in Settings › Cheat Days."); return }
            guard holding, !recording else { return }
            do {
                recordFrom = now
                try recorder.start(clear: clearVoice)
                recording = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                player.isMuted = true
                player.play()
            } catch {
                flash("Couldn't start recording.")
            }
        }
    }

    private func stopVoice() {
        holding = false
        guard recording else { return }
        recording = false
        player.pause(); player.isMuted = false
        if let (url, length) = recorder.stop() {
            let n = sounds.filter { $0.kind == "voice" }.count + 1
            let take = EditSound(kind: "voice", name: "Voice \(n)", file: url, from: recordFrom, length: max(0.3, min(length, total - recordFrom)), full: length)
            sounds.append(take)
            selectedSound = take.id
        }
        Sound.on(.moviePlayback)
    }

    /// A few short sounds to drop in at the line.
    private var effectsPanel: some View {
        VStack(spacing: 8) {
            Text("Tap one to put it in at the line").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(SoundEffects.names, id: \.self) { name in
                    Button {
                        let length = SoundEffects.length(name)
                        sounds.append(EditSound(kind: "effect", name: name, from: now, length: max(0.05, min(length, total - now)), full: length))
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Text(name).font(.caption.weight(.bold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 40)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A voiceover or effect picked: how loud, or taken off.
    private func soundItemPanel(_ k: Int) -> some View {
        let x = sounds[k]
        return VStack(spacing: 10) {
            HStack { Text(x.name).font(.subheadline.weight(.semibold)); Spacer(); Text("\(Int((x.volume * 100).rounded()))").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { sounds.indices.contains(k) ? Double(sounds[k].volume) : 0 }, set: { if sounds.indices.contains(k) { sounds[k].volume = Float($0) } }), in: 0...1).tint(.white)
            Button(role: .destructive) {
                let id = x.id
                withAnimation(.snappy) { panel = nil; selectedSound = nil }
                sounds.removeAll { $0.id == id }
            } label: {
                Label("Take it off", systemImage: "trash").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.warn)
        }
    }

    /// A clip's sound made clearer (Clarity), or back as it was.
    private func clearer(_ i: Int) {
        if clips[i].clean != nil { remember(); clips[i].clean = nil; return }
        let c = clips[i]
        joining = true; player.pause()
        Task {
            defer { joining = false }
            guard let url = await Clarity.clearer(c) else { flash("Couldn't make this clip's sound clearer."); return }
            guard let k = clips.firstIndex(where: { $0.id == c.id }) else { return }
            remember()
            clips[k].clean = url
            flash("Clearer: rumble and hum cut, voices lifted.")
        }
    }

    // MARK: Stage E: music, beats, templates, tips

    static func soundMark(_ kind: String) -> String { kind == "voice" ? "🎙 " : (kind == "song" ? "♫ " : "✦ ") }
    static func soundColour(_ kind: String) -> Color {
        switch kind {
        case "voice": return Color(red: 1, green: 0.48, blue: 0.48)
        case "song": return Color(red: 0.77, green: 0.63, blue: 1)
        default: return Color(red: 0.55, green: 0.85, blue: 0.85)
        }
    }

    /// The song's beats, in the video's seconds, while it plays.
    private var songBeats: [Double] {
        guard let s = sounds.first(where: { $0.kind == "song" }) else { return [] }
        return (s.beats ?? []).map { s.from + $0 - s.start }.filter { $0 >= s.from - 0.001 && $0 <= s.to }
    }

    /// A song from the app's music under the whole edit (one at a time), its beats found.
    private func addSong(_ s: Song) async {
        joining = true
        defer { joining = false }
        guard let mix = await SongMix.make(s, song: 1, clip: 1) else { flash("Couldn't get that song. Check your connection."); return }
        let beats = await Beats.find(mix.file, from: mix.from, length: mix.span)
        sounds.removeAll { $0.kind == "song" }
        sounds.append(EditSound(kind: "song", name: s.title, file: mix.file, from: 0, start: mix.from, length: max(0.5, min(mix.span, total)),
                                full: mix.from + mix.span, beats: beats))
        if beats.count > 2 { withAnimation(.snappy) { panel = .beats } } else { flash("Added \(s.title). No steady beat found in it to cut to.") }
    }

    /// Beats: the song's beats, and the clips cut to land on them.
    private var beatsPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text(sounds.first(where: { $0.kind == "song" })?.name ?? "No song").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Change song") { choosingSong = true }.font(.caption.weight(.bold)).foregroundStyle(.white)
            }
            HStack(spacing: 6) {
                chip("Every beat", on: beatEvery == 1) { beatEvery = 1 }
                chip("2 beats", on: beatEvery == 2) { beatEvery = 2 }
                chip("4 beats", on: beatEvery == 4) { beatEvery = 4 }
            }
            Button { cutToBeats(every: beatEvery) } label: {
                Label("Cut to beats", systemImage: "scissors").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 44)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain).disabled(songBeats.count < 3).opacity(songBeats.count < 3 ? 0.4 : 1)
            Text("\(songBeats.count) beats in the song, the yellow ticks above. Each clip is cut to end on one.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// Each clip cut to end on the next beat (every `n`th) after it starts, as long as it has that much in it.
    private func cutToBeats(every n: Int) {
        let grid = songBeats
        guard grid.count > 2 else { flash("No beat found in this song."); return }
        let cuts = stride(from: 0, to: grid.count, by: max(1, n)).map { grid[$0] }
        var all = clips, cursor = 0.0
        for i in all.indices {
            let c = all[i], rate = max(c.speed, 0.01)
            let most = (c.length - c.start) / rate
            if let end = cuts.first(where: { $0 > cursor + 0.4 && $0 - cursor <= most + 0.001 }) {
                all[i].end = min(c.length, c.start + (end - cursor) * rate)
                if let se = all[i].soundEnd { all[i].soundEnd = min(se, all[i].end) }
                if let ss = all[i].soundStart { all[i].soundStart = min(ss, all[i].end) }
            }
            cursor += all[i].span - ClipJoin.overlap(all, after: i)
        }
        change { _ in all }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        seek(0); player.play()
    }

    /// A ready-made edit the clips drop into (Stage E): a song, cut to its beat, the joins, a look, and titles.
    private struct Template {
        let name: String, about: String, icon: String, song: String, every: Int, join: String?, look: String, titles: [String], recipe: Bool
    }
    private static let templates = [
        Template(name: "Gym montage", about: "Cut to the beat, whips between clips, punchy colour", icon: "dumbbell",
                 song: "backbeat", every: 2, join: "Whip", look: "Vivid", titles: [], recipe: false),
        Template(name: "Cooking reel", about: "Warm colour, soft crossfades, your recipe's steps on it", icon: "fork.knife",
                 song: "city-sunshine", every: 4, join: "Crossfade", look: "Warm", titles: [], recipe: true),
        Template(name: "Day of eating", about: "A meal a clip, each labelled, sliding along", icon: "sun.max",
                 song: "be-chillin", every: 4, join: "Slide", look: "Pop", titles: ["Breakfast", "Lunch", "Snack", "Dinner", "Dessert"], recipe: false),
        Template(name: "Before and after", about: "Two clips, labelled, through black between", icon: "square.split.2x1",
                 song: "inspiration", every: 4, join: "Fade to black", look: "Normal", titles: ["Before", "After"], recipe: false),
    ]

    private var templatesPanel: some View {
        VStack(spacing: 8) {
            ForEach(Self.templates.indices, id: \.self) { k in
                let t = Self.templates[k]
                Button { Task { await apply(t) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.icon).font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.subheadline.weight(.bold))
                            Text(t.about).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            Text("Your clips stay as they are; the template sets the song, the cuts, the joins and the look. Undo takes the cuts back.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func apply(_ t: Template) async {
        withAnimation(.snappy) { panel = nil }
        if let s = Music.all.first(where: { $0.id == t.song }) { await addSong(s) }
        withAnimation(.snappy) { panel = nil }
        if songBeats.count > 2 { cutToBeats(every: t.every) }
        let kind = t.join, l = t.look
        change { all in
            var all = all
            for i in all.indices {
                all[i].look = l
                all[i].transition = i + 1 < all.count ? kind.map { ClipTransition(kind: $0, length: 0.4) } : nil
            }
            return all
        }
        // a title on each clip, near the top
        texts.removeAll { $0.kind == "text" && t.titles.contains($0.text) }
        let starts = ClipJoin.starts(clips)
        for i in clips.indices where i < t.titles.count {
            texts.append(EditText(kind: "text", text: t.titles[i], style: "Box", x: 0.5, y: 0.14, from: starts[i], to: starts[i] + clips[i].span))
        }
        if t.recipe { attachMode = "recipe" }
        flash("\(t.name): done. Change anything you like.")
    }

    /// The first time the editor's opened, three tips one after another.
    private static let tips = [
        "Tap a clip on the strip for its tools: trim, split, speed, filters, sound and more.",
        "With no clip picked, the row along the bottom adds text, captions, voice, music and more over the whole video.",
        "Everything added shows as a bar under the video: drag it along, or by an end, for when it shows.",
    ]

    private func tipCard(_ k: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.tips[k]).font(.subheadline.weight(.semibold)).foregroundStyle(.black).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(k + 1) of \(Self.tips.count)").font(.caption).foregroundStyle(.black.opacity(0.55))
                Spacer()
                Button(k + 1 < Self.tips.count ? "Next" : "Got it") {
                    withAnimation(.snappy) {
                        if k + 1 < Self.tips.count { tip = k + 1 } else { tip = nil; UserDefaults.standard.set(true, forKey: "editor.tips.1") }
                    }
                }
                .font(.subheadline.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 32).background(.black, in: Capsule())
            }
        }
        .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 18).padding(.bottom, 10)
        .transition(.opacity)
    }

    // MARK: Stage D: overlays and movement

    private func selectPip(_ id: UUID) {
        selected = nil; selectedText = nil; selectedSound = nil
        selectedPip = id
        if let p = pips.first(where: { $0.id == id }), now < p.from || now >= p.to { seek(p.from + 0.01) }
        withAnimation(.snappy) { panel = .pip }
    }

    /// A clip or photo picked to go over the edit, from the line: a photo made a still as long as what's left.
    private func addPip(_ picked: Clip) async {
        var c = picked
        if c.still, let img = await ClipJoin.frame(c, at: 0), let url = await ClipJoin.still(img, seconds: max(1, total - now)),
           let long = await ClipJoin.clip(url, still: true) { c = long }
        var aspect = 9.0 / 16.0
        if let v = try? await AVURLAsset(url: c.source).loadTracks(withMediaType: .video).first,
           let n = try? await v.load(.naturalSize), let tf = try? await v.load(.preferredTransform) {
            let up = CGRect(origin: .zero, size: n).applying(tf)
            if up.height != 0 { aspect = Double(abs(up.width) / abs(up.height)) }
        }
        let p = EditPip(source: c.source, start: c.start, length: max(0.3, min(c.duration, total - now)), from: now, full: c.length, aspect: aspect)
        pips.append(p)
        selectPip(p.id)
    }

    /// An overlay changed where the line is: with no keyframes, all of it; with some, the one at the line (made there
    /// if there isn't one), as CapCut's keyframes work.
    private func setPip(_ id: UUID, _ change: (inout MoveKey) -> Void) {
        guard let i = pips.firstIndex(where: { $0.id == id }) else { return }
        var m = pips[i].place(at: now)
        change(&m)
        if pips[i].keys.isEmpty {
            pips[i].x = m.x; pips[i].y = m.y; pips[i].size = m.size; pips[i].opacity = m.opacity
            return
        }
        let at = now - pips[i].from
        m.at = at
        if let k = pips[i].keys.firstIndex(where: { abs($0.at - at) < 0.12 }) { pips[i].keys[k] = m } else { pips[i].keys.append(m) }
    }

    private func dragPip(_ g: BarGrab, _ dt: Double, span: Double) {
        guard let i = pips.firstIndex(where: { $0.id == g.id }) else { return }
        let length = g.to - g.from, whole = pips[i].full > 0 ? pips[i].full : g.start + length
        switch g.mode {
        case 1:
            let d = min(max(-g.start, dt), length - 0.3)
            pips[i].from = max(0, g.from + d); pips[i].start = g.start + d; pips[i].length = length - d
        case 2:
            pips[i].length = max(0.3, min(length + dt, whole - g.start, span - g.from))
        default:
            pips[i].from = min(max(0, g.from + dt), max(0, span - 0.3))
        }
        seek(g.mode == 2 ? max(0, pips[i].to - 0.05) : pips[i].from)
    }

    /// An overlay picked: its size and see-through, a keyframe at the line, or taken off.
    private func pipPanel(_ k: Int) -> some View {
        let p = pips[k], m = p.place(at: now)
        let at = now - p.from
        let near = p.keys.firstIndex { abs($0.at - at) < 0.12 }
        let inside = now >= p.from && now < p.to
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("Size").font(.subheadline.weight(.semibold)).frame(width: 64, alignment: .leading)
                Slider(value: Binding(get: { pips.indices.contains(k) ? pips[k].place(at: now).size : 0.36 }, set: { v in setPip(p.id) { $0.size = v } }), in: 0.12...1).tint(.white)
            }
            HStack(spacing: 12) {
                Text("See-through").font(.subheadline.weight(.semibold)).frame(width: 64, alignment: .leading).lineLimit(1).minimumScaleFactor(0.7)
                Slider(value: Binding(get: { pips.indices.contains(k) ? pips[k].place(at: now).opacity : 1 }, set: { v in setPip(p.id) { $0.opacity = v } }), in: 0.1...1).tint(.white)
            }
            HStack(spacing: 10) {
                Button {
                    guard inside else { return }
                    if let near { pips[k].keys.remove(at: near) } else { var key = m; key.at = at; pips[k].keys.append(key) }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label(near != nil ? "Remove keyframe" : "Keyframe here", systemImage: near != nil ? "diamond.fill" : "diamond")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).foregroundStyle(near != nil ? Color.yellow : Color.white).disabled(!inside).opacity(inside ? 1 : 0.4)
                Button(role: .destructive) {
                    let id = p.id
                    withAnimation(.snappy) { panel = nil; selectedPip = nil }
                    pips.removeAll { $0.id == id }
                } label: {
                    Label("Take it off", systemImage: "trash").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.warn)
            }
            Text(p.keys.isEmpty ? "Drag it on the video to move it, pinch to size it. Add keyframes to make it move over time."
                 : "\(p.keys.count) keyframe\(p.keys.count == 1 ? "" : "s"): it moves and grows between them.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// A clip's movement: a slow zoom or drift from start to end, or its own zoom keyframed at the line.
    private func motionPanel(_ i: Int) -> some View {
        let c = clips[i], at = now - startOf(i)
        let inside = at >= -0.01 && at <= c.span + 0.01
        let m = MoveKey.value(c.moves, at: at, base: MoveKey(at: 0))
        let near = c.moves.firstIndex { abs($0.at - at) < 0.12 }
        return VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("Still", on: c.moves.isEmpty) { remember(); clips[i].moves = [] }
                    chip("Slow zoom in", on: false) { setMoves(i, [MoveKey(at: 0), MoveKey(at: c.span, size: 1.18)]) }
                    chip("Slow zoom out", on: false) { setMoves(i, [MoveKey(at: 0, size: 1.18), MoveKey(at: c.span)]) }
                    chip("Drift left", on: false) { setMoves(i, [MoveKey(at: 0, x: 0.54, size: 1.12), MoveKey(at: c.span, x: 0.46, size: 1.12)]) }
                    chip("Drift right", on: false) { setMoves(i, [MoveKey(at: 0, x: 0.46, size: 1.12), MoveKey(at: c.span, x: 0.54, size: 1.12)]) }
                }
            }
            HStack(spacing: 12) {
                Text("Zoom").font(.subheadline.weight(.semibold))
                Slider(value: Binding(get: { MoveKey.value(clips[i].moves, at: now - startOf(i), base: MoveKey(at: 0)).size },
                                      set: { v in setClipMove(i) { $0.size = v } }), in: 1...2, onEditingChanged: { if $0 { remember() } }).tint(.white)
                Button {
                    guard inside else { return }
                    remember()
                    if let near { clips[i].moves.remove(at: near) } else { var key = m; key.at = at; clips[i].moves.append(key) }
                } label: {
                    Image(systemName: near != nil ? "diamond.fill" : "diamond").font(.system(size: 18, weight: .bold))
                        .foregroundStyle(near != nil ? Color.yellow : Color.white).frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain).disabled(!inside).opacity(inside ? 1 : 0.4)
                .accessibilityLabel(near != nil ? "Remove the keyframe here" : "Add a keyframe here")
            }
            Text(c.moves.isEmpty ? "A slow zoom or drift makes a still shot feel alive." : "\(c.moves.count) keyframe\(c.moves.count == 1 ? "" : "s") on this clip.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setMoves(_ i: Int, _ keys: [MoveKey]) {
        remember(); clips[i].moves = keys
        seek(startOf(i) + 0.01); player.play()
    }

    /// The clip's zoom at the line: all of it with no keyframes (as one keyframe), the one at the line with some.
    private func setClipMove(_ i: Int, _ change: (inout MoveKey) -> Void) {
        let at = min(max(0, now - startOf(i)), clips[i].span)
        var m = MoveKey.value(clips[i].moves, at: at, base: MoveKey(at: 0))
        change(&m); m.at = at
        if clips[i].moves.isEmpty { clips[i].moves = [m]; return }
        if let k = clips[i].moves.firstIndex(where: { abs($0.at - at) < 0.12 }) { clips[i].moves[k] = m } else { clips[i].moves.append(m) }
    }

    private func addText() {
        player.pause()
        let t = EditText(kind: "text", text: "Your text", from: now, to: min(max(total, now + 0.5), now + 3))
        texts.append(t)
        selectText(t.id)
    }

    private func addSticker(_ emoji: String) {
        let t = EditText(kind: "sticker", text: emoji, x: 0.5, y: 0.4, from: now, to: min(max(total, now + 0.5), now + 3))
        texts.append(t)
        selectText(t.id)
    }

    private func flash(_ text: String) {
        withAnimation { note = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { withAnimation { if note == text { note = nil } } }
    }

    /// Captions from what's said in it, made on the phone; ones made before are replaced.
    private func makeCaptions() {
        player.pause(); joining = true
        let kept = clips, sound = soundOf
        Task {
            defer { joining = false }
            do {
                let made = try await EditOverlays.captions(kept, soundOf: sound)
                texts.removeAll { $0.kind == "caption" }
                texts += made
                flash("\(made.count) caption\(made.count == 1 ? "" : "s") made. Tap one to fix a word.")
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    /// A meal, recipe or workout picked for a mode: its overlays made, and it goes with the post.
    private func picked(_ what: JSON) {
        let mode = attachMode
        attachMode = nil
        switch mode {
        case "recipe":
            texts.removeAll { $0.kind == "step" || $0.kind == "macros" }
            texts += EditOverlays.recipe(what, clips: clips)
            if str(what["kind"]) != "meal" { flash("A food has no steps: its macros are on the last clip. Pick a saved meal or recipe for steps.") }
        case "workout":
            guard str(what["kind"]) == "workout" else { flash("Pick a workout for workout mode."); return }
            texts.removeAll { $0.kind == "workout" }
            let made = EditOverlays.workout(what, clips: clips)
            texts += made
            if made.isEmpty { flash("That workout has no exercises with sets to show.") }
        default:
            let m = what["macros"] as? JSON ?? [:], p = Int(num(m["p"]) ?? 0)
            let t = EditText(kind: "calories", text: str(what["name"]), detail: p > 0 ? "\(p) g protein" : "", x: 0.5, y: 0.42,
                             from: now, to: min(max(total, now + 0.5), now + 4), number: num(what["kcal"]) ?? 0)
            texts.removeAll { $0.kind == "calories" }
            texts.append(t)
            selectText(t.id)
        }
        attached = what
        attach(what)
    }

    /// A text, sticker or caption picked: its words, look, colour and size, or taken off.
    private func textPanel(_ k: Int) -> some View {
        let item = texts[k]
        return VStack(spacing: 10) {
            if item.kind == "sticker" {
                stickerGrid { e in texts[k].text = e }
            } else if item.kind != "calories" {
                TextField(item.kind == "caption" ? "What's said" : "Text", text: Binding(get: { texts.indices.contains(k) ? texts[k].text : "" }, set: { if texts.indices.contains(k) { setText(k, $0) } }), axis: .vertical)
                    .lineLimit(1...3).padding(10).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if item.kind == "text" {
                HStack(spacing: 6) { ForEach(EditText.textStyles, id: \.self) { st in chip(st, on: item.style == st) { texts[k].style = st } } }
                HStack(spacing: 10) {
                    ForEach(EditText.colours, id: \.self) { c in
                        Circle().fill(EditText.colour(c)).frame(width: 26, height: 26)
                            .overlay(Circle().stroke(.white, lineWidth: item.colour == c ? 3 : 1))
                            .onTapGesture { texts[k].colour = c }
                            .accessibilityLabel(c)
                    }
                    Spacer()
                }
            }
            if item.kind == "caption" {
                HStack(spacing: 6) {
                    ForEach(EditText.captionStyles, id: \.self) { st in
                        chip(st, on: item.style == st) { for i in texts.indices where texts[i].kind == "caption" { texts[i].style = st } }
                    }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                Slider(value: Binding(get: { texts.indices.contains(k) ? texts[k].size : 1 }, set: { if texts.indices.contains(k) { texts[k].size = $0 } }), in: 0.4...3).tint(.white)
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                let id = item.id
                withAnimation(.snappy) { panel = nil; selectedText = nil }
                texts.removeAll { $0.id == id }
            } label: {
                Label("Take it off", systemImage: "trash").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.warn)
        }
    }

    /// A caption's words changed: kept at their times when the count's the same, spread evenly through it otherwise.
    private func setText(_ k: Int, _ value: String) {
        texts[k].text = value
        guard texts[k].kind == "caption" else { return }
        let parts = value.split(separator: " ").map(String.init)
        let old = texts[k].words ?? []
        if parts.count == old.count {
            texts[k].words = zip(parts, old).map { EditText.Word(text: $0.0, at: $0.1.at) }
        } else if !parts.isEmpty {
            let a = texts[k].from, step = (texts[k].to - a) / Double(parts.count)
            texts[k].words = parts.indices.map { EditText.Word(text: parts[$0], at: a + step * Double($0)) }
        }
    }

    private var stickerPanel: some View {
        VStack(spacing: 8) {
            Text("Tap one to put it on at the line").font(.caption).foregroundStyle(.secondary)
            stickerGrid { addSticker($0) }
        }
    }

    private func stickerGrid(_ tap: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(EditText.stickers, id: \.self) { e in
                Button { tap(e) } label: {
                    Text(e).font(.system(size: 26)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func data(_ j: JSON?) -> Data? { j.flatMap { try? JSONSerialization.data(withJSONObject: $0) } }

    // MARK: Stage A2

    /// The square between two clips (design/editor-all-tools-mockup.html, 3): what's set, or + for a straight cut.
    private func joinSquare(_ i: Int) -> some View {
        let set = clips[i].transition != nil
        return Button {
            joinAt = i
            withAnimation(.snappy) { panel = .join }
        } label: {
            Image(systemName: set ? "arrow.left.arrow.right" : "plus").font(.system(size: 9, weight: .black))
                .foregroundStyle(set ? Color.black : Color.white).frame(width: 22, height: 22)
                .background(set ? Color.white : Color(white: 0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.black.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(set ? "Transition between clips \(i + 1) and \(i + 2): \(clips[i].transition?.kind ?? "")" : "Add a transition between clips \(i + 1) and \(i + 2)")
    }

    /// How one clip turns into the next, how long it takes, and the same for every join.
    private func joinPanel(_ i: Int) -> some View {
        let tr = clips[i].transition
        let most = max(0.2, min(1.5, clips[i].span / 2, clips[i + 1].span / 2))
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("None", on: tr == nil) { setJoin(i, nil) }
                    ForEach(ClipTransition.kinds, id: \.self) { k in
                        chip(k, on: tr?.kind == k) { setJoin(i, ClipTransition(kind: k, length: min(tr?.length ?? 0.5, most))) }
                    }
                }
            }
            if let tr {
                HStack { Text("Length").font(.subheadline.weight(.semibold)); Spacer(); Text(String(format: "%.1f s", min(tr.length, most))).font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
                Slider(value: Binding(get: { min(clips[i].transition?.length ?? 0.5, most) }, set: { clips[i].transition?.length = $0 }),
                       in: 0.2...max(0.21, most), onEditingChanged: { if $0 { remember() } }).tint(.white)
                Button {
                    change { all in
                        var all = all
                        for k in all.indices.dropLast() { all[k].transition = tr }
                        return all
                    }
                } label: {
                    Label("Apply to all", systemImage: "square.stack.3d.down.right").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).foregroundStyle(.white)
            }
        }
        .onAppear { seek(max(0, startOf(i + 1) - 0.6)); player.play() }
    }

    private func setJoin(_ i: Int, _ tr: ClipTransition?) {
        change { all in var all = all; all[i].transition = tr; return all }
        // shown straight away: from just before it
        if tr != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { seek(max(0, startOf(i + 1) - 0.6)); player.play() } }
    }

    /// The single editor's chip: white when it's the one picked.
    private func chip(_ title: String, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button { UISelectionFeedbackGenerator().selectionChanged(); run() } label: {
            Text(title).font(.caption.weight(.bold)).padding(.horizontal, 12).frame(height: 34)
                .foregroundStyle(on ? Color.black : Color.white)
                .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.55)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Filters and Adjust for a clip, as the single editor has them (StoryArt's looks), and the same for every clip.
    private func lookPanel(_ i: Int) -> some View {
        let parts = clips[i].look.split(separator: ";").map(String.init)
        let name = parts.first ?? "Normal"
        var tunes: [String: Double] = [:]
        for p in parts.dropFirst() {
            let kv = p.split(separator: "=")
            if kv.count == 2, let v = Double(kv[1]) { tunes[String(kv[0])] = v }
        }
        let known = tunes
        let adjustable = StoryArt.tunes.filter { $0.0 != "t" }   // (straightening is for a single picture)
        let row = adjustable.first { $0.0 == tune } ?? adjustable[0]
        return VStack(spacing: 10) {
            HStack(spacing: 6) {
                chip("Filters", on: lookTool == "Filters") { lookTool = "Filters" }
                chip("Adjust", on: lookTool == "Adjust") { lookTool = "Adjust" }
                Spacer()
                Button("Use for all") {
                    let l = clips[i].look
                    change { all in var all = all; for k in all.indices { all[k].look = l }; return all }
                }
                .font(.caption.weight(.bold)).foregroundStyle(.white)
            }
            if lookTool == "Filters" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(StoryArt.filters, id: \.self) { n in
                            chip(n, on: n == name) { remember(); clips[i].look = StoryArt.look(n, known) }
                        }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(adjustable.indices, id: \.self) { k in chip(adjustable[k].1, on: adjustable[k].0 == row.0) { tune = adjustable[k].0 } }
                    }
                }
                HStack {
                    Text(row.1).font(.subheadline.weight(.semibold)); Spacer()
                    Text("\(Int(known[row.0] ?? 0))").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { known[row.0] ?? 0 }, set: { v in
                    var next = known; next[row.0] = abs(v) < 2 ? 0 : v.rounded()
                    clips[i].look = StoryArt.look(name, next)
                }), in: row.3...row.4, onEditingChanged: { if $0 { remember() } }).tint(.white)
            }
        }
    }

    /// The frame's shape, and what's behind a clip of another shape.
    private var shapePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shape").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(EditLook.shapes, id: \.self) { sh in chip(sh == "Original" ? "First clip's" : sh, on: look.shape == sh) { look.shape = sh } }
            }
            Text("A clip of another shape").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            HStack(spacing: 6) {
                chip("Fill the frame", on: look.fill == "Fill") { look.fill = "Fill" }
                chip("Whole, blurred behind", on: look.fill == "Blur") { look.fill = "Blur" }
                chip("Whole, on black", on: look.fill == "Black") { look.fill = "Black" }
            }
        }
    }

    /// The selected clip played backwards (its sound off), or forwards again.
    private func reverseSelected() {
        guard let i = index else { return }
        let c = clips[i]
        if let f = c.forward {
            var back = c
            back.source = f.source; back.length = f.length
            back.start = max(0, f.end - c.end); back.end = min(f.length, f.end - c.start)
            back.forward = nil; back.soundOn = f.soundOn
            change { all in var all = all; all[i] = back; return all }
            return
        }
        joining = true; player.pause()
        Task {
            defer { joining = false }
            guard let url = await ClipJoin.reversed(c), let made = await ClipJoin.clip(url) else { return }
            var r = c
            r.source = url; r.length = made.length; r.start = 0; r.end = made.length
            r.forward = Forward(source: c.source, length: c.length, end: c.end, soundOn: c.soundOn)
            r.soundOn = false; r.keys = []; r.soundStart = nil; r.soundEnd = nil
            guard let k = clips.firstIndex(where: { $0.id == c.id }) else { return }
            change { all in var all = all; all[k] = r; return all }
        }
    }

    /// The selected clip swapped for another, keeping how long it was and what was set on it (as CapCut's Replace).
    private func replaceSelected(with new: Clip) {
        guard let i = index else { return }
        let old = clips[i]
        var c = new
        if !c.still { c.end = min(c.length, c.start + old.duration) }
        c.speed = c.still ? 1 : old.speed
        c.transition = old.transition; c.look = old.look
        if !c.still { c.volume = old.volume; c.fadeIn = old.fadeIn; c.fadeOut = old.fadeOut }
        change { all in var all = all; all[i] = c; return all }
        selected = c.id
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
