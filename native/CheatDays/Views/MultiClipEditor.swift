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
    // The editor's own player (PreviewEngine, 21 Nov): plays the edit straight from the clips, drawn by EditPreviewView.
    @State private var player = PreviewEngine()
    @State private var now = 0.0               // where the preview is, in the joined video's seconds
    @State private var panel: Panel?
    @State private var joining = false
    /// What Undo goes back to: the clips, and the sounds over them (21 Nov: a sound separated from its clip has to
    /// come back with it).
    private struct Snap { var clips: [Clip]; var sounds: [EditSound] }
    @State private var history: [Snap] = []  // for Undo
    @State private var future: [Snap] = []   // for Redo: what was undone
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
    @State private var full = false                       // the preview full screen (design/bigger-preview-mockup.html)
    @State private var playing = false
    @State private var scrubFrom: Double?                 // where the timeline was when a finger began sliding it
    @State private var shownShape: String?                // what the preview playing was made of (its tracks)
    @State private var seeking = false                    // a seek on its way: the next waits for it
    @State private var chaseTo: Double?                   // where the finger's got to since
    @State private var dropped = 0                        // a bar let go: the preview made again then
    private struct TrimDrag { var side: Int; var dx: CGFloat }
    @State private var trimDrag: TrimDrag?
    // where the handle is drawn while it's held: back to nothing however the drag ends, cut short too (21 Nov: a drag
    // the timeline took over left the handle stranded, apart from its clip)
    @GestureState private var trimLive: TrimDrag?
    @State private var scrubSkip = false                  // this drag is a bar's or a trim handle's, not the timeline's                // an end of the picked clip being dragged on the timeline
    private struct BarGrab { var id: UUID; var mode: Int; var from: Double; var to: Double; var words: [EditText.Word]?; var start = 0.0 }   // mode: 0 move, 1 start, 2 end
    /// One bar on the timeline: a text, sticker or caption, or a voiceover or sound effect.
    /// kind: 0 over the picture (text, stickers, captions), 1 a sound, 2 a clip or photo over it.
    private struct BarItem: Identifiable { let id: UUID; let from: Double; let to: Double; let label: String; let colour: Color; let kind: Int }
    private enum Panel { case trim, sound, speed, join, look, shape, text, stickers, voice, effects, soundItem, pip, motion, beats, templates }
    private var perSecond: CGFloat { 30 * stripZoom }   // timeline points a second, pinched wider or narrower

    private var total: Double { ClipJoin.total(clips) }
    private var index: Int? { clips.firstIndex { $0.id == selected } }
    private func startOf(_ i: Int) -> Double { ClipJoin.starts(clips)[i] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if !full { top }
                // drawn by the app on every frame, the last real frame always up: never blank while the edit's made
                // again (21 Nov: Apple's player view flashed black each time)
                EditPreviewView(engine: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { togglePlay() }
                    .overlay { overlayLayer.allowsHitTesting(!full) }
                    .overlay(alignment: .bottom) { if let tip, !full { tipCard(tip) } }
                    .overlay(alignment: .topTrailing) {
                        if full {
                            round("arrow.down.right.and.arrow.up.left", "Leave full screen") { withAnimation(.snappy) { full = false } }
                                .padding(14)
                        }
                    }
                    .overlay(alignment: .bottom) { if full { fullBar } }
                    // full screen: a swipe down goes back
                    .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                        if full, v.translation.height > 80 { withAnimation(.snappy) { full = false } }
                    })
                    .overlay(alignment: .top) {
                        if let note {
                            Text(note).font(.subheadline.weight(.semibold)).foregroundStyle(.black).multilineTextAlignment(.center)
                                .padding(.horizontal, 16).padding(.vertical, 10).background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .padding(.horizontal, 20).padding(.top, 8).transition(.opacity)
                        }
                    }
                if !full {
                    bottom
                        // (kept on a view of its own, apart from the Add picker)
                        .photosPicker(isPresented: $replacing, selection: $replacePicks, maxSelectionCount: 1, matching: .any(of: [.images, .videos]))
                }
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
        .statusBarHidden(full)
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
        // (not while a bar's being dragged: made again under the finger, the preview stuttered (21 Nov); once it's let go)
        .task(id: sounds) { guard barGrab == nil else { return }; await settle(); await autosave() }
        .task(id: dropped) { if dropped > 0 { await settle(); await autosave() } }
        .task(id: pips) { guard barGrab == nil else { return }; await settle(); await autosave() }
        .sheet(isPresented: $choosingSong) { SongPicker { s in Task { @MainActor in await addSong(s) } } }
        .onAppear { if !UserDefaults.standard.bool(forKey: "editor.tips.1") { tip = 0 } }
        // (a trim handle's drag cut short, by another clip picked or a panel opened, leaves nothing behind)
        .onChange(of: selected) { _, _ in trimDrag = nil }
        .onChange(of: panel == nil) { _, _ in trimDrag = nil }
        // a handle's drag cut short (no end to it): nothing left held, the picture back where the line is
        .onChange(of: trimLive == nil) { _, gone in if gone, trimDrag != nil { trimDrag = nil; chaseTo = nil; seek(now) } }
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
            player.shutdown()
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

    /// The controls' sheet under the video (21 Nov, design/pro-ui/pro-editor-mockup.png): a shade off the black the
    /// video sits on, so the two don't run into each other.
    static let sheet = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let quiet = Color(white: 0.47)

    /// A plain icon button, as a pro editor's top bar has them; greyed when there's nothing to do.
    private func bare(_ symbol: String, _ label: String, size: CGFloat = 17, on: Bool = true, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium)).foregroundStyle(on ? Color.white : Color(white: 0.33))
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!on).accessibilityLabel(label)
    }

    private var topRow: some View {
        HStack(spacing: 6) {
            // asked first: one tap on the cross threw the whole edit away (19 Nov)
            bare("xmark", "Close") { if clips.isEmpty { close() } else { leaving = true } }
            bare("arrow.uturn.backward", "Undo", on: !history.isEmpty) { undo() }
            bare("arrow.uturn.forward", "Redo", on: !future.isEmpty) { redo() }
            Spacer()
            if panel == nil {
                // the shape it's made in, said, as a pro editor shows its frame size
                Button { withAnimation(.snappy) { panel = .shape } } label: {
                    HStack(spacing: 4) {
                        Text(look.shape)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Color(white: 0.8))
                    .padding(.horizontal, 9).frame(height: 26).background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityLabel("Shape and background: \(look.shape)")
            }
            // up here, as CapCut's Export (21 Nov: along the bottom it took room from the video)
            Button { finish() } label: {
                Text("Next").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 32).background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain).disabled(clips.isEmpty || joining).opacity(clips.isEmpty ? 0.5 : 1).padding(.leading, 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// A time as a pro editor shows it, minutes and seconds, always two of each ("00:09").
    static func code(_ s: Double) -> String { String(format: "%02d:%02d", Int(max(0, s)) / 60, Int(max(0, s)) % 60) }

    private func togglePlay() {
        if player.rate == 0 { player.play(); playing = true } else { player.pause(); playing = false }
    }

    /// At the top of the sheet, as a pro editor lays it: where it is of how long on the left, play in the middle, a
    /// frame back and on and full screen on the right.
    private var timeRow: some View {
        HStack(spacing: 0) {
            (Text(Self.code(now)).foregroundColor(.white)
             + Text(" / " + Self.code(total)).foregroundColor(total > limit + 0.05 ? Theme.warn : Self.quiet))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 112, alignment: .leading)
                .accessibilityLabel("\(Self.clock(now)) of \(Self.clock(total))")
            Spacer(minLength: 0)
            Button { togglePlay() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20)).foregroundStyle(.white)
                    .frame(width: 48, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(playing ? "Pause" : "Play")
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                frameStep(-1)
                frameStep(1)
                bare("arrow.up.left.and.arrow.down.right", "Full screen", size: 14) { withAnimation(.snappy) { full = true } }
            }
            .frame(width: 112, alignment: .trailing)
        }
        .frame(height: 36)
    }

    /// Full screen: play or pause, and how far through it is.
    private var fullBar: some View {
        HStack(spacing: 12) {
            Button { togglePlay() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel(playing ? "Pause" : "Play")
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: g.size.width * CGFloat(min(1, max(0, now / max(total, 0.01)))))
                }
            }
            .frame(height: 4)
            Text(Self.clock(now)).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.bottom, 18)
    }

    /// The open panel's bar (design/panel-tick-mockup.html): what it is, which clip, and a ✓ that closes it, as CapCut's.
    /// (21 Nov, design/pro-ui: ‹ and the ✓ both close it, a pro editor's header.)
    private var panelBar: some View {
        HStack(spacing: 6) {
            bare("chevron.left", "Back", size: 16) { closePanel() }
            Text(panelTitle).font(.subheadline.weight(.bold)).foregroundStyle(.white)
            if !panelSub.isEmpty { Text(panelSub).font(.caption).foregroundStyle(Self.quiet) }
            Spacer()
            Button { closePanel() } label: {
                Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Done")
        }
        .padding(.horizontal, -6)
    }

    private func closePanel() {
        withAnimation(.snappy) { panel = nil; selectedText = nil; selectedSound = nil; selectedPip = nil }
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
        case .trim, .sound, .speed, .look, .motion: return index.map { "Clip \($0 + 1)" } ?? ""
        case .join: return "Clips \(joinAt + 1) and \(joinAt + 2)"
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
            timeRow
            // (21 Nov: longer is allowed; it's only a post that's kept to the limit, and it asks which part when posted)
            if total > limit + 0.05 { Text("Longer than \(Int(limit)) seconds: you can save it all to Photos, but a post keeps \(Int(limit)) seconds.").font(.caption).foregroundStyle(Theme.warn).multilineTextAlignment(.center) }
            switch panel {
            // each panel under its bar, whose ✓ closes it (20 Nov: Done at the top was too far away to find)
            case .trim: panelBar; if let i = index { trimPanel(i) }
            case .sound: scrubBar; panelBar; if let i = index { soundPanel(i) }
            case .speed: scrubBar; panelBar; if let i = index { speedPanel(i) }
            case .join: panelBar; if joinAt + 1 < clips.count { timeline; joinPanel(joinAt) }
            case .look: scrubBar; panelBar; if let i = index { lookPanel(i) }
            case .shape: scrubBar; panelBar; shapePanel
            case .text: scrubBar; panelBar; if let k = texts.firstIndex(where: { $0.id == selectedText }) { bars; textPanel(k) }
            case .stickers: scrubBar; panelBar; stickerPanel
            case .voice: scrubBar; panelBar; bars; voicePanel
            case .effects: scrubBar; panelBar; effectsPanel
            case .soundItem: scrubBar; panelBar; if let k = sounds.firstIndex(where: { $0.id == selectedSound }) { bars; soundItemPanel(k) }
            case .pip: scrubBar; panelBar; if let k = pips.firstIndex(where: { $0.id == selectedPip }) { bars; pipPanel(k) }
            case .motion: scrubBar; panelBar; if let i = index { motionPanel(i) }
            case .beats: panelBar; timeline; beatsPanel
            case .templates: panelBar; templatesPanel
            case nil:
                // one timeline in place of the scrub bar, the bars and the strip (21 Nov: stacked, they left the video
                // a third of the screen)
                timeline
                if selected == nil { addTools } else { actions }
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 8)
        // on a sheet of its own, a shade off the video's black (design/pro-ui)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 18, style: .continuous)
                .fill(Self.sheet).ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: the timeline

    /// Every clip's sound off, or back on, at once (CapCut's "Mute clip audio" at the start of its timeline), in a
    /// column of its own at the timeline's left.
    private var allSound: some View {
        let any = clips.contains { $0.soundOn && !$0.still }
        return Button {
            remember()
            withAnimation(.snappy(duration: 0.2)) { for i in clips.indices where !clips[i].still { clips[i].soundOn = !any } }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: any ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size: 13, weight: .medium))
                Text("Clip\nsound").font(.system(size: 7.5, weight: .medium)).foregroundStyle(Self.quiet).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white).frame(width: 44, height: 58)
            .background(LinearGradient(stops: [.init(color: Self.sheet, location: 0.7), .init(color: Self.sheet.opacity(0), location: 1)],
                                       startPoint: .leading, endPoint: .trailing))
        }
        .buttonStyle(.plain).accessibilityLabel(any ? "Turn every clip's sound off" : "Turn every clip's sound on")
    }

    /// Where the timeline's line is: the player's own time while it plays, else where it was put.
    private var lineTime: Double {
        guard playing, scrubFrom == nil, barGrab == nil else { return now }
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : now
    }

    /// How many rows of bars the timeline shows under its clips.
    private var laneCount: Int { min(4, barRows.count) }
    private static let rulerHeight: CGFloat = 18, clipRow: CGFloat = 58, laneHeight: CGFloat = 15

    /// The clips and everything over them as one timeline under a line fixed in the middle, as CapCut and Edits lay
    /// it out (21 Nov; design/bigger-preview-mockup.html, then design/pro-ui): a ruler over it, slide it under the line
    /// to look through the video, tap a clip for its tools and drag its ends to trim it, pinch it wider or narrower. A
    /// second is the same width on every row, so each bar sits under the clips it plays over.
    private var timeline: some View {
        GeometryReader { g in
            let mid = g.size.width / 2, pps = perSecond, span = max(total, 0.01)
            let rows = timelineRows(width: CGFloat(span) * pps, span: span, pps: pps)
            ZStack(alignment: .topLeading) {
                // While it plays, slid on every frame the screen draws, from the player's own clock (21 Nov: moved
                // only on the 20-a-second time updates, it stepped along)
                TimelineView(.animation(minimumInterval: nil, paused: !playing || scrubFrom != nil)) { _ in
                    rows.offset(x: mid - CGFloat(min(lineTime, span)) * pps)
                }
                // the line: white, a dot on its top, yellow while a finger looks through the video
                let line = scrubFrom != nil ? Color.yellow : Color.white
                VStack(spacing: 0) {
                    Circle().fill(line).frame(width: 9, height: 9)
                    Rectangle().fill(line).frame(width: 2)
                }
                .shadow(color: .black.opacity(0.5), radius: 2)
                .frame(width: 9, height: g.size.height)
                .offset(x: mid - 4.5).allowsHitTesting(false)
                allSound.offset(y: Self.rulerHeight + 2)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            // alongside the clips' own touches, not after them: as a gesture of its own it waited for a clip's hold
            // (to move it) to give up first, and the timeline stood still a moment before it moved (21 Nov recording)
            .simultaneousGesture(DragGesture(minimumDistance: 6)
                .onChanged { v in scrubTimeline(by: v.translation.width, from: v.startLocation, mid: mid, pps: pps) }
                .onEnded { _ in endScrub() })
            .simultaneousGesture(MagnificationGesture()
                .onChanged { m in
                    if stripZoomFrom == nil { stripZoomFrom = stripZoom }
                    stripZoom = min(4, max(0.4, (stripZoomFrom ?? 1) * m))
                }
                .onEnded { _ in stripZoomFrom = nil })
        }
        .frame(height: Self.rulerHeight + 4 + Self.clipRow + (laneCount > 0 ? 3 + CGFloat(laneCount) * (Self.laneHeight + 3) : 0))
        // edge to edge, as CapCut's
        .padding(.horizontal, -14)
    }

    /// The ruler over the clips: a tick each step, its time on every other, the step chosen so the times don't crowd.
    private func ruler(width: CGFloat, span: Double, pps: CGFloat) -> some View {
        let step = [0.5, 1, 2, 5, 10, 15, 30, 60].first { CGFloat($0) * pps >= 54 } ?? 60
        return Canvas { ctx, size in
            var t = 0.0, k = 0
            while t <= span + 0.001 {
                let x = CGFloat(t) * pps, big = k % 2 == 0
                ctx.fill(Path(CGRect(x: x, y: size.height - (big ? 6 : 4), width: 1, height: big ? 6 : 4)),
                         with: .color(Color(white: big ? 0.42 : 0.28)))
                if big {
                    ctx.draw(Text(Self.code(t)).font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundColor(Self.quiet),
                             at: CGPoint(x: x, y: size.height - 7), anchor: t < 0.001 ? .bottomLeading : .bottom)
                }
                t += step / 2; k += 1
            }
        }
        .frame(width: width + 60, height: Self.rulerHeight)
        .allowsHitTesting(false)
    }

    private func timelineRows(width: CGFloat, span: Double, pps: CGFloat) -> some View {
        let starts = ClipJoin.starts(clips)
        let joins = Array(0..<max(0, clips.count - 1))
        return VStack(alignment: .leading, spacing: 4) {
            ruler(width: width, span: span, pps: pps)
            ZStack(alignment: .topLeading) {
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                    timelineClip(c, i, w: CGFloat(c.span) * pps).offset(x: CGFloat(starts[i]) * pps, y: 2)
                }
                // the song's beats, as yellow ticks (Stage E)
                ForEach(songBeats.indices, id: \.self) { b in
                    Rectangle().fill(Color.yellow.opacity(0.85)).frame(width: 1, height: 6)
                        .offset(x: CGFloat(songBeats[b]) * pps, y: 50).allowsHitTesting(false)
                }
                // the square for each join, in the middle of where one turns into the next
                ForEach(joins, id: \.self) { i in
                    let at = starts[i + 1] + ClipJoin.overlap(clips, after: i) / 2
                    joinSquare(i).offset(x: CGFloat(at) * pps - 9, y: 16)
                }
                Button { adding = true } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.black)
                        .frame(width: 34, height: 34).background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityLabel("Add clips")
                .offset(x: width + 18, y: 7)
                // the picked clip framed, with a handle on each end to drag it shorter or longer (over the joins'
                // squares, so a handle caught by its middle trims, not opens the transition)
                if let i = index, i < starts.count {
                    trimFrame(i, x: CGFloat(starts[i]) * pps, w: CGFloat(clips[i].span) * pps - 2, pps: pps)
                }
            }
            .frame(width: width + 60, height: Self.clipRow, alignment: .topLeading)
            if laneCount > 0 { lanes(width: width, span: span) }
        }
    }

    /// A clip on the timeline: its frames, its length on it, and its sound under them as a fine wave, green while
    /// it's heard (as CapCut shows it).
    private func timelineClip(_ c: Clip, _ at: Int, w: CGFloat) -> some View {
        let heard = c.soundOn && !c.still && (soundOf == nil || soundOf == c.id)
        return VStack(spacing: 2) {
            ClipThumb(clip: c)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 3) {
                        if !c.soundOn || c.still || (soundOf != nil && soundOf != c.id) { Image(systemName: "speaker.slash.fill") }
                        if abs(c.speed - 1) > 0.001 { Text(Self.speedText(c.speed)) }
                        Text(String(format: "%.1fs", c.span))
                    }
                    .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(3)
                }
            Bars(levels: c.still ? [] : (levels[c.id] ?? []), colour: heard ? Color(red: 0.24, green: 0.86, blue: 0.52) : Color.white.opacity(0.25))
                .frame(height: 10).clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .task(id: "\(c.id)|\(c.start)|\(c.end)") { if !c.still { levels[c.id] = await ClipJoin.levels(c, count: 48) } }
        }
        .frame(width: max(6, w - 2))
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { select(c.id) }
        // hold and drag onto another to move it there
        .draggable(c.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let raw = ids.first, let from = clips.firstIndex(where: { $0.id.uuidString == raw }), let to = clips.firstIndex(of: c), from != to else { return false }
            change { var all = $0; let moved = all.remove(at: from); all.insert(moved, at: to); return all }
            return true
        }
        .accessibilityLabel("Clip \(at + 1), \(Self.clock(c.span))")
        .accessibilityAddTraits(.isButton)
    }

    /// The picked clip's white frame, a handle on each end (design/pro-ui): drag one and the frame follows the finger,
    /// the preview showing the frame the clip will start or end on; let go and it's trimmed there.
    private func trimFrame(_ i: Int, x: CGFloat, w: CGFloat, pps: CGFloat) -> some View {
        let c = clips[i], r = max(c.speed, 0.01)
        // how far each end may go: out to the file's ends, in to a third of a second
        let leftMin = -CGFloat(c.start / r) * pps, leftMax = CGFloat((c.duration - 0.3) / r) * pps
        let rightMin = -CGFloat((c.duration - 0.3) / r) * pps, rightMax = CGFloat((c.length - c.end) / r) * pps
        let dl = trimLive?.side == 0 ? min(max(trimLive?.dx ?? 0, leftMin), leftMax) : 0
        let dr = trimLive?.side == 1 ? min(max(trimLive?.dx ?? 0, rightMin), rightMax) : 0
        let x0 = x + dl, width = max(8, w + dr - dl)
        func handle(_ side: Int) -> some View {
            UnevenRoundedRectangle(topLeadingRadius: side == 0 ? 5 : 0, bottomLeadingRadius: side == 0 ? 5 : 0,
                                   bottomTrailingRadius: side == 1 ? 5 : 0, topTrailingRadius: side == 1 ? 5 : 0, style: .continuous)
                .fill(.white).frame(width: 12, height: 48)
                .overlay(Capsule().fill(Color(white: 0.2)).frame(width: 2, height: 14))
                // a thumb's width to catch it by
                .padding(.horizontal, 10).contentShape(Rectangle()).padding(.horizontal, -10)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($trimLive) { v, live, _ in live = TrimDrag(side: side, dx: v.translation.width) }
                    .onChanged { v in
                        if trimDrag == nil { player.pause(); playing = false; UISelectionFeedbackGenerator().selectionChanged() }
                        trimDrag = TrimDrag(side: side, dx: v.translation.width)
                        // the frame it'll start or end on, under the line
                        let d = side == 0 ? min(max(v.translation.width, leftMin), leftMax) : min(max(v.translation.width, rightMin), rightMax)
                        let at = side == 0 ? startOf(i) + Double(d / pps) : startOf(i) + c.span + Double(d / pps) - 0.04
                        // (inside the clip: past its ends is the next clip's picture, not this one's)
                        chase(min(max(startOf(i), at), startOf(i) + max(0, c.span - 0.04)))
                    }
                    .onEnded { v in
                        let d = side == 0 ? min(max(v.translation.width, leftMin), leftMax) : min(max(v.translation.width, rightMin), rightMax)
                        trimDrag = nil; chaseTo = nil
                        if abs(d) < 0.5 { seek(now) } else { trimEnd(i, side: side, by: Double(d / pps) * r) }
                    })
                .accessibilityLabel(side == 0 ? "Start of clip \(i + 1)" : "End of clip \(i + 1)")
        }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white, lineWidth: 2)
                .frame(width: width, height: 48).allowsHitTesting(false)
            handle(0).offset(x: -12)
            handle(1).offset(x: width)
        }
        .offset(x: x0, y: 0)
    }

    /// A clip's start or end moved by `by` of its file's seconds, kept in its file and at least a third of a second.
    private func trimEnd(_ i: Int, side: Int, by d: Double) {
        guard clips.indices.contains(i), abs(d) > 0.001 else { return }
        remember()
        var c = clips[i]
        if side == 0 { c.start = min(max(0, c.start + d), c.end - 0.3) } else { c.end = max(min(c.length, c.end + d), c.start + 0.3) }
        // its sound kept inside what's kept of the picture
        if let ss = c.soundStart { c.soundStart = max(c.start, min(ss, c.end)) }
        if let se = c.soundEnd { c.soundEnd = max(c.start, min(se, c.end)) }
        withAnimation(.snappy(duration: 0.2)) { clips[i] = c }
        seek(side == 0 ? startOf(i) + 0.01 : max(startOf(i), startOf(i) + clips[i].span - 0.05))
    }

    /// The bars under the clips, at the timeline's seconds: slim tags.
    private func lanes(width: CGFloat, span: Double) -> some View {
        let rows = Array(barRows.prefix(4))
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.indices, id: \.self) { r in
                ZStack(alignment: .leading) {
                    ForEach(rows[r]) { item in bar(item, w: width, span: span, onTimeline: true) }
                }
                .frame(width: width, height: Self.laneHeight, alignment: .leading)
            }
        }
        .padding(.top, 2)
    }

    /// The timeline slid by a finger: the video under the line follows it, held on a clip's edge when it's near one.
    private func scrubTimeline(by dx: CGFloat, from start: CGPoint, mid: CGFloat, pps: CGFloat) {
        if scrubSkip { return }
        if scrubFrom == nil {
            // a bar or a clip's end being dragged has the finger: the timeline keeps still under it. Told by where the
            // finger came down, not only by the bar's own drag having begun: that came too late, and the timeline slid
            // under a trim handle being dragged, the handle drifting from the finger (21 Nov recording)
            if barGrab != nil || trimDrag != nil || onHandleOrBar(start, mid: mid, pps: pps) { scrubSkip = true; return }
            scrubFrom = now
            wasPlaying = player.rate != 0
            player.pause(); playing = false
        }
        let span = max(total, 0.01)
        // (short of the very end, where the preview goes round to the start again)
        var t = min(max(0, (scrubFrom ?? 0) - Double(dx / max(pps, 1))), max(0, span - 0.12))
        let reach = Double(8 / max(pps, 1))
        let edges = ClipJoin.starts(clips).dropFirst()
        if let e = edges.min(by: { abs($0 - t) < abs($1 - t) }), abs(e - t) < reach {
            t = e
            if snapped != e { snapped = e; UISelectionFeedbackGenerator().selectionChanged() }
        } else { snapped = nil }
        chase(t)
        now = t
    }

    /// Whether a point on the timeline (its own coordinates) is on the picked clip's trim handles or on a bar.
    private func onHandleOrBar(_ p: CGPoint, mid: CGFloat, pps: CGFloat) -> Bool {
        let shift = mid - CGFloat(now) * pps
        let clipTop = Self.rulerHeight + 4, lanesTop = clipTop + Self.clipRow + 4 + 2
        let starts = ClipJoin.starts(clips)
        if let i = index, i < starts.count, p.y >= clipTop - 4, p.y <= clipTop + Self.clipRow {
            let a = shift + CGFloat(starts[i]) * pps, b = a + CGFloat(clips[i].span) * pps - 2
            // each handle 12 wide outside the clip's edge, with 10 more each side to catch it by
            if (p.x >= a - 22 && p.x <= a + 10) || (p.x >= b - 10 && p.x <= b + 22) { return true }
        }
        guard p.y >= lanesTop else { return false }
        let r = Int((p.y - lanesTop) / (Self.laneHeight + 3))
        let rows = Array(barRows.prefix(4))
        guard r >= 0, r < rows.count else { return false }
        return rows[r].contains { item in
            let x0 = shift + CGFloat(item.from) * pps, x1 = x0 + max(16, CGFloat(item.to - item.from) * pps)
            return p.x >= x0 - 4 && p.x <= x1 + 4
        }
    }

    /// A finger looking through the video: one seek at a time, each to where the finger is when the last one's done
    /// (Apple's "chase" seek). (21 Nov: a seek for every move piled up behind each other, and the picture froze.)
    private func chase(_ t: Double) {
        chaseTo = t
        if !seeking { seekToChase() }
    }

    private func seekToChase() {
        guard let t = chaseTo else { return }
        chaseTo = nil; seeking = true
        let near = CMTime(seconds: 0.04, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: near, toleranceAfter: near) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { seeking = false; if chaseTo != nil { seekToChase() } } }
        }
    }

    private func endScrub() {
        if scrubSkip { scrubSkip = false; return }
        guard scrubFrom != nil else { return }
        snapped = nil; scrubFrom = nil; chaseTo = nil
        seek(now)
        if wasPlaying == true { player.play(); playing = true }
        wasPlaying = nil
    }

    private var actions: some View {
        let has = index != nil
        let moving = index.map { !clips[$0].still } ?? false
        return HStack(spacing: 0) {
          // back to the tools for the whole video
          Button { withAnimation(.snappy) { selected = nil } } label: {
              Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                  .frame(width: 34, height: 54).contentShape(Rectangle())
          }
          .buttonStyle(.plain).accessibilityLabel("Back to the tools for the whole video")
          Rectangle().fill(Color(white: 0.17)).frame(width: 1, height: 30).padding(.trailing, 4)
          toolRow {
            action("scissors", "Trim", on: has) { withAnimation(.snappy) { panel = .trim } }
            action("square.split.2x1", "Split", on: has) { splitHere() }
            action("gauge.with.dots.needle.67percent", "Speed", on: moving) { withAnimation(.snappy) { panel = .speed } }
            action("snowflake", "Freeze", on: moving) { freezeHere() }
            action("backward.fill", "Reverse", on: moving) { reverseSelected() }
            action("camera.filters", "Filters", on: has) { withAnimation(.snappy) { panel = .look } }
            action("arrow.up.left.and.arrow.down.right", "Motion", on: has) { withAnimation(.snappy) { panel = .motion } }
            action("speaker.wave.2", "Sound", on: has) { withAnimation(.snappy) { panel = .sound } }
            action("arrow.down.to.line", "Separate", on: moving && soundOf == nil && (index.map { clips[$0].soundOn } ?? false)) { separateSelected() }
                .accessibilityLabel("Separate audio")
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
          }
        }
        .padding(.top, 2)
    }

    /// A tool: its icon over its name, plain on the sheet, as a pro editor's tools row (design/pro-ui; the dark tiles
    /// went, and the names never cut off).
    private func action(_ icon: String, _ title: String, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 19, weight: .regular)).foregroundStyle(.white).frame(height: 22)
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Color(white: 0.74)).lineLimit(1).fixedSize()
            }
            .frame(minWidth: 52).frame(height: 54).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!on).opacity(on ? 1 : 0.3)
    }

    /// A row of tools that scrolls, faded at its right edge so it's clear there are more.
    private func toolRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { content() }.padding(.trailing, 28)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
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
                .background(alignment: .bottom) { tabLine }
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

    /// A panel's tool as a tab: its name, white and underlined when it's the one on (design/pro-ui: the big white
    /// blocks went). (`icon` kept for its callers; tabs are words.)
    private func soundTile(_ icon: String, _ title: String, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button { UISelectionFeedbackGenerator().selectionChanged(); withAnimation(.snappy(duration: 0.2)) { run() } } label: {
            Text(title).font(.system(size: 12.5, weight: on ? .bold : .medium)).foregroundStyle(on ? Color.white : Color(white: 0.55))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.vertical, 9).frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) { if on { Rectangle().fill(.white).frame(height: 2) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The line under a row of tabs.
    private var tabLine: some View { Rectangle().fill(Color(white: 0.13)).frame(height: 1) }

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
        return VStack(spacing: 10) {
            ProSlider(value: Binding(get: { Double(shown) }, set: { v in setVolume(i, Float(v)) }), began: { remember() })
            HStack(spacing: 10) {
            keyButton(near != nil, on: at != nil) {
                guard let at else { return }
                remember()
                if let near { clips[i].keys.remove(at: near) }
                else { clips[i].keys.append(VolumeKey(at: at, volume: c.keys.isEmpty ? c.volume : c.level(at: at))) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            .frame(height: 30)
            }
            Text(c.keys.isEmpty ? "Put the line where you want it, then add a keyframe to set the volume there."
                 : "\(c.keys.count) keyframe\(c.keys.count == 1 ? "" : "s"): the volume eases between them.")
                .font(.system(size: 11)).foregroundStyle(Color(white: 0.43)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Add a keyframe here, or take away the one here: a labelled button beside the sound (design/pro-ui).
    private func keyButton(_ here: Bool, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: here ? "diamond.fill" : "diamond").font(.system(size: 11, weight: .bold)).foregroundStyle(here ? Color.yellow : Color.white)
                Text(here ? "Remove" : "Keyframe").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!on).opacity(on ? 1 : 0.4)
        .accessibilityLabel(here ? "Remove the keyframe here" : "Add a keyframe here")
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

    private func remember() { history.append(Snap(clips: clips, sounds: sounds)); future = []; if history.count > 30 { history.removeFirst() } }
    private func change(_ f: ([Clip]) -> [Clip]) { remember(); withAnimation(.snappy) { clips = f(clips) } }
    private func undo() {
        guard let last = history.popLast() else { return }
        future.append(Snap(clips: clips, sounds: sounds)); restore(last)
    }
    private func redo() {
        guard let next = future.popLast() else { return }
        history.append(Snap(clips: clips, sounds: sounds)); restore(next)
    }
    private func restore(_ s: Snap) {
        withAnimation(.snappy) { clips = s.clips; sounds = s.sounds }
        // a sound's panel shut if its sound has gone
        if let id = selectedSound, !s.sounds.contains(where: { $0.id == id }) {
            selectedSound = nil
            if panel == .soundItem { panel = nil }
        }
    }

    /// The picked clip's own sound as a bar of its own (21 Nov; design/separate-audio-mockup.html): the clip goes
    /// quiet and the same sound starts in the same place, at the same level, fades and speed, so nothing sounds
    /// different until the bar's moved or trimmed. Then it can run under the next clip, or start before its own.
    private func separateSelected() {
        guard let i = index, !clips[i].still, clips[i].soundOn, soundOf == nil else { return }
        let c = clips[i], r = max(c.speed, 0.01)
        let a = c.heardStart, b = c.heardEnd
        guard b - a > 0.05 else { return }
        var s = EditSound(kind: "clip", name: "Clip \(i + 1) sound", file: c.clean ?? c.source,
                          from: startOf(i) + (a - c.start) / r, start: a, length: (b - a) / r, volume: c.volume, full: c.length)
        if !c.keys.isEmpty { s.keys = c.keys }
        if c.fadeIn > 0.01 { s.fadeIn = c.fadeIn / r }
        if c.fadeOut > 0.01 { s.fadeOut = c.fadeOut / r }
        if abs(r - 1) > 0.001 { s.rate = r }
        s.clip = c.id
        remember()
        clips[i].soundOn = false
        withAnimation(.snappy) { sounds.append(s) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        flash("Clip \(i + 1)'s sound is its own bar now: drag it, or by an end, to move it under other clips.")
    }

    /// A separated sound back on its clip, as the clip had it.
    private func putBack(_ id: UUID) {
        guard let s = sounds.first(where: { $0.id == id }), let ci = clips.firstIndex(where: { $0.id == s.clip }) else { return }
        remember()
        withAnimation(.snappy) { panel = nil; selectedSound = nil; sounds.removeAll { $0.id == id }; clips[ci].soundOn = true }
    }

    private func takeOff(_ id: UUID) {
        remember()
        withAnimation(.snappy) { panel = nil; selectedSound = nil; sounds.removeAll { $0.id == id } }
    }

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
                            .frame(width: max(2, w * CGFloat(c.span / span) - 2), height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(c.id == selected || selected == nil ? 0 : 0.35)))
                            .offset(x: w * CGFloat(starts[i] / span))
                    }
                }
                .frame(width: w, height: 26, alignment: .leading).clipped()
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1))
                // the song's beats, as yellow ticks (Stage E)
                ForEach(songBeats.indices, id: \.self) { b in
                    Rectangle().fill(Color.yellow.opacity(0.8)).frame(width: 1, height: 10)
                        .offset(x: w * CGFloat(songBeats[b] / span), y: 14).allowsHitTesting(false)
                }
                // where it is: yellow while a finger looks through it, as in the single editor; white as it plays
                Capsule().fill(wasPlaying != nil ? Color.yellow : Color.white).frame(width: 3.5, height: 36)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(x: min(max(0, w * CGFloat(now / span) - 1.75), w - 3.5))
            }
            .frame(width: w, height: 38)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if wasPlaying == nil { wasPlaying = player.rate != 0; player.pause(); playing = false }
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
                    chase(t)
                    now = t
                }
                .onEnded { _ in
                    snapped = nil; chaseTo = nil
                    seek(now)
                    if wasPlaying == true { player.play(); playing = true }
                    wasPlaying = nil
                })
            .accessibilityElement()
            .accessibilityLabel("Where in the video")
            .accessibilityValue("\(Self.clock(now)) of \(Self.clock(total))")
            .accessibilityAdjustableAction { dir in
                seek(min(max(0, now + (dir == .increment ? 1 : -1)), max(0, total - 0.05)))
            }
        }
        // thin, over a tool's panel: the panel has the room (design/bigger-preview-mockup.html)
        .frame(height: 38)
    }

    /// What the preview's tracks are made of: what's put where, not how loud or how it looks. Two edits alike in this
    /// make compositions with the same tracks.
    private var shape: String {
        var s = soundOf?.uuidString ?? "-"
        for c in clips {
            s += "|\(proxies[c.source]?.path ?? c.source.path),\(c.start),\(c.end),\(c.speed),\(c.still),\(c.clean?.path ?? ""),\(c.soundStart ?? -1),\(c.soundEnd ?? -1)"
            s += ",\(c.transition?.kind ?? ""),\(c.transition?.length ?? 0)"
        }
        for x in sounds { s += "|s\(x.url?.path ?? x.name),\(x.from),\(x.start),\(x.length),\(x.speed)" }
        for p in pips { s += "|p\(p.source.path),\(p.from),\(p.start),\(p.length)" }
        return s
    }

    /// The preview made again from the clips as they are now, kept where it was.
    /// The edit as it is now given to the editor's own player: nothing's made, it plays on from where it is with the
    /// change (21 Nov: the preview was made again for each change, and flashed).
    @MainActor private func rebuild(play: Bool) async {
        if player.onTime == nil {
            player.onTime = { t in
                // (not while a finger's looking through it: the seeks' own times fought the finger)
                guard scrubFrom == nil, wasPlaying == nil else { return }
                now = t
                if playing != (player.rate != 0) { playing = player.rate != 0 }
            }
            player.onSize = { frameSize = $0 }
        }
        player.update(clips: clips, soundOf: soundOf, look: look, sounds: sounds, pips: pips, swap: proxies)
        frameSize = player.frameSize
        if player.rate == 0, abs(player.currentTime().seconds - now) > 0.001 { seek(min(now, max(0, total - 0.05))) }
        Sound.on(.moviePlayback)
        if play { player.play(); playing = true }
    }

    private func settle() async {
        guard !Task.isCancelled else { return }
        await rebuild(play: !player.loaded)
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
            player.pause(); playing = false
            seek(min(max(0, now + dir / 30), max(0, total - 0.05)))
        } label: {
            Image(systemName: dir < 0 ? "backward.frame" : "forward.frame").font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(white: 0.82)).frame(width: 34, height: 34).contentShape(Rectangle())
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
                        .accessibilityLabel("Overlay").accessibilityHint("Double tap to change it; drag to move it")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selectPip(p.id) }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if pipFrom == nil {
                                    guard hypot(v.translation.width, v.translation.height) > 2 else { return }
                                    pipFrom = m
                                }
                                let start = pipFrom ?? m
                                setPip(p.id) { $0.x = min(1, max(0, start.x + Double(v.translation.width / max(r.width, 1))))
                                               $0.y = min(1, max(0, start.y + Double(v.translation.height / max(r.height, 1)))) }
                            }
                            .onEnded { _ in
                                if pipFrom == nil { selectPip(p.id) }
                                pipFrom = nil
                            })
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
                        // sized with its dashed box, so the box grows with it (20 Nov: the box stayed small)
                        .scaleEffect(k * CGFloat(item.size))
                        .position(x: r.minX + item.x * r.width, y: r.minY + item.y * r.height)
                        .accessibilityLabel(item.kind == "sticker" ? "Sticker \(item.text)" : item.barLabel)
                        .accessibilityHint("Double tap to change it; drag to move it")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selectText(item.id) }
                        // One gesture, from the first touch: a touch that doesn't move is a tap. (20 Nov: a tap and a
                        // drag on it held the first move back while the phone worked out which it was.)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard let i = texts.firstIndex(where: { $0.id == item.id }) else { return }
                                if moveFrom == nil {
                                    guard hypot(v.translation.width, v.translation.height) > 2 else { return }
                                    moveFrom = (texts[i].x, texts[i].y)
                                }
                                let start = moveFrom ?? (item.x, item.y)
                                texts[i].x = min(0.95, max(0.05, start.0 + Double(v.translation.width / max(r.width, 1))))
                                texts[i].y = min(0.95, max(0.05, start.1 + Double(v.translation.height / max(r.height, 1))))
                            }
                            .onEnded { _ in
                                if moveFrom == nil { selectText(item.id) }
                                moveFrom = nil
                            })
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
        toolRow {
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
        .padding(.top, 2)
    }

    /// Everything laid over the video as bars, in rows so none covers another: drag one along, or by an end for when it
    /// starts and stops; tap it to change it. Text and stickers, then the sounds.
    private var barItems: [BarItem] {
        texts.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: $0.barLabel, colour: $0.barColour, kind: 0) }
            + sounds.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: Self.soundMark($0.kind) + $0.name, colour: Self.soundColour($0.kind), kind: 1) }
            + pips.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: "▣ Overlay" + ($0.keys.isEmpty ? "" : " · ◆"), colour: Color(red: 0.36, green: 0.82, blue: 0.56), kind: 2) }
    }

    /// The bars in rows, so none covers another and each row is one kind.
    private var barRows: [[BarItem]] {
        var rows: [[BarItem]] = []
        for t in barItems.sorted(by: { $0.from < $1.from }) {
            if let r = rows.firstIndex(where: { ($0.last?.to ?? 0) <= t.from + 0.01 && $0.last?.kind == t.kind }) { rows[r].append(t) } else { rows.append([t]) }
        }
        return rows
    }

    private var bars: some View {
        let shownRows = barRows
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

    /// `onTimeline`: there the line stays put while a bar's dragged (else the timeline slides under the finger), and
    /// goes to the bar after.
    private func bar(_ item: BarItem, w: CGFloat, span: Double, onTimeline: Bool = false) -> some View {
        let x0 = w * CGFloat(min(item.from, span) / span), x1 = w * CGFloat(min(item.to, span) / span)
        let width = max(16, x1 - x0), on = item.id == selectedText || item.id == selectedSound || item.id == selectedPip
        // (on the timeline a slim tag, design/pro-ui)
        let h: CGFloat = onTimeline ? Self.laneHeight : 18, corner: CGFloat = onTimeline ? 4 : 5
        return Text(item.label).font(.system(size: onTimeline ? 8 : 9, weight: onTimeline ? .bold : .heavy)).lineLimit(1).foregroundStyle(.black.opacity(0.82))
            .padding(.horizontal, 5).frame(width: width, height: h, alignment: .leading)
            .background(item.colour.opacity(onTimeline ? 0.88 : 1), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(on ? Color.white : Color.clear, lineWidth: 1.5))
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
                        // held still under the finger while it's moved (21 Nov: playing on, the timeline slid away
                        // under the bar being dragged)
                        player.pause(); playing = false
                        // by its ends, or the middle to move it
                        let mode = v.startLocation.x < 12 ? 1 : (v.startLocation.x > width - 12 ? 2 : 0)
                        if item.kind == 1, let s = sounds.first(where: { $0.id == item.id }) {
                            remember()   // (a sound moved can be undone)
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
                    case 1: dragSound(g, dt, span: span, follow: !onTimeline)
                    case 2: dragPip(g, dt, span: span, follow: !onTimeline)
                    default: dragText(g, dt, span: span, follow: !onTimeline)
                    }
                }
                .onEnded { _ in
                    if onTimeline, barGrab != nil, let b = barItems.first(where: { $0.id == item.id }) { seek(min(b.from, max(0, total - 0.05))) }
                    let moved = barGrab != nil && item.kind != 0
                    barGrab = nil
                    // a sound or overlay moved: the preview made again with it, now it's let go
                    if moved { dropped += 1 }
                })
            .offset(x: x0)
            .accessibilityElement()
            .accessibilityLabel("\(item.label), \(Self.clock(item.from)) to \(Self.clock(item.to))")
            .accessibilityHint("Double tap to change it")
            .accessibilityAddTraits(.isButton)
    }

    private func dragText(_ g: BarGrab, _ dt: Double, span: Double, follow: Bool = true) {
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
        if follow { seek(g.mode == 2 ? max(0, texts[i].to - 0.05) : texts[i].from) }
    }

    /// A sound's bar: moved along, its front trimmed off (its start in its own sound moving with it), or its end.
    private func dragSound(_ g: BarGrab, _ dt: Double, span: Double, follow: Bool = true) {
        guard let i = sounds.firstIndex(where: { $0.id == g.id }) else { return }
        // (dt is the video's seconds; a clip's separated sound runs at its clip's speed through its own)
        let r = sounds[i].speed
        let length = g.to - g.from, whole = sounds[i].full > 0 ? sounds[i].full : g.start + length * r
        switch g.mode {
        case 1:
            let d = min(max(-g.start / r, -g.from, dt), length - 0.3)
            sounds[i].from = g.from + d; sounds[i].start = g.start + d * r; sounds[i].length = length - d
        case 2:
            sounds[i].length = max(0.3, min(length + dt, (whole - g.start) / r, span - g.from))
        default:
            sounds[i].from = min(max(0, g.from + dt), max(0, span - 0.3))
        }
        if follow { seek(g.mode == 2 ? max(0, sounds[i].to - 0.05) : sounds[i].from) }
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

    /// A sound's bar picked (a voiceover, an effect, the song, or a clip's separated sound): the clip Sound panel's
    /// tools (21 Nov; design/separate-audio-mockup.html, 4): Volume with keyframes, Fade, Put back, Take off.
    private func soundItemPanel(_ k: Int) -> some View {
        let x = sounds[k]
        let home = x.kind == "clip" && clips.contains { $0.id == x.clip }
        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                soundTile("speaker.wave.2.fill", "Volume", on: soundTool == .volume) { soundTool = .volume }
                soundTile("waveform.path", "Fade", on: soundTool == .fade) { soundTool = .fade }
                if home { soundTile("arrow.up.to.line", "Put back", on: false) { putBack(x.id) } }
                soundTile("trash", "Take off", on: false) { takeOff(x.id) }
            }
            .background(alignment: .bottom) { tabLine }
            if soundTool == .fade { barFadePanel(k) } else { barVolumePanel(k) }
        }
    }

    /// Where the line is in a sound's own seconds, if the line is over its bar.
    private func barFileTime(_ k: Int) -> Double? {
        let s = sounds[k]
        guard now >= s.from - 0.01, now <= s.to + 0.01 else { return nil }
        return s.fileTime(min(max(now, s.from), s.to))
    }

    /// A bar's volume: as a clip's (volumePanel), the number and slider the level at the line, the diamond a keyframe.
    private func barVolumePanel(_ k: Int) -> some View {
        let s = sounds[k], at = barFileTime(k), keys = s.keys ?? []
        let near = at.flatMap { t in keys.firstIndex { abs($0.at - t) < 0.15 } }
        let shown = keys.isEmpty ? s.volume : s.keyLevel(at: at ?? s.start)
        return VStack(spacing: 10) {
            ProSlider(value: Binding(get: { Double(shown) }, set: { v in setBarVolume(k, Float(v)) }), began: { remember() })
            HStack(spacing: 10) {
            keyButton(near != nil, on: at != nil) {
                guard let at, sounds.indices.contains(k) else { return }
                remember()
                var all = sounds[k].keys ?? []
                if let near { all.remove(at: near) } else { all.append(VolumeKey(at: at, volume: keys.isEmpty ? s.volume : s.keyLevel(at: at))) }
                sounds[k].keys = all.isEmpty ? nil : all
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            // the bar, its keyframes on it and the line where it is: tap a diamond to go to it
            GeometryReader { g in
                let w = g.size.width, span = max(s.length, 0.01)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Self.soundColour(s.kind).opacity(0.35))
                    ForEach(keys.indices, id: \.self) { j in
                        let v = s.videoTime(keys[j].at)
                        Image(systemName: "diamond.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.yellow)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .position(x: min(max(6, w * CGFloat((v - s.from) / span)), w - 6), y: g.size.height / 2)
                            .onTapGesture { seek(v) }
                    }
                    if at != nil {
                        Capsule().fill(.white).frame(width: 2.5, height: g.size.height + 6)
                            .offset(x: min(max(0, w * CGFloat((now - s.from) / span) - 1.25), w - 2.5)).allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 30)
            }
            Text(keys.isEmpty ? "Put the line over the bar, then add a keyframe to set the volume there."
                 : "\(keys.count) keyframe\(keys.count == 1 ? "" : "s"): the volume eases between them.")
                .font(.system(size: 11)).foregroundStyle(Color(white: 0.43)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The slider moved: the sound's volume, or with keyframes the one at the line (made there if there isn't one).
    private func setBarVolume(_ k: Int, _ v: Float) {
        guard sounds.indices.contains(k) else { return }
        guard var keys = sounds[k].keys, !keys.isEmpty, let at = barFileTime(k) else { sounds[k].volume = v; return }
        if let j = keys.firstIndex(where: { abs($0.at - at) < 0.15 }) { keys[j].volume = v } else { keys.append(VolumeKey(at: at, volume: v)) }
        sounds[k].keys = keys
    }

    /// A bar's fades: each up to 3 seconds, never past half of it (a song faded out at the end, say).
    private func barFadePanel(_ k: Int) -> some View {
        let most = max(0.1, min(3, sounds[k].length / 2))
        return VStack(spacing: 14) {
            fadeRow("Fade in", value: Binding(get: { sounds.indices.contains(k) ? min(sounds[k].fadeIn ?? 0, most) : 0 },
                                              set: { if sounds.indices.contains(k) { sounds[k].fadeIn = $0 < 0.05 ? nil : $0 } }), most: most)
            fadeRow("Fade out", value: Binding(get: { sounds.indices.contains(k) ? min(sounds[k].fadeOut ?? 0, most) : 0 },
                                               set: { if sounds.indices.contains(k) { sounds[k].fadeOut = $0 < 0.05 ? nil : $0 } }), most: most)
        }
        .padding(.top, 4)
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

    static func soundMark(_ kind: String) -> String {
        switch kind {
        case "voice": return "🎙 "
        case "song": return "♫ "
        case "clip": return "⇣ "
        default: return "✦ "
        }
    }
    static func soundColour(_ kind: String) -> Color {
        switch kind {
        case "voice": return Color(red: 1, green: 0.48, blue: 0.48)
        case "song": return Color(red: 0.77, green: 0.63, blue: 1)
        case "clip": return Color(red: 0.37, green: 0.77, blue: 0.91)
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
        "Slide the timeline under the line to look through the video. Tap a clip on it for its tools: trim, split, speed, filters, sound and more.",
        "With no clip picked, the row along the bottom adds text, captions, voice, music and more over the whole video.",
        "Everything added shows as a bar under the clips: drag it along, or by an end, for when it shows.",
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

    private func dragPip(_ g: BarGrab, _ dt: Double, span: Double, follow: Bool = true) {
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
        if follow { seek(g.mode == 2 ? max(0, pips[i].to - 0.05) : pips[i].from) }
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
            // a small square on the join, edged in the sheet's colour so it stands off the clips (design/pro-ui)
            Image(systemName: set ? "arrow.left.arrow.right" : "plus").font(.system(size: 7.5, weight: .black))
                .foregroundStyle(set ? Color.black : Color.white).frame(width: 18, height: 18)
                .background(set ? Color.white : Color(white: 0.22), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Self.sheet, lineWidth: 2))
                // a bigger target than it looks
                .padding(6).contentShape(Rectangle()).padding(-6)
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

/// A clip's sound as a fine wave: a thin line every three points, as tall as the sound there (21 Nov,
/// design/pro-ui/pro-editor-mockup.png: the fat rounded bars looked like a toy's).
struct Bars: View {
    let levels: [Float]
    var colour: Color = Color.white.opacity(0.55)
    var body: some View {
        Canvas { ctx, size in
            guard !levels.isEmpty, size.width > 1 else { return }
            let n = max(1, Int(size.width / 3))
            for j in 0..<n {
                let level = CGFloat(levels[min(levels.count - 1, j * levels.count / n)])
                let h = max(1, size.height * level)
                ctx.fill(Path(CGRect(x: CGFloat(j) * 3, y: (size.height - h) / 2, width: 1.2, height: h)), with: .color(colour))
            }
        }
        .background(colour.opacity(0.12))
    }
}

/// A pro editor's volume slider (design/pro-ui): a thin track, a white knob, its number in a bubble over the knob and
/// a scale under it. `value` 0…1, shown 0…100; `began` when a finger first takes it (for Undo).
struct ProSlider: View {
    @Binding var value: Double
    var began: () -> Void = {}
    @State private var holding = false
    @GestureState private var touching = false   // (back to false however the drag ends, cut short too)

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { g in
                let w = max(g.size.width, 1), x = w * CGFloat(min(1, max(0, value)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.17)).frame(height: 4)
                    Capsule().fill(.white).frame(width: x, height: 4)
                    Circle().fill(.white).frame(width: 20, height: 20).shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(x: min(max(0, x - 10), w - 20))
                    Text("\(Int((value * 100).rounded()))").font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(.black)
                        .frame(width: 38, height: 20).background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .offset(x: min(max(0, x - 19), w - 38), y: -27)
                }
                .frame(width: w, height: 24)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($touching) { _, t, _ in t = true }
                    .onChanged { v in
                        if !holding { holding = true; began() }
                        value = Double(min(1, max(0, v.location.x / w)))
                    }
                    .onEnded { _ in holding = false })
                .onChange(of: touching) { _, now in if !now { holding = false } }
            }
            .frame(height: 24)
            HStack(spacing: 0) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { n in
                    Text("\(n)")
                    if n < 100 { Spacer(minLength: 0) }
                }
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Color(white: 0.37))
        }
        .padding(.top, 26)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded()))")
        .accessibilityAdjustableAction { dir in
            began()
            value = min(1, max(0, value + (dir == .increment ? 0.05 : -0.05)))
        }
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
