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
    private struct Snap { var clips: [Clip]; var sounds: [EditSound]; var texts: [EditText] = [] }
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
    // the captions' panel (21 Nov, design/captions-editing-mockup.html): how much each holds, how many lines, and
    // the caption picked in the list
    @State private var captionGroup = "few"
    @State private var captionLines = 1
    @State private var listPicked: UUID?
    // text typed straight onto the video, and the stories' sticker tray (21 Nov, design/editor-text-stickers-mockup.html)
    @State private var typing: UUID?
    @FocusState private var typingFocus: Bool
    @State private var stickering = false
    @State private var stickerPick: String?
    // the recipe laid over it (design/editor-recipe-mockup.html), and how
    @State private var recipe: JSON?
    @State private var plan = EditOverlays.RecipePlan()
    @State private var stepPicked: Int?
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
    @State private var templating = false                 // the templates open (design/templates-mockup.html)
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
    @State private var scrubSkip = false
    @State private var pressed: UUID?        // the bar a finger's on (design/capcut-timeline-mockup.html: hold to lift)
    @State private var pressMoved = false    // it moved before the hold was up: a scroll, not a hold
    @State private var lifted: UUID?         // the bar held long enough to move
    @State private var liftDY: CGFloat = 0    // how far up or down it's been dragged
    @State private var dropRow: Int?          // the row it'd go on if let go now
    @State private var heldRows: [UUID: Int] = [:]   // each bar's row as it was when one was caught, till it's let go
    @State private var barSnap: Double?
    @State private var stripHeld: CGFloat?                // the keyframe a strip's scrub is held on (for the tap, once)                   // what a bar being dragged is held on (for the tap, once)                  // this drag is a bar's or a trim handle's, not the timeline's                // an end of the picked clip being dragged on the timeline
    private struct BarGrab { var id: UUID; var mode: Int; var from: Double; var to: Double; var words: [EditText.Word]?; var start = 0.0 }   // mode: 0 move, 1 start, 2 end
    /// One bar on the timeline: a text, sticker or caption, or a voiceover or sound effect.
    /// kind: 0 over the picture (text, stickers, captions), 1 a sound, 2 a clip or photo over it.
    private struct BarItem: Identifiable { let id: UUID; let from: Double; let to: Double; let label: String; let colour: Color; let kind: Int; var lane: Int? = nil }
    private enum Panel { case trim, sound, speed, join, look, shape, text, stickers, voice, effects, soundItem, pip, motion, beats, captions, captionList, recipe, recipeSteps }
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
        // what's over a clip moves with it when a transition, a trim or a move shifts where it starts (21 Nov: a
        // transition added, the captions after it ran behind what was said)
        .onChange(of: clips) { old, new in follow(from: old, to: new) }
        // a voiceover moved or trimmed: the captions of what's said in it go with it
        // (kept out of this chain: inline, it was too much for the compiler, 21 Nov)
        .onChange(of: voiceSpans) { _, _ in voiceMoved() }
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
        // the stories' sticker tray: yours, 3D and GIPHY's (a tile that needs more asks once the tray's gone)
        .sheet(isPresented: $stickering, onDismiss: { if let p = stickerPick { stickerPick = nil; addCard(p) } }) {
            StickerSheet(forVideo: true, pick: { id in stickerPick = id; stickering = false }, place: { o in stickering = false; placeCard(o) })
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        // text typed on the video itself, everything else dimmed behind
        .fullScreenCover(isPresented: $templating) {
            TemplateMaker(clips: clips, make: { t, c, s, m in Task { @MainActor in await makeTemplate(t, c, s, m) } }, close: { templating = false })
        }
        .fullScreenCover(isPresented: Binding(get: { typing != nil }, set: { if !$0 { endTyping() } })) {
            if let k = texts.firstIndex(where: { $0.id == typing }) { typingView(k) }
        }
        // a 4K clip played from a smaller copy while it's edited (the finished video's made from the file itself)
        .task(id: Set(clips.map { $0.source })) {
            for src in Set(clips.map { $0.source }) where !proxied.contains(src) {
                proxied.insert(src)
                if let p = await ClipJoin.proxy(src) { proxies[src] = p }
            }
        }
        .task(id: proxies.count) { if !proxies.isEmpty { await settle() } }
        // left for another app: paused, as CapCut does; back: the editor's sound on again and the player's sound
        // started afresh (21 Nov: back in the app, nothing could be heard. The likeliest causes, not proven: the
        // phone stopped the sound engine while the app was away, or the app's sound was put back to the ringer's)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if player.rate != 0 { player.pause(); playing = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Sound.on(.moviePlayback)
            player.wake()
        }
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
        case .beats: return "Music"
        case .captions: return "Captions"
        case .captionList: return "Edit captions"
        case .recipe: return "Recipe"
        case .recipeSteps: return "Method"
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
            case .captions: scrubBar; panelBar; captionsPanel   // (no bars: squashed to a letter each they said nothing the list doesn't, 21 Nov)
            case .captionList: scrubBar; panelBar; captionList
            case .recipe: scrubBar; panelBar; bars; recipePanel
            case .recipeSteps: scrubBar; panelBar; recipeSteps
            case .stickers: scrubBar; panelBar; stickerPanel
            case .voice: scrubBar; panelBar; bars; voicePanel
            case .effects: scrubBar; panelBar; bars; effectsPanel   // (the bars shown: 21 Nov, an effect went in and nobody could see where)
            case .soundItem: scrubBar; panelBar; if let k = sounds.firstIndex(where: { $0.id == selectedSound }) { bars; soundItemPanel(k) }
            case .pip: scrubBar; panelBar; if let k = pips.firstIndex(where: { $0.id == selectedPip }) { bars; pipPanel(k) }
            case .motion: scrubBar; panelBar; if let i = index { motionPanel(i) }
            case .beats: panelBar; timeline; beatsPanel
            case nil:
                // one timeline in place of the scrub bar, the bars and the strip (21 Nov: stacked, they left the video
                // a third of the screen)
                timeline
                if selected != nil { actions } else if let b = pickedBar { barTools(b) } else { addTools }
            }
        }
        // (no more under the tools than the home bar's own room: 21 Nov, a gap at the bottom)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 0)
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
            .foregroundStyle(.white).frame(width: 44, height: Self.clipRow + 4)   // (as tall as the clips' row, its sound wave in it)
            .overlay(alignment: .trailing) { Rectangle().fill(Color(white: 0.2)).frame(width: 1, height: 40) }
            // solid, down past every row of bars under the clips too (21 Nov: captions showed under it; and before,
            // the fade into the clips dimmed the first of them too far)
            .frame(width: 44, height: max(Self.clipRow + 4, Self.clipRow + 2 + (laneCount > 0 ? 3 + CGFloat(laneCount) * (Self.laneHeight + 3) : 0)), alignment: .top)
            .background(Self.sheet)
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
    // (an empty rail always kept under the last, to drop onto: one that came and went as a bar was dragged grew and
    // shrank the timeline under the finger, 22 Nov)
    private var laneCount: Int { let n = barRows.count; return n == 0 ? 0 : min(6, n + 1) }
    // the bars as tall as CapCut's, their words readable (21 Nov, design/capcut-timeline-mockup.html: 15 pt bars read as slivers)
    private static let rulerHeight: CGFloat = 18, clipRow: CGFloat = 49, laneHeight: CGFloat = 34

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
                // each row's tile beside it, lined up with it (22 Nov: "match cap where we have ui that lines up with things")
                laneHeads.offset(x: 7, y: Self.rulerHeight + 4 + Self.clipRow + 4 + 2)
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
                // (not the picked clip's two: its trim handles are there, and a square under one hid it, 21 Nov)
                ForEach(joins.filter { index == nil || ($0 != index && $0 + 1 != index) }, id: \.self) { i in
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
            if laneCount > 0 { lanes(width: width, span: span).zIndex(1) }
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
        // past where it can go (the start or end of the video), a little stretch, as CapCut's, so it doesn't look stuck
        func band(_ d: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { let c = min(max(d, lo), hi); return c + (d - c) * 0.12 }
        let dl = trimLive?.side == 0 ? band(trimLive?.dx ?? 0, leftMin, leftMax) : 0
        let dr = trimLive?.side == 1 ? band(trimLive?.dx ?? 0, rightMin, rightMax) : 0
        let x0 = x + dl, width = max(8, w + dr - dl)
        func handle(_ side: Int) -> some View {
            // (the white is the frame's, drawn whole below: this is where it's caught, and its grip)
            Color.clear.frame(width: 12, height: 48)
                .overlay(Capsule().fill(Color(white: 0.2)).frame(width: 2, height: 14))
                // a thumb's width to catch it by
                .padding(.horizontal, 10).contentShape(Rectangle()).padding(.horizontal, -10)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($trimLive) { v, live, _ in live = TrimDrag(side: side, dx: v.translation.width) }
                    .onChanged { v in
                        if trimDrag == nil { player.pause(); playing = false; UISelectionFeedbackGenerator().selectionChanged() }
                        // a tap the moment it reaches the end of the video
                        let lo = side == 0 ? leftMin : rightMin, hi = side == 0 ? leftMax : rightMax
                        let out = v.translation.width < lo - 0.5 || v.translation.width > hi + 0.5
                        if out, let was = trimDrag, !(was.dx < lo - 0.5 || was.dx > hi + 0.5) { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
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
        // the frame and its two handles as one white shape, rounded outside, the clip showing through it (21 Nov: drawn
        // as a frame and two handles, each with its own rounded corners, they left a notch at each corner where they met)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRoundedRect(in: CGRect(x: 0, y: 0, width: width + 24, height: 48), cornerSize: CGSize(width: 6, height: 6), style: .continuous)
                p.addRoundedRect(in: CGRect(x: 12, y: 2, width: width, height: 44), cornerSize: CGSize(width: 4, height: 4), style: .continuous)
            }
            .fill(Color.white, style: FillStyle(eoFill: true))
            .frame(width: width + 24, height: 48).allowsHitTesting(false)
            handle(0)
            handle(1).offset(x: width + 12)
        }
        .offset(x: x0 - 12, y: 0)
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
        // the line stays where it was (21 Nov: it jumped to the trimmed end); only kept inside the video if it's shorter
        seek(min(now, max(0, total - 0.05)))
    }

    /// The bars under the clips, at the timeline's seconds: slim tags.
    private func lanes(width: CGFloat, span: Double) -> some View {
        let rows = Array(barRows.prefix(6))
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.indices, id: \.self) { r in
                ZStack(alignment: .leading) {
                    // the row's rail, the whole way along, so where each row is shows even where it's empty (CapCut's)
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.13))
                    // where a held bar would go: the row outlined, or a line where it'd be a new row of its own
                    if dropRow == r { dropMark(r, rows[r]) }
                    ForEach(rows[r]) { item in bar(item, w: width, span: span, onTimeline: true) }
                }
                .frame(width: width, height: Self.laneHeight, alignment: .leading)
                // (over the other rows' rails while its bar's lifted: under them, it vanished as it was dragged, 22 Nov)
                .zIndex(hasLifted(rows[r]) ? 1 : 0)
            }
            // the empty rail under the last, a new row for a bar dropped on it
            if rows.count < 6 { emptyRail(wanted: dropRow == rows.count, width: width) }
        }
        .overlay(alignment: .topLeading) { barHandles(rows, width: width, span: span) }
        .coordinateSpace(name: "bars")
        .padding(.top, 2)
    }

    private func hasLifted(_ row: [BarItem]) -> Bool {
        guard let id = lifted else { return false }
        return row.contains { (b: BarItem) -> Bool in b.id == id }
    }

    private func emptyRail(wanted: Bool, width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let dash = StrokeStyle(lineWidth: 1.5, dash: [5, 4])
        return shape.fill(Color(white: 0.13))
            .overlay(shape.strokeBorder(Color.white.opacity(wanted ? 0.5 : 0), style: dash))
            .frame(width: width, height: Self.laneHeight)
    }

    /// Where the lifted bar would land on row r.
    @ViewBuilder private func dropMark(_ r: Int, _ row: [BarItem]) -> some View {
        if let id = lifted, let item = barItems.first(where: { (b: BarItem) -> Bool in b.id == id }) {
            if joins(item, row) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            } else {
                let down = r >= (rowOf(id) ?? r)
                Capsule().fill(Color.white).frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: down ? .bottom : .top)
            }
        }
    }

    // The picked bar's handles: a grip outside each end, caught 44 points wide and high. No more than a quarter of the
    // bar is the handle's, so a short one can still be held to move it.
    private static let gripWidth: CGFloat = 14, catchSize: CGFloat = 44

    private static func catchInside(_ barWidth: CGFloat) -> CGFloat { min(8, barWidth / 4) }

    /// The picked bar's two white handles, over every row (22 Nov: "not handles?").
    @ViewBuilder private func barHandles(_ rows: [[BarItem]], width w: CGFloat, span: Double) -> some View {
        if lifted == nil, selected == nil, let item = pickedBar, let r = rows.firstIndex(where: { (row: [BarItem]) -> Bool in row.contains { (b: BarItem) -> Bool in b.id == item.id } }) {
            barHandle(item, side: 1, row: r, w: w, span: span)
            barHandle(item, side: 2, row: r, w: w, span: span)
        }
    }

    /// side: 1 its start, 2 its end (as BarGrab's modes).
    private func barHandle(_ item: BarItem, side: Int, row: Int, w: CGFloat, span: Double) -> some View {
        let left: CGFloat = w * CGFloat(min(item.from, span) / span)
        let right: CGFloat = w * CGFloat(min(item.to, span) / span)
        let barWidth: CGFloat = max(16, right - left)
        let size: CGFloat = Self.catchSize, inside: CGFloat = Self.catchInside(barWidth)
        let x: CGFloat = side == 1 ? left - (size - inside) : left + barWidth - inside
        let gripX: CGFloat = side == 1 ? size - inside - Self.gripWidth : inside
        let y: CGFloat = CGFloat(row) * (Self.laneHeight + 3) - (size - Self.laneHeight) / 2
        let grip = UnevenRoundedRectangle(topLeadingRadius: side == 1 ? 6 : 0, bottomLeadingRadius: side == 1 ? 6 : 0,
                                          bottomTrailingRadius: side == 2 ? 6 : 0, topTrailingRadius: side == 2 ? 6 : 0, style: .continuous)
        return grip.fill(Color.white)
            .frame(width: Self.gripWidth, height: Self.laneHeight)
            .overlay(Capsule().fill(Color(white: 0.2)).frame(width: 2, height: 14))
            .offset(x: gripX)
            .frame(width: size, height: size, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("bars"))
                .onChanged { handleChanged($0, item, side: side, w: w, span: span) }
                .onEnded { _ in letGo(item) })
            .accessibilityLabel(side == 1 ? "Start of \(item.label)" : "End of \(item.label)")
            .offset(x: x, y: y)
    }

    private func handleChanged(_ v: DragGesture.Value, _ item: BarItem, side: Int, w: CGFloat, span: Double) {
        if barGrab == nil {
            guard abs(v.translation.width) > 1 else { return }
            grabBar(item, mode: side)
        }
        moveBar(v, item, w: w, span: span)
    }

    /// A tile for each row of bars, in the timeline's left column, lined up with its row: what's on it (captions, text,
    /// stickers, voice, music, sound FX, overlays; mixed, a stack), as CapCut heads its tracks.
    private var laneHeads: some View {
        let rows = Array(barRows.prefix(6))
        return VStack(spacing: 3) {
            ForEach(rows.indices, id: \.self) { r in
                Image(systemName: laneIcon(rows[r])).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: Self.laneHeight)
                    .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .allowsHitTesting(false)
    }

    private func laneIcon(_ row: [BarItem]) -> String {
        let icons = Set(row.map { item -> String in
            switch item.kind {
            case 1:
                switch sounds.first(where: { $0.id == item.id })?.kind {
                case "voice": return "mic.fill"
                case "song": return "music.note"
                case "clip": return "speaker.wave.2.fill"
                default: return "waveform"
                }
            case 2: return "rectangle.inset.topright.filled"
            default:
                switch texts.first(where: { $0.id == item.id })?.kind {
                case "caption": return "captions.bubble"
                case "sticker", "card": return "face.smiling"
                default: return "textformat"
                }
            }
        })
        return icons.count == 1 ? icons.first! : "square.stack.fill"
    }

    /// The timeline slid by a finger: the video under the line follows it, held on a clip's edge when it's near one.
    private func scrubTimeline(by dx: CGFloat, from start: CGPoint, mid: CGFloat, pps: CGFloat) {
        if scrubSkip { return }
        // a bar held and lifted, or being moved: the timeline keeps still under it from then on
        if lifted != nil || barGrab != nil { return }
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
        // a bar's middle is the timeline's until the bar's held (lifted); a picked bar's handles are its own
        guard selected == nil, let item = pickedBar, let r = rowOf(item.id), r < 6 else { return false }
        let top: CGFloat = lanesTop + CGFloat(r) * (Self.laneHeight + 3) - (Self.catchSize - Self.laneHeight) / 2
        guard p.y >= top, p.y <= top + Self.catchSize else { return false }
        let end: Double = min(item.to, max(total, 0.01))
        let x0: CGFloat = shift + CGFloat(item.from) * pps
        let barWidth: CGFloat = max(16, CGFloat(end - item.from) * pps)
        let inside: CGFloat = Self.catchInside(barWidth), outside: CGFloat = Self.catchSize - inside
        let x1: CGFloat = x0 + barWidth
        return (p.x >= x0 - outside && p.x <= x0 + inside) || (p.x >= x1 - inside && p.x <= x1 + outside)
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
            action("captions.bubble", "Caption this", on: has && soundOf == nil) { if let i = index { makeCaptions(.clip(clips[i].id)) } }
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
            .frame(minWidth: 52).frame(height: 50).contentShape(Rectangle())
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
                .contentShape(Rectangle())
                // drag along it to move the line through the clip, held on a diamond when near one (21 Nov)
                .gesture(stripScrub(width: w, marks: c.keys.map { w * CGFloat(($0.at - c.start) / span) }) { x in
                    startOf(i) + Double(x / max(w, 1)) * span / max(c.speed, 0.01)
                })
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
    /// A keyframe strip's scrub: the line goes where the finger is along it (paused), held on a keyframe's diamond
    /// when it comes within 10 points of one, with a tap; a tap on a diamond goes to it.
    private func stripScrub(width w: CGFloat, marks: [CGFloat], time: @escaping (CGFloat) -> Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if player.rate != 0 { player.pause(); playing = false }
                var x = min(max(0, v.location.x), w)
                if let m = marks.min(by: { abs($0 - x) < abs($1 - x) }), abs(m - x) <= 10 {
                    if abs(m - x) > 0.5, stripHeld != m { UISelectionFeedbackGenerator().selectionChanged() }
                    stripHeld = m; x = m
                } else { stripHeld = nil }
                seek(min(max(0, time(x)), max(0, total - 0.01)))
            }
            .onEnded { _ in stripHeld = nil }
    }

    private func keyButton(_ here: Bool, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: here ? "diamond.fill" : "diamond").font(.system(size: 11, weight: .bold)).foregroundStyle(here ? Color.yellow : Color.white)
                Text(here ? "Remove" : "Keyframe").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 96, height: 30)   // the same width whichever it says (21 Nov: the strip beside it jumped)
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
        // (the line stays where it is: 21 Nov, it jumped to the clip's start, and the timeline with it)
    }

    /// The selected clip in two at the line (the line has to be inside it).
    private func splitHere() {
        guard let i = index else { return }
        let into = (now - startOf(i)) * clips[i].speed
        guard let (a, b) = ClipJoin.split(clips[i], at: into) else { return }
        change { var all = $0; all[i] = a; all.insert(b, at: i + 1); return all }
        selected = b.id
    }

    /// Where each voiceover plays and which part of it: a change moves the captions of what's said in it.
    private var voiceSpans: [[Double]] {
        sounds.filter { (s: EditSound) -> Bool in s.kind == "voice" }.map { (s: EditSound) -> [Double] in [s.from, s.start, s.length] }
    }
    private func voiceMoved() {
        // (once it's let go, not each step: made again as it was trimmed, the words passed on the way were dropped for
        // good when it was dragged back out, and every step of the drag had that work to do)
        guard barGrab == nil else { return }
        let ids: Set<UUID> = Set(sounds.map { (s: EditSound) -> UUID in s.id })
        let tied = texts.contains { (t: EditText) -> Bool in
            guard t.kind == "caption", let words = t.words else { return false }
            return words.contains { (w: EditText.Word) -> Bool in w.clip.map { ids.contains($0) } ?? false }
        }
        if tied { texts = EditOverlays.reanchor(texts, clips: clips, sounds: sounds) }
    }

    private func remember() { history.append(Snap(clips: clips, sounds: sounds, texts: texts)); future = []; if history.count > 30 { history.removeFirst() } }
    /// Every text, caption, sticker, sound and overlay moved as far as the clip it starts over has moved.
    private func follow(from old: [Clip], to new: [Clip]) {
        guard !old.isEmpty, !new.isEmpty else { return }
        let was = ClipJoin.starts(old), now = ClipJoin.starts(new)
        var at: [UUID: Double] = [:]
        for (i, c) in new.enumerated() { at[c.id] = now[i] }
        // how far the clip under `t` has moved (nothing for one taken out)
        func moved(_ t: Double) -> Double {
            guard let i = was.lastIndex(where: { $0 <= t + 0.001 }), let n = at[old[i].id] else { return 0 }
            return n - was[i]
        }
        // captions go with their words (21 Nov): each word tied to the clip and moment it was said in, then put
        // where that now plays; trimmed-out words go
        texts = EditOverlays.anchor(texts, clips: old)
        let tied = Set(texts.filter { $0.kind == "caption" && !($0.words ?? []).isEmpty && ($0.words ?? []).allSatisfy { $0.src != nil } }.map(\.id))
        for k in texts.indices where texts[k].part != "recipe" && !tied.contains(texts[k].id) {
            let d = moved(texts[k].from)
            guard abs(d) > 0.0005 else { continue }
            texts[k].from = max(0, texts[k].from + d); texts[k].to = max(texts[k].from + 0.1, texts[k].to + d)
            if let w = texts[k].words { texts[k].words = w.map { EditText.Word(text: $0.text, at: max(0, $0.at + d)) } }
        }
        for k in sounds.indices where sounds[k].kind != "song" {
            let d = moved(sounds[k].from)
            if abs(d) > 0.0005 { sounds[k].from = max(0, sounds[k].from + d) }
        }
        for k in pips.indices {
            let d = moved(pips[k].from)
            if abs(d) > 0.0005 { pips[k].from = max(0, pips[k].from + d) }
        }
        texts = EditOverlays.reanchor(texts, clips: new, sounds: sounds)
        // a caption running across a join stays while the next moves back with its clip: each one ends where
        // the next begins, so two are never shown over each other (21 Nov: "Unglazed" drawn over "turns black")
        let caps = texts.indices.filter { texts[$0].kind == "caption" }.sorted { texts[$0].from < texts[$1].from }
        for (a, b) in zip(caps, caps.dropFirst()) where texts[a].to > texts[b].from {
            texts[a].to = max(texts[a].from + 0.1, texts[b].from)
        }
        if recipe != nil { remakeRecipe() }
    }

    private func change(_ f: ([Clip]) -> [Clip]) { remember(); withAnimation(.snappy) { clips = f(clips) } }
    private func undo() {
        guard let last = history.popLast() else { return }
        future.append(Snap(clips: clips, sounds: sounds, texts: texts)); restore(last)
    }
    private func redo() {
        guard let next = future.popLast() else { return }
        history.append(Snap(clips: clips, sounds: sounds, texts: texts)); restore(next)
    }
    private func restore(_ s: Snap) {
        withAnimation(.snappy) { clips = s.clips; sounds = s.sounds; texts = s.texts }
        // the sounds and texts as they were with these clips: put back after follow() has moved them with the clips
        DispatchQueue.main.async { sounds = s.sounds; texts = s.texts }
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

    private func seek(_ s: Double) { player.seek(to: CMTime(seconds: max(0, s), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); now = s; followCaption(s) }

    /// A caption being edited, and the line moves on (played or slid) into another: that one's picked, as CapCut
    /// does, so the panel is always for the caption on screen.
    private func followCaption(_ t: Double) {
        guard let id = selectedText, let cur = texts.first(where: { (x: EditText) -> Bool in x.id == id }), cur.kind == "caption" else { return }
        guard t < cur.from || t >= cur.to else { return }
        if let next = texts.first(where: { (x: EditText) -> Bool in x.kind == "caption" && t >= x.from && t < x.to }) { selectedText = next.id }
    }

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
            s += ",\(c.transition?.kind ?? ""),\(c.transition?.length ?? 0),\(c.transition?.direction ?? "")"
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
                followCaption(t)
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
        let items = texts, size = frameSize
        making = Task {
            guard await EditOverlays.prepare(items) else {
                // (22 Nov: made without its frames, a GIF was a yellow box in the video)
                if !Task.isCancelled { joining = false; progress = nil; making = nil; flash("A GIF didn't load. Check your connection and try again, or take it off.") }
                return
            }
            let over = EditOverlays.pieces(items, frame: size)
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
    /// A caption picked and held up while paused: the others aren't drawn with it (21 Nov: two drawn over each other
    /// after a split).
    private var heldCaption: UUID? {
        guard !playing, let id = selectedText, texts.contains(where: { (x: EditText) -> Bool in x.id == id && x.kind == "caption" }) else { return nil }
        return id
    }

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
                // the one picked is held up while it's edited; playing, only what's on at the line shows (21 Nov: the
                // picked caption stayed up while the others played under it)
                if (on && !playing) || (now >= item.from && now < item.to && !(item.kind == "caption" && heldCaption != nil)) {
                    // a calorie count held still shows its number, not the 0 it counts up from (21 Nov: "always 0":
                    // put on at the line, it was drawn at the very start of its count); playing, it counts as posted
                    EditTextView(item: item, at: item.kind == "calories" && !playing ? max(now, item.from + 1.3) : now).padding(24)
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

    /// The bar picked on the timeline (its tools under it), if one is.
    private var pickedBar: BarItem? {
        guard let id = selectedText ?? selectedSound ?? selectedPip else { return nil }
        return barItems.first { $0.id == id }
    }

    /// A bar picked on the timeline: just picked, the line at it if it isn't already over it; no panel.
    private func pickBar(_ item: BarItem) {
        selected = nil; selectedText = nil; selectedSound = nil; selectedPip = nil
        switch item.kind {
        case 1: selectedSound = item.id
        case 2: selectedPip = item.id
        default: selectedText = item.id
        }
        player.pause(); playing = false
        if now < item.from || now >= item.to { seek(item.from + 0.01) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A picked bar's tools, as CapCut's row changes for what's picked: its panel (Edit), the captions' list, a copy,
    /// taking it off; ‹ goes back to the tools for the whole video.
    private func barTools(_ b: BarItem) -> some View {
        let caption = b.kind == 0 && texts.first(where: { $0.id == b.id })?.kind == "caption"
        return HStack(spacing: 0) {
            Button { withAnimation(.snappy) { selectedText = nil; selectedSound = nil; selectedPip = nil } } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Back to the tools for the whole video")
            Rectangle().fill(Color(white: 0.17)).frame(width: 1, height: 30).padding(.trailing, 4)
            toolRow {
                action("slider.horizontal.3", caption ? "Style" : "Edit", on: true) {
                    switch b.kind {
                    case 1: selectSound(b.id)
                    case 2: selectPip(b.id)
                    default: selectText(b.id)
                    }
                }
                if caption {
                    action("list.bullet", "Edit captions", on: true) { listPicked = b.id; withAnimation(.snappy) { panel = .captionList } }
                }
                if b.kind == 0 { action("plus.square.on.square", "Copy", on: true) { copyText(b.id) } }
                action("trash", "Delete", on: true) { deleteBar(b) }
            }
        }
    }

    /// A text, sticker or caption copied, straight after itself, and picked.
    private func copyText(_ id: UUID) {
        guard let t = texts.first(where: { $0.id == id }) else { return }
        remember()
        var c = t, len = t.to - t.from
        len = max(0.3, len)
        c.id = UUID(); c.from = min(t.to, max(0, total - len)); c.to = c.from + len
        if let w = t.words { c.words = w.map { var x = $0; x.at += c.from - t.from; x.src = nil; return x } }
        texts.append(c)
        selectedText = c.id
    }

    /// A picked bar taken off.
    private func deleteBar(_ b: BarItem) {
        switch b.kind {
        case 1: takeOff(b.id)
        case 2: pips.removeAll { $0.id == b.id }
        default: remember(); texts.removeAll { $0.id == b.id }
        }
        selectedText = nil; selectedSound = nil; selectedPip = nil
    }

    /// What can be put over the video, when no clip is picked (the mockup's bottom row).
    private var addTools: some View {
        toolRow {
                action("textformat", "Text", on: true) { addText() }
                action("face.smiling", "Stickers", on: true) { player.pause(); playing = false; stickering = true }
                action("captions.bubble", "Captions", on: true) {
                    if texts.contains(where: { $0.kind == "caption" }) { withAnimation(.snappy) { panel = .captions } } else { makeCaptions() }
                }
                action("fork.knife", "Recipe", on: true) { if recipe != nil { withAnimation(.snappy) { panel = .recipe } } else { attachMode = "recipe" } }
                action("dumbbell", "Workout", on: true) { attachMode = "workout" }
                action("mic.fill", "Voice", on: true) { withAnimation(.snappy) { panel = .voice } }
                action("waveform", "Sound FX", on: true) { withAnimation(.snappy) { panel = .effects } }
                action("rectangle.inset.topright.filled", "Overlay", on: true) { pipPicking = true }
                // Music and its beats as one (21 Nov: "both are the same? Let's just have music")
                action("music.note", "Music", on: true) {
                    if sounds.contains(where: { $0.kind == "song" }) { withAnimation(.snappy) { panel = .beats } } else { choosingSong = true }
                }
                action("square.grid.2x2", "Templates", on: true) { player.pause(); templating = true }
        }
        .padding(.top, 2)
    }

    /// Everything laid over the video as bars, in rows so none covers another: drag one along, or by an end for when it
    /// starts and stops; tap it to change it. Text and stickers, then the sounds.
    private var barItems: [BarItem] {
        texts.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: $0.barLabel, colour: $0.barColour, kind: 0, lane: $0.lane) }
            + sounds.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: Self.soundMark($0.kind) + $0.name, colour: Self.soundColour($0.kind), kind: 1, lane: $0.lane) }
            + pips.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: "▣ Overlay" + ($0.keys.isEmpty ? "" : " · ◆"), colour: Color(red: 0.36, green: 0.82, blue: 0.56), kind: 2, lane: $0.lane) }
    }

    /// The bars in rows: one put on a row (held and dragged there) is on it; the rest in rows of their own kind where
    /// they don't cover another, as before. Empty rows close up.
    private var barRows: [[BarItem]] {
        var rows: [[BarItem]] = []
        // (while one's held, each keeps the row it had: packed again as it moved, the bar under the finger jumped
        // rows, so was a new view each time and lost the finger, 22 Nov)
        let held = heldRows
        for t in barItems {
            guard let lane = held[t.id] ?? t.lane else { continue }
            let l = max(0, lane)
            while rows.count <= l { rows.append([]) }
            rows[l].append(t)
        }
        rows = rows.filter { !$0.isEmpty }.map { $0.sorted { $0.from < $1.from } }
        let fixed = rows.count
        for t in barItems.filter({ held[$0.id] == nil && $0.lane == nil }).sorted(by: { $0.from < $1.from }) {
            let free = rows.indices.first { r in
                r >= fixed && rows[r].last?.kind == t.kind && (rows[r].last?.to ?? 0) <= t.from + 0.01
            }
            if let r = free { rows[r].append(t) } else { rows.append([t]) }
        }
        return rows
    }

    /// The row a bar's on now.
    private func rowOf(_ id: UUID) -> Int? { barRows.firstIndex { $0.contains { $0.id == id } } }

    /// The rows as they are, held like that till the bar that's been caught is let go.
    private func holdRows() {
        guard heldRows.isEmpty else { return }
        var held: [UUID: Int] = [:]
        for (r, row) in barRows.enumerated() { for item in row { held[item.id] = r } }
        heldRows = held
    }

    /// Whether a bar can be on a row as it is: only with its own kind (sound with sound, as CapCut's tracks) and
    /// covering none there.
    private func joins(_ item: BarItem, _ row: [BarItem]) -> Bool {
        for o in row where o.id != item.id {
            if o.kind != item.kind { return false }
            if min(o.to, item.to) - max(o.from, item.from) > 0.01 { return false }
        }
        return true
    }

    /// A bar held and dropped on another row (or the new one under the last): every bar keeps the row it's shown on,
    /// this one goes to that row (a new row there when it would cover one already on it), and the texts and overlays
    /// are drawn in row order, the top row on top (design/capcut-timeline-mockup.html).
    private func dropBar(_ id: UUID, on target: Int) {
        var rows = barRows.map { $0.map(\.id) }
        guard let from = rows.firstIndex(where: { $0.contains(id) }) else { return }
        guard let item = barItems.first(where: { $0.id == id }) else { return }
        let shown = barRows
        rows[from].removeAll { $0 == id }
        var to = min(max(0, target), rows.count)
        if to == rows.count { rows.append([id]) }
        else if joins(item, shown[to]) { rows[to].append(id) }
        // a new row of its own: past that one going down (above it would be where it came from), over it going up
        else { rows.insert([id], at: to >= from ? to + 1 : to) }
        rows = rows.filter { !$0.isEmpty }
        to = rows.firstIndex { $0.contains(id) } ?? to
        var lane: [UUID: Int] = [:]
        for (r, ids) in rows.enumerated() { for i in ids { lane[i] = r } }
        for k in texts.indices { texts[k].lane = lane[texts[k].id] }
        for k in sounds.indices { sounds[k].lane = lane[sounds[k].id] }
        for k in pips.indices { pips[k].lane = lane[pips[k].id] }
        // drawn in order: the bottom row first, so the top row is over it
        func ordered<T>(_ xs: [T], _ l: (T) -> Int?) -> [T] {
            xs.enumerated().sorted { a, b in
                let la = l(a.element) ?? Int.max, lb = l(b.element) ?? Int.max
                return la != lb ? la > lb : a.offset < b.offset
            }.map(\.element)
        }
        texts = ordered(texts) { $0.lane }
        pips = ordered(pips) { $0.lane }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                .coordinateSpace(name: "bars")
            }
        }
        .frame(height: min(60, CGFloat(shownRows.count) * 21))
    }

    /// Where a bar's edge at `t` is held: the nearest within `reach` of a clip's start or end, another bar's start or end,
    /// or the line.
    private func snapTarget(_ t: Double, reach: Double, except: UUID) -> Double? {
        var targets = ClipJoin.starts(clips) + [total, now]
        for b in barItems where b.id != except { targets.append(b.from); targets.append(b.to) }
        guard let best = targets.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= reach else { return nil }
        return best
    }

    /// `onTimeline`: there the line stays put while a bar's dragged (else the timeline slides under the finger), and
    /// goes to the bar after.
    private func bar(_ item: BarItem, w: CGFloat, span: Double, onTimeline: Bool = false) -> some View {
        let x0 = w * CGFloat(min(item.from, span) / span), x1 = w * CGFloat(min(item.to, span) / span)
        let width = max(16, x1 - x0), on = item.id == selectedText || item.id == selectedSound || item.id == selectedPip
        // (on the timeline a slim tag, design/pro-ui)
        let h: CGFloat = onTimeline ? Self.laneHeight : 18, corner: CGFloat = onTimeline ? 7 : 5, up = lifted == item.id
        return Text(item.label).font(.system(size: onTimeline ? 11 : 9, weight: onTimeline ? .semibold : .heavy)).lineLimit(1).foregroundStyle(.black.opacity(0.82))
            .padding(.horizontal, onTimeline ? 8 : 5).frame(width: width, height: h, alignment: .leading)
            .background(item.colour.opacity(onTimeline && !up ? 0.88 : 1), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(on ? Color.white : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            // held, it lifts (as CapCut's do): solid, a little bigger, a shadow under it, in the row it would go on
            // (22 Nov: see-through and loose under the finger, "doesn't feel as smooth as CapCut")
            .scaleEffect(up ? 1.08 : 1)
            .shadow(color: .black.opacity(up ? 0.6 : 0), radius: 8, y: 5)
            .offset(y: up ? liftDY : 0)
            // A tap picks it; held a third of a second it lifts, with a tick, and only then moves (21 Nov: a drag
            // moved it at once, so a slightly-off scroll or tap moved a bar). A picked bar's ends trim it straight
            // away; a drag anywhere else is the timeline's. Measured in the bars' rows, which keep still, not in the
            // bar itself: measured in it, each step counted part of its own move back (21 Nov: a separated sound)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("bars"))
                .onChanged { barChanged($0, item, x0: x0, width: width, endsTrim: on && !onTimeline, w: w, span: span, rowHeight: onTimeline ? Self.laneHeight + 3 : 21) }
                .onEnded { barEnded($0, item) })
            .offset(x: x0)
            .accessibilityElement()
            .accessibilityLabel("\(item.label), \(Self.clock(item.from)) to \(Self.clock(item.to))")
            .accessibilityHint("Double tap to change it")
            .accessibilityAddTraits(.isButton)
            .zIndex(up ? 2 : 0)   // (last, for its row to see)
    }

    /// A finger on a bar, moving (kept out of bar()'s chain: the compiler timed out on a long one, 1.4.21).
    private func barChanged(_ v: DragGesture.Value, _ item: BarItem, x0: CGFloat, width: CGFloat, endsTrim: Bool, w: CGFloat, span: Double, rowHeight: CGFloat) {
        let dist = hypot(v.translation.width, v.translation.height)
        if pressed != item.id {
            pressed = item.id; pressMoved = false; lifted = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard pressed == item.id, !pressMoved, barGrab == nil else { return }
                holdRows()
                withAnimation(.snappy(duration: 0.15)) { lifted = item.id }
                player.pause(); playing = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        if dist > 8, lifted == nil, barGrab == nil { pressMoved = true }
        if barGrab == nil {
            // by its ends once it's picked, or anywhere once it's lifted to move it
            let at = v.startLocation.x - x0   // (where on the bar: it hasn't moved yet)
            let mode = lifted == item.id ? 0 : (at < 12 ? 1 : (at > width - 12 ? 2 : 0))
            guard lifted == item.id || (mode != 0 && endsTrim && dist > 2) else { return }
            grabBar(item, mode: mode)
        }
        // lifted: up or down a row at a time, into the row it would go on (the empty rail under the last too)
        if lifted == item.id, barGrab != nil, let here = rowOf(item.id) {
            let to = min(max(0, here + Int((v.translation.height / rowHeight).rounded())), min(barRows.count, 5))
            let next: Int? = to == here ? nil : to
            if next != dropRow {
                withAnimation(.snappy(duration: 0.15)) { dropRow = next; liftDY = CGFloat(to - here) * rowHeight }
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        moveBar(v, item, w: w, span: span)
    }

    /// A bar caught, to move it (mode 0) or trim its start (1) or end (2).
    private func grabBar(_ item: BarItem, mode: Int) {
        // held still under the finger while it's moved (21 Nov: playing on, the timeline slid away
        // under the bar being dragged)
        player.pause(); playing = false
        holdRows()
        remember()   // (moved or trimmed, it can be undone)
        if item.kind == 1, let s = sounds.first(where: { $0.id == item.id }) {
            barGrab = BarGrab(id: item.id, mode: mode, from: s.from, to: s.to, words: nil, start: s.start)
        } else if item.kind == 2, let p = pips.first(where: { $0.id == item.id }) {
            barGrab = BarGrab(id: item.id, mode: mode, from: p.from, to: p.to, words: nil, start: p.start)
        } else if let t = texts.first(where: { $0.id == item.id }) {
            barGrab = BarGrab(id: item.id, mode: mode, from: t.from, to: t.to, words: t.words)
        }
    }

    /// The bar that's caught, moved or trimmed as far as the finger's gone.
    private func moveBar(_ v: DragGesture.Value, _ item: BarItem, w: CGFloat, span: Double) {
        guard let g = barGrab else { return }
        var dt = Double(v.translation.width / max(w, 1)) * span
        // held on a clip's start or end, another bar's, or the line, when it comes within 8 points of
        // one, with a tap; anywhere else it goes where the finger puts it (21 Nov: the owner, "snap to
        // the in or outs or where the cursor is")
        let reach = Double(8 / max(w, 1)) * span
        let edges = g.mode == 2 ? [g.to] : (g.mode == 1 ? [g.from] : [g.from, g.to])
        var held: (dt: Double, at: Double)?
        for e in edges {
            if let at = snapTarget(e + dt, reach: reach, except: g.id), held == nil || abs(at - e - dt) < abs(held!.dt - dt) {
                held = (at - e, at)
            }
        }
        if let held {
            dt = held.dt
            if barSnap != held.at { barSnap = held.at; UISelectionFeedbackGenerator().selectionChanged() }
        } else { barSnap = nil }
        // the line stays where it is while it's moved (21 Nov: it followed the bar, and the timeline jumped)
        switch item.kind {
        case 1: dragSound(g, dt, span: span, follow: false)
        case 2: dragPip(g, dt, span: span, follow: false)
        default: dragText(g, dt, span: span, follow: false)
        }
    }

    /// The finger off a bar: a tap picks it; a move is done.
    private func barEnded(_ v: DragGesture.Value, _ item: BarItem) {
        // a tap (not held, not moved): it's picked. On the timeline, only picked: the timeline stays, with its trim
        // frame, and the row under it is its tools (CapCut's, 21 Nov: the panel opened at once and hid the timeline
        // the bar was on, so its ends couldn't be trimmed nor it held there). In a panel's bars, its panel, as before.
        if barGrab == nil, lifted == nil, hypot(v.translation.width, v.translation.height) < 6 {
            if panel == nil { pickBar(item) } else {
                switch item.kind {
                case 1: selectSound(item.id)
                case 2: selectPip(item.id)
                default: selectText(item.id)
                }
            }
        }
        letGo(item)
    }

    /// The finger off a bar or one of its handles.
    private func letGo(_ item: BarItem) {
        if barGrab != nil, let here = rowOf(item.id), let moved = barItems.first(where: { (b: BarItem) -> Bool in b.id == item.id }) {
            let covers = barRows[here].contains { (o: BarItem) -> Bool in
                o.id != moved.id && min(o.to, moved.to) - max(o.from, moved.from) > 0.01
            }
            // onto the row it was dragged to; moved over another on its own row, a row of its own beside it
            if let d = dropRow { dropBar(item.id, on: d) } else if covers { dropBar(item.id, on: here) }
        }
        dropRow = nil; liftDY = 0; heldRows = [:]
        pressed = nil; pressMoved = false; lifted = nil
        // (the line left where it was: 21 Nov, it jumped to the bar's start when it was let go)
        let changed = barGrab != nil
        barSnap = nil
        barGrab = nil
        guard changed, item.kind != 0 else { return }
        // a sound or overlay moved: the preview made again with it, now it's let go
        dropped += 1
        // and a voiceover's captions put with it
        if item.kind == 1 { voiceMoved() }
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
            Text("Tap one to put it in at \(Self.code(now)), where the line is").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(SoundEffects.names, id: \.self) { name in
                    Button {
                        let length = SoundEffects.length(name)
                        remember()
                        sounds.append(EditSound(kind: "effect", name: name, from: now, length: max(0.05, min(length, total - now)), full: length))
                        UISelectionFeedbackGenerator().selectionChanged()
                        flash("\(name) added at \(Self.code(now)). It's the new bar above: tap it to move or change it.")
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
                if x.kind == "voice" || x.kind == "clip" { soundTile("captions.bubble", "Caption this", on: false) { makeCaptions(.sound(x.id)) } }
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
                .contentShape(Rectangle())
                .gesture(stripScrub(width: w, marks: keys.map { w * CGFloat((s.videoTime($0.at) - s.from) / span) }) { x in
                    s.from + Double(x / max(w, 1)) * span
                })
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
        withAnimation(.snappy) { panel = .beats }
    }

    /// Music: the song, its volume and fades, taking it off, and its beats with the clips cut to land on them.
    private var beatsPanel: some View {
        let song = sounds.first(where: { $0.kind == "song" })
        return VStack(spacing: 10) {
            HStack {
                Image(systemName: "music.note").foregroundStyle(Self.soundColour("song"))
                Text(song?.name ?? "No song").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(song == nil ? "Add a song" : "Change song") { choosingSong = true }.font(.caption.weight(.bold)).foregroundStyle(.white)
            }
            if let song {
                HStack(spacing: 8) {
                    wide("Volume and fade", "slider.horizontal.3") { selectSound(song.id) }
                    wide("Take off", "trash", warn: true) {
                        remember()
                        sounds.removeAll { $0.kind == "song" }
                        withAnimation(.snappy) { panel = nil }
                    }
                }
            }
            if songBeats.count > 2 {
            Text("Cut to the beat").font(.caption.weight(.semibold)).foregroundStyle(Self.quiet).frame(maxWidth: .infinity, alignment: .leading)
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
            } else if song != nil {
                Text("No steady beat found in this song to cut to.").font(.caption).foregroundStyle(.secondary)
            }
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

    /// A template made (21 Nov, design/templates-mockup.html): its song, the clips picked cut to their slots on its
    /// beat, the joins and look, and each slot's words over its clip. The clips that weren't picked go; Undo brings
    /// them back.
    private func makeTemplate(_ t: EditTemplate, _ picked: [Clip], _ slots: [EditTemplate.Slot], _ meal: JSON?) async {
        templating = false
        player.pause(); joining = true
        defer { joining = false }
        var song: EditSound?, beats: [Double] = []
        if let s = Music.all.first(where: { $0.id == t.song }), let mix = await SongMix.make(s, song: 1, clip: 1) {
            let found = await Beats.find(mix.file, from: mix.from, length: mix.span)
            beats = found.map { $0 - mix.from }
            song = EditSound(kind: "song", name: s.title, file: mix.file, from: 0, start: mix.from, length: mix.span, full: mix.from + mix.span, beats: found)
        }
        let laid = EditTemplate.lay(picked, slots: slots, beats: beats, join: t.join, look: t.look)
        guard !laid.isEmpty else { return }
        let long = ClipJoin.total(laid)
        var laidSounds = sounds.filter { $0.kind != "song" }
        if var song { song.length = max(0.5, min(song.length, long)); laidSounds.append(song) }
        let words = EditTemplate.labels(laid, slots: slots)
        var over = texts.filter { $0.part != "template" }
        over += words
        remember()
        selected = nil; selectedText = nil; selectedSound = nil; selectedPip = nil
        withAnimation(.snappy) { clips = laid; panel = nil }
        // put after follow() has moved what was there with the clips (as Undo does)
        DispatchQueue.main.async { sounds = laidSounds; texts = over }
        if let meal { attached = meal; attach(meal) }
        if song == nil { flash("\(t.name): made, cut half a second a beat (the song couldn't be fetched). Change anything you like.") }
        else { flash("\(t.name): made. Change anything you like.") }
        seek(0); player.play()
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
        player.pause(); playing = false
        let t = EditText(kind: "text", text: "", from: now, to: min(max(total, now + 0.5), now + 3))
        texts.append(t)
        selectText(t.id)
        startTyping(t.id)
    }

    /// Typing on the video (design/editor-text-stickers-mockup.html, 1): opened at once, no slide up.
    private func startTyping(_ id: UUID) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { typing = id }
    }

    /// Typing done: an empty one taken off.
    private func endTyping() {
        if let id = typing, let k = texts.firstIndex(where: { $0.id == id }), texts[k].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.remove(at: k)
            if selectedText == id { selectedText = nil; withAnimation(.snappy) { panel = nil } }
        }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { typing = nil }
    }

    /// The text being typed, large in the middle of the dimmed video: its typefaces along the top, its size on the
    /// left, its looks and colours over the keyboard (as Instagram's and CapCut's are).
    private func typingView(_ k: Int) -> some View {
        let item = texts[k]
        let ink = EditText.colour(item.colour)
        let words = Binding(get: { texts.indices.contains(k) ? texts[k].text : "" }, set: { if texts.indices.contains(k) { texts[k].text = $0 } })
        let field = TextField("Type something", text: words, axis: .vertical)
            .font(EditText.font(item.font, size: 38 * CGFloat(item.size)))
            .multilineTextAlignment(.center).lineLimit(1...6)
            .focused($typingFocus)
            .tint(Color(red: 1, green: 0.84, blue: 0.04))
        return ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { endTyping() }
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(EditText.fonts, id: \.self) { fo in
                        Button { texts[k].font = fo == "classic" ? nil : fo } label: {
                            Text("Aa").font(EditText.font(fo, size: 14)).frame(width: 36, height: 36)
                                .foregroundStyle((item.font ?? "classic") == fo ? Color.black : Color.white)
                                .background((item.font ?? "classic") == fo ? Color.white : Color.black.opacity(0.5), in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Typeface " + fo)
                    }
                    Spacer()
                    Button { endTyping() } label: {
                        Text("Done").font(.subheadline.weight(.heavy)).foregroundStyle(.black).padding(.horizontal, 16).frame(height: 34).background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.top, 10)
                Spacer(minLength: 10)
                Group {
                    switch item.style {
                    case "Box":
                        field.foregroundStyle(EditText.ink(on: item.colour)).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    case "Outline":
                        let edge = EditText.ink(on: item.colour) == .black ? Color.black : Color.white
                        field.foregroundStyle(ink)
                            .shadow(color: edge, radius: 0, x: 1.5, y: 1.5).shadow(color: edge, radius: 0, x: -1.5, y: -1.5)
                            .shadow(color: edge, radius: 0, x: 1.5, y: -1.5).shadow(color: edge, radius: 0, x: -1.5, y: 1.5)
                    case "Plain": field.foregroundStyle(ink)
                    default: field.foregroundStyle(ink).shadow(color: .black.opacity(0.7), radius: 4, y: 2)
                    }
                }
                .padding(.horizontal, 44)
                Spacer(minLength: 10)
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(EditText.textStyles, id: \.self) { st in
                            Button { UISelectionFeedbackGenerator().selectionChanged(); texts[k].style = st } label: {
                                Text(st).font(.caption.weight(.heavy)).padding(.horizontal, 12).frame(height: 30)
                                    .foregroundStyle(item.style == st ? Color.black : Color.white)
                                    .background(item.style == st ? Color.white : Color.black.opacity(0.55), in: Capsule())
                                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // any colour, from the wheel
                            ColorPicker("Any colour", selection: Binding(get: { EditText.colour(texts.indices.contains(k) ? texts[k].colour : "white") },
                                                                         set: { c in if texts.indices.contains(k) { texts[k].colour = Self.hex(c) } }), supportsOpacity: false)
                                .labelsHidden().frame(width: 30, height: 30)
                            ForEach(EditText.palette, id: \.self) { c in
                                Circle().fill(StoryArt.color(c)).frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 2))
                                    .padding(3)
                                    .overlay(Circle().stroke(.white, lineWidth: item.colour.uppercased() == c ? 2 : 0))
                                    .onTapGesture { texts[k].colour = c }
                                    .accessibilityLabel("Colour " + c)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            // its size, up the left side
            HStack {
                Slider(value: Binding(get: { texts.indices.contains(k) ? texts[k].size : 1 }, set: { if texts.indices.contains(k) { texts[k].size = $0 } }), in: 0.5...2.5)
                    .tint(.white).frame(width: 200).rotationEffect(.degrees(-90)).frame(width: 30, height: 200)
                    .accessibilityLabel("Text size")
                Spacer()
            }
            .padding(.leading, 6).offset(y: -40)
        }
        .presentationBackground(.clear)
        .onAppear { typingFocus = true }
    }

    /// A colour as "#RRGGBB".
    static func hex(_ c: Color) -> String {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        func two(_ v: CGFloat) -> String { String(format: "%02X", Int((min(1, max(0, v)) * 255).rounded())) }
        return "#" + two(r) + two(g) + two(b)
    }

    /// A tile picked in the sticker tray that wasn't placed straight away: made from today's numbers, or asked for.
    private func addCard(_ id: String) {
        let s = Store.shared
        switch id {
        // a food's calories, counting up (21 Nov: what the Calories button was)
        case "food": attachMode = "calories"
        case "photo": pipPicking = true
        case "macros":
            let m = s.macros(s.todayItems)
            placeCard(["type": "macros", "p": Int(m.p), "c": Int(m.c), "f": Int(m.f), "kcal": Int(s.eaten)])
        case "streak": placeCard(["type": "streak", "days": s.streakInfo.days])
        case "left": placeCard(["type": "left", "kcal": Int(max(0, s.left))])
        case "time": placeCard(["type": "time", "text": Date().formatted(date: .omitted, time: .shortened)])
        case "ring": placeCard(["type": "ring", "eaten": Int(s.eaten), "budget": Int(s.budgetToday)])
        case "steps": placeCard(["type": "steps", "steps": Steps.shared.today ?? 0])
        case "badge":
            if let b = StickerSheet.latestBadge { placeCard(["type": "badge", "id": b]) } else { flash("Earn a badge first") }
        case "rank": placeCard(["type": "rank", "level": s.rank.level])
        case "cheat":
            if let d = StickerSheet.daysToCheat { placeCard(["type": "cheat", "days": d]) } else { flash("Set a cheat day first") }
        case "hashtag": placeCard(["type": "hashtag", "text": "cheatday"])
        case "place":
            Task { if let sub = await Locator.shared.suburb() { placeCard(["type": "place", "text": sub]) } else { flash("Couldn't find your suburb") } }
        default: addSticker(id)
        }
    }

    /// A story sticker put on at the line, for three seconds; a GIF's frames fetched for the finished video meanwhile.
    private func placeCard(_ o: JSON) {
        if str(o["type"]) == "emoji" { addSticker(str(o["text"])); return }
        guard let d = try? JSONSerialization.data(withJSONObject: o), let json = String(data: d, encoding: .utf8) else { return }
        let names = ["gif": "GIF", "sticker3d": "Sticker", "macros": "Macros", "streak": "Streak", "left": "Calories left", "ring": "Today",
                     "steps": "Steps", "badge": "Badge", "rank": "Rank", "cheat": "Cheat day", "time": "Time", "place": "Place", "hashtag": "#" + str(o["text"])]
        var t = EditText(kind: "card", text: names[str(o["type"])] ?? "Sticker", x: 0.5, y: 0.4, from: now, to: min(max(total, now + 0.5), now + 3))
        t.card = json
        texts.append(t)
        selectText(t.id)
        if str(o["type"]) == "gif" { Task { await EditOverlays.prepare([t]) } }
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

    /// What captions are made for (21 Nov: a voiceover or clips added after meant making them all again).
    private enum CaptionJob: Equatable { case all, gaps, sound(UUID), clip(UUID) }

    /// Captions from what's said in it, made on the phone: all of it again (the clips and every voiceover), only the
    /// gaps (what's said where there are none yet), or one voiceover or clip, the rest left as they are.
    private func makeCaptions(_ job: CaptionJob = .all) {
        player.pause(); joining = true
        let kept = clips, sound = soundOf, voices = sounds.filter { ($0.kind == "voice" || $0.kind == "clip") && $0.file != nil }
        let before = texts.filter { $0.kind == "caption" }.count
        Task {
            defer { joining = false }
            do {
                var heard: [EditText] = [], over: ClosedRange<Double>?, lastError: Error?
                func edit() async { do { heard += try await EditOverlays.captions(kept, soundOf: sound) } catch { lastError = error } }
                func voice(_ s: EditSound) async { do { heard += try await EditOverlays.captions(of: s) } catch { lastError = error } }
                switch job {
                case .sound(let id):
                    guard let s = voices.first(where: { $0.id == id }) else { return }
                    await voice(s); over = s.from...max(s.from + 0.1, s.to)
                case .clip(let id):
                    guard let i = kept.firstIndex(where: { $0.id == id }) else { return }
                    let at = ClipJoin.starts(kept)[i]
                    await edit(); over = at...(at + kept[i].span)
                case .all, .gaps:
                    await edit()
                    for v in voices {
                        // a voiceover's words stand in for whatever the clips said under it
                        let before = heard
                        await voice(v)
                        let mine = heard.filter { !before.contains($0) }
                        heard = before.filter { $0.to <= v.from + 0.05 || $0.from >= v.to - 0.05 } + mine
                    }
                }
                if heard.isEmpty, let lastError { throw lastError }
                let made = EditOverlays.regroup(heard.sorted { $0.from < $1.from }, by: captionGroup, lines: captionLines)
                let old = texts.filter { $0.kind == "caption" }   // (Redo all: all of them made again, in the look they had)
                if job == .all { over = -3600...3600 }
                let merged = EditOverlays.merge(old, made, over: over)
                remember()
                texts.removeAll { $0.kind == "caption" }
                texts += merged
                let added = job == .all ? merged.count : max(0, merged.count - before)
                switch job {
                case .gaps: flash(added == 0 ? "No gaps with words in them: every bit that's said has a caption." : "\(added) caption\(added == 1 ? "" : "s") added where there were none.")
                case .all: flash("\(added) caption\(added == 1 ? "" : "s") made. Edit all to fix a word or split a line.")
                default: flash("Captioned. The other captions are as they were.")
                }
                withAnimation(.snappy) { panel = .captions }
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
            // a saved meal or recipe: a food has no method to show (21 Nov)
            guard str(what["kind"]) == "meal" else { flash("Pick a saved meal or recipe: a single food has no method to show."); return }
            recipe = what
            plan = EditOverlays.RecipePlan()
            remakeRecipe()
            withAnimation(.snappy) { panel = .recipe }
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
            } else if item.kind == "text" {
                // typed on the video, with its looks (21 Nov: typed down here, the keyboard pushed the video away)
                wide(item.text.isEmpty ? "Type" : "Edit text", "character.cursor.ibeam") { startTyping(item.id) }
            } else if item.kind == "label" {
                TextField("Words", text: Binding(get: { texts.indices.contains(k) ? texts[k].text : "" }, set: { if texts.indices.contains(k) { texts[k].text = $0 } }))
                    .padding(10).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                TextField("Under it", text: Binding(get: { texts.indices.contains(k) ? texts[k].detail : "" }, set: { if texts.indices.contains(k) { texts[k].detail = $0 } }))
                    .padding(10).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if item.kind != "calories" && item.kind != "card" {
                TextField(item.kind == "caption" ? "What's said" : "Text", text: Binding(get: { texts.indices.contains(k) ? texts[k].text : "" }, set: { if texts.indices.contains(k) { setText(k, $0) } }), axis: .vertical)
                    .lineLimit(1...3).padding(10).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if item.kind == "caption" {
                // this caption's own look (21 Nov: each line can have its own); Apply to all gives every caption it
                HStack(spacing: 6) {
                    ForEach(EditText.captionStyles, id: \.self) { st in chip(st, on: item.style == st) { texts[k].style = st } }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    ForEach(EditText.highlights, id: \.self) { c in
                        Circle().fill(c == "none" ? Color.clear : EditText.colour(c)).frame(width: 26, height: 26)
                            .overlay { if c == "none" { Image(systemName: "nosign").font(.system(size: 15, weight: .bold)).foregroundStyle(.white) } }
                            .overlay(Circle().stroke(.white, lineWidth: (item.highlight ?? "yellow") == c ? 3 : 1))
                            .onTapGesture { texts[k].highlight = c }
                            .accessibilityLabel(c == "none" ? "No highlight" : "Highlight " + c)
                    }
                    Spacer()
                }
                segments([("top", "Top"), ("middle", "Middle"), ("bottom", "Bottom")], item.y < 0.35 ? "top" : (item.y < 0.62 ? "middle" : "bottom")) { w in
                    texts[k].y = w == "top" ? 0.2 : (w == "middle" ? 0.5 : 0.76)
                }
                HStack(spacing: 8) {
                    wide("Apply to all", "square.stack.3d.down.right") {
                        let l = texts[k]
                        for i in texts.indices where texts[i].kind == "caption" {
                            texts[i].style = l.style; texts[i].highlight = l.highlight; texts[i].size = l.size; texts[i].y = l.y; texts[i].x = l.x
                        }
                        flash("Every caption looks like this one now.")
                    }
                    wide("Edit captions", "list.bullet") { listPicked = item.id; withAnimation(.snappy) { panel = .captionList } }
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
            texts[k].words = zip(parts, old).map { var w = $0.1; w.text = $0.0; return w }
        } else if !parts.isEmpty {
            let a = texts[k].from, step = (texts[k].to - a) / Double(parts.count)
            texts[k].words = parts.indices.map { EditText.Word(text: parts[$0], at: a + step * Double($0)) }
        }
    }

    /// A row of choices, one picked (the captions' panels).
    private func segments(_ options: [(String, String)], _ value: String, _ pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                Button { UISelectionFeedbackGenerator().selectionChanged(); pick(o.0) } label: {
                    Text(o.1).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity).frame(height: 32)
                        .foregroundStyle(value == o.0 ? Color.black : Color.white)
                        .background(value == o.0 ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// A wide dark button (the captions' panels).
    private func wide(_ title: String, _ icon: String, warn: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain).foregroundStyle(warn ? Theme.warn : .white)
    }

    private var captionIndices: [Int] { texts.indices.filter { texts[$0].kind == "caption" }.sorted { texts[$0].from < texts[$1].from } }

    /// Every caption made again from its words, as much in each as picked (straight away: no listening again).
    private func regroupCaptions() {
        let caps = texts.filter { $0.kind == "caption" }
        guard !caps.isEmpty else { return }
        remember()
        texts.removeAll { $0.kind == "caption" }
        texts += EditOverlays.regroup(caps, by: captionGroup, lines: captionLines)
        listPicked = nil
    }

    /// The captions as a whole (design/captions-editing-mockup.html, 1): how much is on screen at a time, how many
    /// lines, the look of every one, and the list to edit them in.
    private var captionsPanel: some View {
        let caps = captionIndices
        let style = caps.first.map { texts[$0].style } ?? "Pop"
        return VStack(alignment: .leading, spacing: 8) {
            Text("On screen at a time").font(.caption.weight(.semibold)).foregroundStyle(Self.quiet)
            segments(EditText.captionGroups.map { ($0.id, $0.name) }, captionGroup) { g in captionGroup = g; regroupCaptions() }
            Text("Lines").font(.caption.weight(.semibold)).foregroundStyle(Self.quiet)
            segments([("1", "1"), ("2", "Up to 2")], String(captionLines)) { l in captionLines = Int(l) ?? 1; regroupCaptions() }
            Text("Highlight the word being said").font(.caption.weight(.semibold)).foregroundStyle(Self.quiet)
            segments([("on", "On"), ("off", "Off")], caps.allSatisfy { texts[$0].highlight == "none" } ? "off" : "on") { v in
                remember()
                for i in caps { texts[i].highlight = v == "off" ? "none" : (texts[i].highlight == "none" ? nil : texts[i].highlight) }
            }
            Text("Style").font(.caption.weight(.semibold)).foregroundStyle(Self.quiet)
            HStack(spacing: 6) {
                ForEach(EditText.captionStyles, id: \.self) { st in
                    chip(st, on: caps.allSatisfy { texts[$0].style == st } && style == st) { for i in caps { texts[i].style = st } }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                wide("Edit captions", "list.bullet") { listPicked = nil; withAnimation(.snappy) { panel = .captionList } }
                wide("Fill gaps", "text.badge.plus") { makeCaptions(.gaps) }
            }
            HStack(spacing: 8) {
                wide("Redo all", "arrow.clockwise") { makeCaptions(.all) }
                wide("Take off", "trash", warn: true) {
                    remember()
                    texts.removeAll { $0.kind == "caption" }
                    withAnimation(.snappy) { panel = nil }
                }
            }
            Text("Added a voiceover or more clips? Fill gaps captions only what's new; your edits stay. Or pick a clip or a voiceover and tap Caption this.")
                .font(.caption2).foregroundStyle(Self.quiet)
            Text("\(caps.count) caption\(caps.count == 1 ? "" : "s"). Tap one on the video for its own look.").font(.caption2).foregroundStyle(Self.quiet)
        }
    }

    /// Every caption as a list, as CapCut's Edit captions (21 Nov, design/capcut-timeline-mockup.html): a row each with
    /// a play button and its time, its words typed where they are; the one picked or being said in white, kept in view
    /// as it plays. Over the keyboard: Split at the cursor, Merge up, Merge down, its look, Delete (CaptionField).
    private var captionList: some View {
        let caps = captionIndices
        let saying = caps.first { now >= texts[$0].from && now < texts[$0].to }.map { texts[$0].id }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(caps.indices, id: \.self) { n in
                        captionRow(caps[n], first: n == 0, last: n == caps.count - 1, saying: saying).id(texts[caps[n]].id)
                    }
                }
            }
            .frame(maxHeight: 300)
            .onAppear { if let p = listPicked ?? saying { proxy.scrollTo(p, anchor: .center) } }
            // as it plays, the caption being said stays in view
            .onChange(of: saying) { _, id in if playing, let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }

    private func captionRow(_ k: Int, first: Bool, last: Bool, saying: UUID?) -> some View {
        let c = texts[k], on = c.id == (listPicked ?? saying), talking = playing && c.id == saying
        return HStack(spacing: 8) {
            Button { playCaption(c.id) } label: {
                Image(systemName: talking ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(on ? Color.white : Self.quiet).frame(width: 28, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(talking ? "Pause" : "Play from \(Self.code(c.from))")
            Text(Self.code(c.from)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Self.quiet).frame(width: 40, alignment: .leading)
            CaptionField(text: Binding(get: { texts.indices.contains(k) ? texts[k].text : "" }, set: { if texts.indices.contains(k) { setText(k, $0) } }),
                         active: on, canUp: !first, canDown: !last,
                         focused: { pickCaption(c.id) },
                         split: { splitCaption(c.id, at: $0) },
                         mergeUp: { mergeCaption(c.id, up: true) },
                         mergeDown: { mergeCaption(c.id, up: false) },
                         style: { selectText(c.id) },
                         delete: { deleteCaption(c.id) })
                .frame(height: 44)
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    /// A caption's words tapped to type in: it's the one picked, the video at it.
    private func pickCaption(_ id: UUID) {
        guard listPicked != id, let c = texts.first(where: { $0.id == id }) else { return }
        player.pause(); playing = false
        listPicked = id; if selectedText != nil { selectedText = id }
        seek(c.from + 0.01)
    }

    /// A row's play button: from its start, the list following what's said; tapped while it's being said, paused.
    private func playCaption(_ id: UUID) {
        guard let c = texts.first(where: { $0.id == id }) else { return }
        if playing, now >= c.from, now < c.to { player.pause(); playing = false; return }
        listPicked = nil
        seek(c.from + 0.01); player.play(); playing = true
    }

    /// Split at the cursor: the words before it stay, the rest a caption of its own from when its first word's said.
    private func splitCaption(_ id: UUID, at cursor: Int) {
        guard let k = texts.firstIndex(where: { $0.id == id }) else { return }
        let t = texts[k].text, head = String(t.prefix(max(0, min(cursor, t.count))))
        guard let (a, b) = EditOverlays.split(texts[k], at: head.split(separator: " ").count) else {
            flash("Put the cursor between two words to split there.")
            return
        }
        remember()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        texts[k] = a; texts.append(b)
        listPicked = b.id; if selectedText != nil { selectedText = b.id }
        seek(b.from + 0.01)
    }

    /// With the one before (up) or the one after (down), as one.
    private func mergeCaption(_ id: UUID, up: Bool) {
        let caps = captionIndices
        guard let n = caps.firstIndex(where: { texts[$0].id == id }) else { return }
        if up { if n > 0 { joinNext(caps[n - 1]) } } else { joinNext(caps[n]) }
    }

    private func deleteCaption(_ id: UUID) {
        remember()
        texts.removeAll { $0.id == id }
        if listPicked == id { listPicked = nil }
        if selectedText == id { selectedText = nil }
    }

    /// A caption and the one after it as one.
    private func joinNext(_ k: Int) {
        let caps = captionIndices
        guard let at = caps.firstIndex(of: k), at + 1 < caps.count else { return }
        remember()
        let n = caps[at + 1]
        let joined = EditOverlays.join(texts[k], texts[n])
        let gone = texts[n].id
        texts[k] = joined
        texts.removeAll { $0.id == gone }
        listPicked = joined.id; if selectedText != nil { selectedText = joined.id }
    }

    /// The recipe's overlays made again from the plan (the ones it made before taken off first, and an old recipe's).
    private func remakeRecipe() {
        texts.removeAll { $0.part == "recipe" || ($0.part == nil && ($0.kind == "step" || $0.kind == "macros")) }
        guard let recipe else { return }
        texts += EditOverlays.reel(recipe, clips: clips, plan: plan)
    }

    /// A toggle row: its name, what it is, and the switch.
    private func toggleRow(_ title: String, _ about: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(about).font(.caption).foregroundStyle(Self.quiet)
            }
        }
        .tint(Color(red: 0.19, green: 0.82, blue: 0.35))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func planBinding(_ key: WritableKeyPath<EditOverlays.RecipePlan, Bool>) -> Binding<Bool> {
        Binding(get: { plan[keyPath: key] }, set: { plan[keyPath: key] = $0; remakeRecipe() })
    }

    /// The recipe as a whole (design/editor-recipe-mockup.html, 1): its four parts, each on or off, their look, and
    /// the end's numbers.
    private var recipePanel: some View {
        let meal = recipe ?? [:]
        let steps = EditOverlays.steps(of: meal)
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(str(meal["name"])).font(.subheadline.weight(.heavy)).lineLimit(1)
                    Spacer()
                    Button("Change recipe") { attachMode = "recipe" }.font(.caption.weight(.bold)).foregroundStyle(.white)
                }
                toggleRow("Title card", "At the start", planBinding(\.title))
                toggleRow("Ingredients", "With amounts, after the title", planBinding(\.ingredients))
                HStack(spacing: 6) {
                    toggleRow("Method", steps.isEmpty ? "This recipe has no steps saved" : "\(steps.count) step\(steps.count == 1 ? "" : "s")", planBinding(\.method))
                    if plan.method && !steps.isEmpty {
                        Button { withAnimation(.snappy) { panel = .recipeSteps } } label: {
                            Image(systemName: "list.number").font(.system(size: 15, weight: .bold)).frame(width: 46, height: 54)
                                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel("The steps")
                    }
                }
                toggleRow("Macros at the end", "A portion's numbers on the last clip", planBinding(\.macros))
                if plan.macros {
                    segments([("count", "Counts up"), ("still", "Shown still")], plan.countUp ? "count" : "still") { v in plan.countUp = v == "count"; remakeRecipe() }
                    HStack(spacing: 6) {
                        ForEach(["p", "c", "f"], id: \.self) { k in
                            let name = ["p": "Protein", "c": "Carbs", "f": "Fat"][k] ?? k
                            chip(name, on: plan.show.contains(k)) {
                                if plan.show.contains(k) { plan.show.remove(k) } else { plan.show.insert(k) }
                                remakeRecipe()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                Text("Look").font(.caption.weight(.semibold)).foregroundStyle(Self.quiet).padding(.top, 4)
                HStack(spacing: 6) {
                    ForEach(EditOverlays.RecipePlan.looks, id: \.self) { l in chip(l, on: plan.look == l) { plan.look = l; remakeRecipe() } }
                    Spacer(minLength: 0)
                }
                wide("Take the recipe off", "trash", warn: true) {
                    recipe = nil; remakeRecipe()
                    withAnimation(.snappy) { panel = nil }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxHeight: 330)
    }

    /// The method a step at a time (design/editor-recipe-mockup.html, 2): a clip each or spread evenly, each step's
    /// clip, and its words to shorten.
    private var recipeSteps: some View {
        let meal = recipe ?? [:]
        let steps = EditOverlays.steps(of: meal)
        let room = max(1, plan.macros && clips.count > 1 ? clips.count - 1 : clips.count)
        let even = plan.spread || steps.count > room
        return VStack(alignment: .leading, spacing: 8) {
            segments([("clip", "A clip each"), ("even", "Spread evenly")], even ? "even" : "clip") { v in plan.spread = v == "even"; remakeRecipe() }
            if !plan.spread && steps.count > room {
                Text("More steps than clips, so they're spread evenly. Add clips to give each its own.").font(.caption2).foregroundStyle(Theme.warn)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { i in
                        let on = stepPicked == i
                        HStack(alignment: .center, spacing: 10) {
                            Text("\(i + 1)").font(.caption.weight(.black)).foregroundStyle(.black).frame(width: 22, height: 22).background(.white, in: Circle())
                            if on {
                                TextField("Step", text: Binding(get: { plan.words[i] ?? steps[i] }, set: { plan.words[i] = $0; remakeRecipe() }), axis: .vertical)
                                    .font(.subheadline).lineLimit(1...3)
                            } else {
                                Text(plan.words[i] ?? steps[i]).font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !even {
                                Menu {
                                    ForEach(clips.indices, id: \.self) { k in
                                        Button("Clip \(k + 1)") { plan.clipOf[i] = k; remakeRecipe(); seek(startOf(k) + 0.01) }
                                    }
                                } label: {
                                    Text("Clip \(min(plan.clipOf[i] ?? i, clips.count - 1) + 1) ▾").font(.caption2.weight(.heavy)).foregroundStyle(Color(white: 0.85))
                                        .padding(.horizontal, 7).frame(height: 24).background(.black, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                            }
                        }
                        .padding(.horizontal, 11).padding(.vertical, 9)
                        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Color.white : .clear, lineWidth: 1.5))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture {
                            stepPicked = i
                            if let t = texts.first(where: { $0.part == "recipe" && $0.kind == "step" && $0.detail.hasPrefix("\(i + 1)/") }) { player.pause(); playing = false; seek(t.from + 0.01) }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
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
        .accessibilityLabel(set ? "Transition between clips \(i + 1) and \(i + 2): \(clips[i].transition?.name ?? "")" : "Add a transition between clips \(i + 1) and \(i + 2)")
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
                        chip(k, on: tr?.name == k) { setJoin(i, ClipTransition(kind: k, length: min(tr?.length ?? 0.5, most), direction: tr?.direction)) }
                    }
                }
            }
            // which way it goes, for the ones that move (design/transitions-mockup.html)
            if let tr, ClipTransition.moving.contains(tr.name) {
                HStack(spacing: 6) {
                    ForEach(ClipTransition.directions, id: \.self) { d in
                        let icon = ["left": "arrow.left", "right": "arrow.right", "up": "arrow.up", "down": "arrow.down"][d] ?? "arrow.left"
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            var n = tr; n.direction = d; setJoin(i, n)
                        } label: {
                            let on = (tr.direction ?? "left") == d
                            Image(systemName: icon).font(.system(size: 13, weight: .bold)).frame(width: 44, height: 34)
                                .foregroundStyle(on ? Color.black : Color.white)
                                .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.55)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Goes \(d)")
                    }
                    Spacer()
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
    @State private var from: Double?
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
                        if !holding { holding = true; began(); from = value }
                        // moved as far as the finger has, from where it was (21 Nov: it jumped to where the finger
                        // landed, so a touch near it snapped the volume)
                        value = Double(min(1, max(0, (from ?? value) + Double(v.translation.width / w))))
                    }
                    .onEnded { _ in holding = false; from = nil })
                .onChange(of: touching) { _, now in if !now { holding = false; from = nil } }
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
