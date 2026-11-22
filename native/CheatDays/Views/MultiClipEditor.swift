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
    /// Its captions of what's trimmed off its clips, as the draft had them.
    var startCut: [EditText]? = nil
    var close: () -> Void
    var done: (URL) -> Void
    /// The draft it's auto-saved as (a new edit gets one of its own once it's saved the first time).
    var autosaved: (String) -> Void = { _ in }
    /// Whoever opened it keeps the draft once it's made into a video (Make an edit lets it go when it's shared);
    /// otherwise the auto-saved draft is let go then.
    var keepsDraft = false
    /// A meal, recipe or workout picked in the editor (recipe and workout mode, the calorie count): for the post to carry.
    var attach: (JSON?) -> Void = { _ in }

    @State private var cutWords: [EditText] = []   // the video's own captions of what's trimmed off (ClipCuts)
    @State private var importFailure: ImportFailure?
    @State private var trouble: EditorTrouble?
    @State private var saveWarned = false          // said that it isn't being saved, till it is again
    @State private var selected: UUID?
    @State private var soundOf: UUID?          // one clip's sound over the whole video
    // The editor's own player (PreviewEngine, 21 Nov): plays the edit straight from the clips, drawn by EditPreviewView.
    @State private var player = PreviewEngine()
    @State private var clock = EditPlayhead()
    /// Where the preview is, in the joined video's seconds. (Read in a body only inside Live: the editor isn't made
    /// again each time it moves.)
    private var now: Double {
        get { clock.time }
        nonmutating set { if clock.time != newValue { clock.time = newValue } }
    }
    @State private var panel: Panel?
    @State private var joining = false
    /// What Undo goes back to: the clips, and the sounds over them (21 Nov: a sound separated from its clip has to
    /// come back with it).
    /// All of the edit, as Undo keeps it.
    private struct Snap: Equatable {
        var clips: [Clip]
        var sounds: [EditSound]
        var texts: [EditText]
        var pips: [EditPip]
        var look: EditLook
        var soundOf: UUID?
        var cut: [EditText]
        var plan: EditOverlays.RecipePlan
        var recipe: SameJSON
        var attached: SameJSON
    }
    @State private var edits = EditHistory<Snap>()   // for Undo and Redo
    @State private var restoring: [Clip]?            // the clips an Undo or Redo is putting back
    @State private var restores = 0
    @State private var autoID: String?           // the draft it's kept in as it goes (Stage A1)
    @State private var opened: [Clip]?           // as it was when opened from a draft: Discard goes back to it
    @State private var waves = Waveforms()
    @State private var pauseHeld: Double?        // the pause a handle's held on, in its file's seconds
    @State private var watch: Any?
    @State private var adding = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var leaving = false   // the cross tapped: asking before the edit is thrown away
    @State private var wasPlaying: Bool?   // while the scrub bar is dragged: whether it was playing before
    @State private var soundTool: SoundTool = .volume   // which sound tool is open
    private enum SoundTool { case volume, fade, beats }
    @State private var shapeTab = "Shape"
    @State private var recipeTab = "Show"
    @State private var captionsTab = "On screen"
    @State private var changingSticker = false     // a sticker's emoji being picked again, in its panel
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
    @State private var fingerHeld = false          // something on the video or a caption's slider is being dragged
    @State private var captionScreen = CaptionScreen.main
    @State private var captionPart = CaptionPart.lit
    /// The captions just moved or sized together, to have just the one instead.
    private struct MovedAll { var id = UUID(); var caption: UUID; var sized: Bool; var was: [UUID: Placing] }
    private struct Placing { var x: Double; var y: Double; var size: Double; var byHand: Bool? }
    @State private var movedAll: MovedAll?
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
    @State private var stripZoom: CGFloat = 1             // the strip pinched wider or narrower (Stage D)
    @State private var stripZoomFrom: CGFloat?
    @State private var songPicked: Song?                  // the song picked in the chooser, with its part
    @State private var press = VoicePress()               // the record button's
    @State private var countdown = false                  // a tap counts down 3 seconds first
    @State private var count: Int?                        // the countdown showing
    @State private var pressTask: Task<Void, Never>?      // a hold or a countdown being timed
    @State private var recordBegan = Date()
    @State private var templating = false                 // the templates open (design/templates-mockup.html)
    @State private var beatEvery = 2
    @State private var tip: Int?                          // the first-time tip showing
    @State private var full = false                       // the preview full screen (design/bigger-preview-mockup.html)
    @State private var playing = false
    @State private var scrubFrom: Double?                 // where the timeline was when a finger began sliding it
    @State private var shownShape: String?                // what the preview playing was made of (its tracks)
    @State private var motion = TimelineMotion()
    @GestureState private var onTimeline = false          // a finger's on the timeline
    // the bars, worked out once for each change to what's in them (22 Nov: ten times over for each step of a drag)
    private struct ItemsKey: Equatable { var texts: [EditText]; var sounds: [EditSound]; var pips: [EditPip] }
    private struct RowsKey: Equatable { var items: ItemsKey; var held: [UUID: Int] }
    @State private var keptItems = Remembered<ItemsKey, [BarItem]>()
    @State private var keptRows = Remembered<RowsKey, [[BarItem]]>()
    @State private var dropped = 0                        // a bar let go: the preview made again then
    private struct TrimDrag { var side: Int; var dx: CGFloat }
    @State private var trimDrag: TrimDrag?
    // where the handle is drawn while it's held: back to nothing however the drag ends, cut short too (21 Nov: a drag
    // the timeline took over left the handle stranded, apart from its clip)
    @GestureState private var trimLive: TrimDrag?
    @State private var scrubSkip = false
    @State private var pressed: UUID?        // the bar a finger's on (design/capcut-timeline-mockup.html: hold to lift)
    @State private var pressMoved = false    // it moved before the hold was up: a scroll, not a hold
    @State private var pressCount = 0        // which press it is
    @State private var handleDown = false    // a finger's on a picked bar's handle: the timeline keeps still
    @GestureState private var onHandle = false   // (the same, back to false however that drag ends, cut short too)
    @State private var lifted: UUID?         // the bar held long enough to move
    @State private var liftDY: CGFloat = 0    // how far up or down it's been dragged
    @State private var dropRow: Int?          // the row it'd go on if let go now
    @State private var pulledPast = false     // dragged down past where there's a row for it
    @State private var heldRows: [UUID: Int] = [:]   // each bar's row as it was when one was caught, till it's let go
    @State private var barSnap: Double?
    @State private var stripHeld: CGFloat?                // the keyframe a strip's scrub is held on (for the tap, once)                   // what a bar being dragged is held on (for the tap, once)                  // this drag is a bar's or a trim handle's, not the timeline's                // an end of the picked clip being dragged on the timeline
    private struct BarGrab { var id: UUID; var mode: Int; var from: Double; var to: Double; var words: [EditText.Word]?; var start = 0.0 }   // mode: 0 move, 1 start, 2 end
    /// One bar on the timeline: a text, sticker or caption, or a voiceover or sound effect.
    /// kind: 0 over the picture (text, stickers, captions), 1 a sound, 2 a clip or photo over it.
    private struct BarItem: Identifiable { let id: UUID; let from: Double; let to: Double; let label: String; let colour: Color; let kind: Int; var lane: Int? = nil; var off: Bool = false }
    private enum Panel { case trim, sound, speed, join, look, shape, text, stickers, voice, effects, soundItem, pip, motion, beats, songs, captions, captionList, recipe, recipeSteps }
    private var perSecond: CGFloat { 30 * stripZoom }   // timeline points a second, pinched wider or narrower

    private var total: Double { ClipJoin.total(clips) }
    private var index: Int? { clips.firstIndex { $0.id == selected } }
    private func startOf(_ i: Int) -> Double {
        let starts: [Double] = ClipJoin.starts(clips)
        // (asked by something put off, or on its way out, after Undo has taken that clip)
        return starts.indices.contains(i) ? starts[i] : (starts.last ?? 0)
    }

    var body: some View {
        ZStack {
            behind
            VStack(spacing: 0) {
                if !full { top }
                // drawn by the app on every frame, the last real frame always up: never blank while the edit's made
                // again (21 Nov: Apple's player view flashed black each time)
                EditPreviewView(engine: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { togglePlay() }
                    .overlay { overVideo.allowsHitTesting(!full) }
                    .overlay(alignment: .bottom) { if let tip, !full { tipCard(tip) } }
                    .overlay(alignment: .topTrailing) {
                        if full {
                            round("arrow.down.right.and.arrow.up.left", "Leave full screen") { withAnimation(.snappy) { full = false } }
                                .padding(14)
                        }
                    }
                    .overlay(alignment: .bottom) { if full { Live { fullBar } } }
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
            Button("Save draft") { saveAndClose() }
            Button("Discard", role: .destructive) { discard() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text(opened == nil ? "Keep it as a draft to finish later, or let it go." : "Save the changes to this draft, or leave it as it was.") }
        .onAppear {
            if soundOf == nil, let s = startSoundOf { soundOf = s }
            if let l = startLook, opened == nil { look = l }
            if let t = startTexts, opened == nil, texts.isEmpty { texts = t }
            if let v = startSounds, opened == nil, sounds.isEmpty { sounds = v }
            if let p = startPips, opened == nil, pips.isEmpty { pips = p }
            if let c = startCut, opened == nil, cutWords.isEmpty { cutWords = c }
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
        .onAppear { if !UserDefaults.standard.bool(forKey: "editor.tips.1") { tip = 0 } }
        // (a trim handle's drag cut short, by another clip picked or a panel opened, leaves nothing behind)
        .onChange(of: selected) { _, _ in trimDrag = nil }
        .onChange(of: panel) { (_: Panel?, _: Panel?) in panelChanged() }
        // a handle's drag cut short (no end to it): nothing left held, the picture back where the line is
        .onChange(of: pipPicks) { _, now in
            guard !now.isEmpty else { return }
            pipPicks = []
            loadOverlay(now)
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
            templatesScreen
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
            wentAway()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            editorBack()
        }
        .onDisappear {
            holding = false
            pressTask?.cancel()
            if recording { _ = recorder.stop() }
            motion.end()
            player.shutdown()
            // the sound given back (19 Nov: left on, the feed's videos went on stopping their Spotify after an edit)
            Sound.off()
        }
        // more from the library, onto the end, in the order picked
        .photosPicker(isPresented: $adding, selection: $picks, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: replacePicks) { _, now in
            guard !now.isEmpty else { return }
            replacePicks = []
            loadReplacement(now)
        }
        .onChange(of: picks) { _, now in
            guard !now.isEmpty else { return }
            picks = []
            loadMore(now) }
    }

    /// The black under it all, with the editor's alerts on it (kept out of the body's chain).
    private var behind: some View {
        Color.black.ignoresSafeArea()
            .importFailed($importFailure)
            .modifier(EditorTroubleAlert(trouble: $trouble, retry: { finish() }))
            .modifier(EditWatch<Snap>(edit: snap, began: { startHistory() }, changed: { editChanged() },
                                      busy: { midEdit() }, settled: { recordEdit() }))
    }

    private func editorBack() {
        guard !recording else { return }
        Sound.on(.moviePlayback)
        player.wake()
    }

    private func wentAway() {
        endVoice()
        SongPlayer.shared.stop()
        stopGlide()
        if player.rate != 0 { player.pause(); playing = false }
        // (saved as it's left: the last second's changes hadn't been)
        Task { @MainActor in await saveNow(tidy: false) }
    }

    /// The edit saved as it is this moment; whether it was.
    @MainActor @discardableResult
    private func saveNow(tidy: Bool) async -> Bool {
        guard !clips.isEmpty else { return true }
        let id: String = autoID ?? draftID ?? UUID().uuidString.lowercased()
        if autoID == nil { autoID = id; autosaved(id) }
        let kept = clips, sound = soundOf, shape = look, over = texts, with = Self.data(attached), laid = sounds, on = pips, cut = cutWords
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            EditDrafts.queue.async {
                let ok: Bool = EditDrafts.save(id: id, clips: kept, soundOf: sound, look: shape, texts: over, attached: with,
                                               sounds: laid, pips: on, cut: cut, tidy: tidy)
                done.resume(returning: ok)
            }
        }
    }

    private func saveAndClose() {
        player.pause(); playing = false
        Task { @MainActor in
            if await saveNow(tidy: true) { close() } else { trouble = .draft }
        }
    }

    private func discard() {
        player.pause()
        let id: String? = autoID ?? draftID
        let was = opened, sound = startSoundOf, shape = startLook, over = startTexts, with = Self.data(startAttached)
        let laid = startSounds, on = startPips, cut = startCut
        EditDrafts.queue.async {
            guard let id else { return }
            if let was { EditDrafts.save(id: id, clips: was, soundOf: sound, look: shape, texts: over, attached: with, sounds: laid, pips: on, cut: cut) }
            else { EditDrafts.delete(id) }
        }
        close()
    }

    private func loadMore(_ items: [PhotosPickerItem]) {
        load(items, again: { loadMore(items) }) { (got: [Clip]) in change { (all: [Clip]) -> [Clip] in all + got } }
    }

    private func loadOverlay(_ items: [PhotosPickerItem]) {
        load(items, again: { loadOverlay(items) }) { (got: [Clip]) in
            if let c = got.first { Task { await addPip(c) } }
        }
    }

    private func loadReplacement(_ items: [PhotosPickerItem]) {
        load(items, again: { loadReplacement(items) }) { (got: [Clip]) in
            if let c = got.first { replaceSelected(with: c) }
        }
    }

    /// What was picked, loaded: in it goes, or what wouldn't is said with Try again.
    private func load(_ items: [PhotosPickerItem], again: @escaping () -> Void, then use: @escaping ([Clip]) -> Void) {
        Task { @MainActor in
            let loaded: (clips: [Clip], failed: [Int]) = await Self.load(items)
            let got: [Clip] = loaded.clips
            if loaded.failed.isEmpty { use(got); return }
            try? await Task.sleep(for: .milliseconds(450))
            importFailure = ImportFailure(total: items.count, failed: loaded.failed, retry: again,
                                          carryOn: got.isEmpty ? nil : { use(got) })
        }
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
            bare("xmark", "Close") { endVoice(); if clips.isEmpty { close() } else { leaving = true } }
            bare("arrow.uturn.backward", "Undo", on: edits.canUndo) { undo() }
            bare("arrow.uturn.forward", "Redo", on: edits.canRedo) { redo() }
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
        // (recording, play and pause are its stop)
        if recording || count != nil {
            endVoice()
            return
        }
        if motion.gliding {
            motion.end()
            finishScrub(resume: false)
        }
        if panel == .songs {
            SongPlayer.shared.stop()
            Sound.on(.moviePlayback)
        }
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


    private func closePanel() {
        captionScreen = .main
        changingSticker = false
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
        case .text: return textTitle
        case .stickers: return "Stickers"
        case .voice: return "Voiceover"
        case .effects: return "Sound effects"
        case .soundItem: return sounds.first(where: { $0.id == selectedSound })?.name ?? "Sound"
        case .pip: return "Overlay"
        case .motion: return "Motion"
        case .beats: return "Music"
        case .songs: return "Add music"
        case .captions: return "Captions"
        case .captionList: return "Edit captions"
        case .recipe: return "Recipe"
        case .recipeSteps: return "Method"
        case nil: return ""
        }
    }

    /// A picked thing's name, by what it is.
    private var textTitle: String {
        guard let item = texts.first(where: { (t: EditText) -> Bool in t.id == selectedText }) else { return "Text" }
        switch item.kind {
        case "caption": return "Caption"
        case "sticker", "card": return "Sticker"
        case "label": return "Label"
        case "step": return "Recipe step"
        case "ingredients": return "Ingredients"
        case "macros": return "Macros"
        case "workout": return "Exercise"
        case "calories": return "Calories"
        default: return "Text"
        }
    }

    /// What's on the left of a panel's bottom bar.
    private func panelLeft(_ open: Panel) -> SheetAction? {
        switch open {
        case .look:
            return SheetAction(icon: "square.stack.3d.down.right", name: "Use for all", run: { lookForAll() })
        case .join:
            guard clips.indices.contains(joinAt), clips[joinAt].transition != nil else { return nil }
            return SheetAction(icon: "square.stack.3d.down.right", name: "Apply to all", run: { joinForAll() })
        case .captions:
            return SheetAction(icon: "list.bullet", name: "Edit all", run: { editAllCaptions() })
        case .captionList:
            return SheetAction(icon: "chevron.left", name: "Captions", run: { backToCaptions() })
        case .recipeSteps:
            return SheetAction(icon: "chevron.left", name: "Recipe", run: { backToRecipe() })
        case .songs:
            return SheetAction(icon: "chevron.left", name: "Back", run: { leaveSongs() })
        default:
            return nil
        }
    }

    private func lookForAll() {
        guard let i = index else { return }
        let l: String = clips[i].look
        change { (all: [Clip]) -> [Clip] in
            var out: [Clip] = all
            for k in out.indices { out[k].look = l }
            return out
        }
        flash("Every clip has this look now.")
    }

    private func joinForAll() {
        guard clips.indices.contains(joinAt), let tr = clips[joinAt].transition else { return }
        change { (all: [Clip]) -> [Clip] in
            var out: [Clip] = all
            for k in out.indices.dropLast() { out[k].transition = tr }
            return out
        }
        flash("Every join is like this one now.")
    }

    private func editAllCaptions() {
        listPicked = nil
        withAnimation(.snappy) { panel = .captionList }
    }

    private func backToCaptions() {
        selectedText = nil
        withAnimation(.snappy) { panel = .captions }
    }

    private func backToRecipe() {
        withAnimation(.snappy) { panel = .recipe }
    }


    private func round(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var bottom: some View {
        VStack(spacing: 0) {
            if let item = editedWords {
                wordsSheet(item)
            } else if let open = panel {
                panelSheet(open)
            } else {
                timelineSheet
            }
        }
    }

    /// A caption's own sheet (design/caption-panel-pro-mockup.html): flat, one height, no rows of bars.
    private func captionSheet(_ item: EditText) -> some View {
        let id: UUID = item.id
        return CaptionPanel(item: item, screen: $captionScreen, part: $captionPart,
                            change: { (edit: (inout EditText) -> Void) in changeText(id, edit) },
                            step: { captionStep() },
                            held: { (on: Bool) in sliderHeld(on) },
                            words: { (text: String) in captionWords(id, text) },
                            editAll: { editEveryCaption(id) },
                            delete: { deleteFromPanel(id) },
                            applyAll: { applyToAll(id) },
                            done: { closePanel() },
                            head: { captionHead })
            .background { Self.captionBack.ignoresSafeArea(edges: .bottom) }
            .onChange(of: captionScreen) { (_: CaptionScreen, to: CaptionScreen) in screenChanged(to) }
    }

    private func screenChanged(_ to: CaptionScreen) {
        guard to != .main else { return }
        player.pause()
        playing = false
    }

    /// A step of Undo: not inside the wheel or the eyedropper, which are one from start to finish.
    private func captionStep() {
        if captionScreen == .main { remember() }
    }

    private func editHeld(_ on: Bool) {
        if on { captionStep() }
        fingerHeld = on
    }

    private static let captionBack = Color(red: 0.086, green: 0.086, blue: 0.094)

    private var captionHead: some View {
        VStack(spacing: 0) {
            Live { captionTransport }
            Live { scrubStrip(slim: true) }.padding(.horizontal, 16)
        }
    }

    private var captionTransport: some View {
        ZStack {
            (Text(Self.code(now)).foregroundColor(.white) + Text(" / " + Self.code(total)).foregroundColor(Self.quiet))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            HStack(spacing: 4) {
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 16)).foregroundStyle(Color.white)
                        .frame(width: 40, height: 38, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(playing ? "Pause" : "Play")
                Spacer(minLength: 0)
                frameStep(-1)
                frameStep(1)
                bare("arrow.up.left.and.arrow.down.right", "Full screen", size: 14) { withAnimation(.snappy) { full = true } }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func sliderHeld(_ on: Bool) {
        if on {
            player.pause()
            playing = false
        }
        editHeld(on)
    }

    private func captionWords(_ id: UUID, _ text: String) {
        guard let k = texts.firstIndex(where: { (t: EditText) -> Bool in t.id == id }), texts[k].text != text else { return }
        setText(k, text)
    }

    private func editEveryCaption(_ id: UUID) {
        listPicked = id
        captionScreen = .main
        withAnimation(.snappy) { panel = .captionList }
    }

    private func deleteFromPanel(_ id: UUID) {
        closePanel()
        removeText(id)
    }

    private func applyToAll(_ id: UUID) {
        guard let like = texts.first(where: { (t: EditText) -> Bool in t.id == id }) else { return }
        remember()
        changeEveryCaption { (t: inout EditText) in
            t.takeLook(from: like)
            t.byHand = nil   // (the two layers at one height: one's lifted over the other again)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        flash("Every caption looks like this one now.")
    }

    /// A caption or text with its panel open: each has a sheet of its own.
    private var editedWords: EditText? {
        guard let id = editingCaption ?? editingText else { return nil }
        return texts.first { (t: EditText) -> Bool in t.id == id }
    }

    @ViewBuilder private func wordsSheet(_ item: EditText) -> some View {
        if item.kind == "caption" { captionSheet(item) } else { textSheet(item) }
    }

    private func textSheet(_ item: EditText) -> some View {
        let id: UUID = item.id
        return TextPanel(item: item, screen: $captionScreen,
                         change: { (edit: (inout EditText) -> Void) in changeText(id, edit) },
                         step: { captionStep() },
                         held: { (on: Bool) in sliderHeld(on) },
                         edit: { startTyping(id) },
                         delete: { deleteFromPanel(id) },
                         done: { closePanel() },
                         head: { captionHead })
            .id(id)
            .onChange(of: captionScreen) { (_: CaptionScreen, to: CaptionScreen) in screenChanged(to) }
    }

    /// Every other panel (design/editor-panels-mockup.html): the one sheet, no rows of bars on any.
    private func panelSheet(_ open: Panel) -> some View {
        ProSheet(title: panelTitle, left: panelLeft(open), done: { panelDone(open) },
                 head: { sheetHead(open) },
                 main: { panelMain(open) })
    }

    @ViewBuilder private func sheetHead(_ open: Panel) -> some View {
        // (choosing a song has the room; recording, the line stays with the voice)
        if open != .songs {
            let held: Bool = recording || count != nil || press.phase != .idle
            captionHead
                .disabled(held)
                .opacity(held ? 0.5 : 1)
        }
    }

    private func panelDone(_ open: Panel) {
        if open == .songs, let song = songPicked {
            takeSong(song)
        } else {
            closePanel()
        }
    }

    private func openSongs() {
        player.pause(); playing = false
        songPicked = nil
        withAnimation(.snappy) { panel = .songs }
    }

    private func leaveSongs() {
        songPicked = nil
        let music: Bool = sounds.contains { (s: EditSound) -> Bool in s.kind == "song" }
        if music {
            withAnimation(.snappy) { panel = .beats }
        } else {
            closePanel()
        }
    }

    private func takeSong(_ song: Song) {
        SongPlayer.shared.stop()
        Sound.on(.moviePlayback)
        Task { @MainActor in await addSong(song) }
    }

    /// The chooser's gone: the sound the editor's again, unless the editor's gone with it (the feed stopped their
    /// Spotify).
    private func songsLeft() {
        guard player.onTime != nil else { return }
        Sound.on(.moviePlayback)
    }

    /// Something's to be heard by itself: the edit stops for it.
    private func hearAlone() {
        if player.rate != 0 {
            player.pause()
            now = player.currentTime().seconds   // (the last it was told is up to a twentieth behind)
        }
        playing = false
    }

    @ViewBuilder private func panelMain(_ open: Panel) -> some View {
        switch open {
        case .trim, .sound, .speed, .join, .look, .motion, .shape: clipMain(open)
        case .text, .stickers, .pip, .recipe, .recipeSteps: overMain(open)
        default: soundMain(open)
        }
    }

    @ViewBuilder private func clipMain(_ open: Panel) -> some View {
        switch open {
        case .trim: if let i = index { trimPanel(i) }
        case .sound: if let i = index { liveSound(i) }
        case .speed: if let i = index { speedPanel(i) }
        case .look: if let i = index { lookPanel(i) }
        case .motion: if let i = index { liveMotion(i) }
        case .join: if joinAt + 1 < clips.count { joinPanel(joinAt) }
        case .shape: shapePanel
        default: EmptyView()
        }
    }

    @ViewBuilder private func overMain(_ open: Panel) -> some View {
        switch open {
        case .text: if let k = texts.firstIndex(where: { (t: EditText) -> Bool in t.id == selectedText }) { textPanel(k) }
        case .pip: if let k = pips.firstIndex(where: { (p: EditPip) -> Bool in p.id == selectedPip }) { livePip(k) }
        case .stickers: stickerPanel
        case .recipe: recipePanel
        case .recipeSteps: recipeSteps
        default: EmptyView()
        }
    }

    @ViewBuilder private func soundMain(_ open: Panel) -> some View {
        switch open {
        case .voice: voicePanel
        case .effects: liveEffects
        case .soundItem: if let k = sounds.firstIndex(where: { (s: EditSound) -> Bool in s.id == selectedSound }) { liveSoundItem(k) }
        case .beats: liveMusic
        case .songs: SongChooser(picked: $songPicked, hearing: { hearAlone() }, left: { songsLeft() })
        case .captions: captionsPanel
        case .captionList: liveList
        default: EmptyView()
        }
    }

    /// No panel open: the timeline and the tools under it.
    private var timelineSheet: some View {
        VStack(spacing: 10) {
            // where it is and how long, said as the trim strip says it ("0:11 · 0:24 of 0:30")
            Live { timeRow }
            // (21 Nov: longer is allowed; it's only a post that's kept to the limit, and it asks which part when posted)
            if total > limit + 0.05 { Text("Longer than \(Int(limit)) seconds: you can save it all to Photos, but a post keeps \(Int(limit)) seconds.").font(.caption).foregroundStyle(Theme.warn).multilineTextAlignment(.center) }
            // one timeline in place of the scrub bar, the bars and the strip (21 Nov: stacked, they left the video
            // a third of the screen)
            timeline
            underTimeline
        }
        // (no more under the tools than the home bar's own room: 21 Nov, a gap at the bottom)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 0)
        // on a sheet of its own, a shade off the video's black (design/pro-ui)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 18, style: .continuous)
                .fill(Self.sheet).ignoresSafeArea(edges: .bottom)
        }
    }

    // The panels that show where the line is, each made again by itself as it moves. (Guarded: one can be asked again
    // after what it was for has gone.)
    private func liveSound(_ i: Int) -> some View {
        Live { if clips.indices.contains(i) { soundPanel(i) } }
    }
    private func liveMotion(_ i: Int) -> some View {
        Live { if clips.indices.contains(i) { motionPanel(i) } }
    }
    private func liveSoundItem(_ k: Int) -> some View {
        Live { if sounds.indices.contains(k) { soundItemPanel(k) } }
    }
    private func livePip(_ k: Int) -> some View {
        Live { if pips.indices.contains(k) { pipPanel(k) } }
    }
    private var liveList: some View { Live { captionList } }
    private var liveEffects: some View { Live { effectsPanel } }
    private var liveMusic: some View { Live { beatsPanel } }

    // MARK: the timeline

    /// Every clip's sound off, or back on, at once (CapCut's "Mute clip audio"): a tile against the timeline's start,
    /// going along with it (22 Nov, design/timeline-left-gap-mockup.html, B: held at the screen's edge, it and the
    /// rows' tiles had a gap between them and what they head at 0:00).
    private var allSound: some View {
        let any: Bool = clips.contains { (c: Clip) -> Bool in c.soundOn && !c.still }
        return VStack(spacing: 2) {
            Image(systemName: any ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size: 13, weight: .medium))
            Text("Clip\nsound").font(.system(size: 7.5, weight: .medium)).foregroundStyle(Self.quiet).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white).frame(width: Self.headWidth, height: Self.clipRow - 2)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        // a tap by the screen's measure, not a Button: the tile goes along under a finger sliding the timeline, so a
        // Button was still under it when it lifted, and would switch the sound
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onEnded { tappedAllSound($0) })
        .accessibilityElement()
        .accessibilityLabel(any ? "Turn every clip's sound off" : "Turn every clip's sound on")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleAllSound() }
    }

    private func tappedAllSound(_ v: DragGesture.Value) {
        if !motion.justStopped, hypot(v.translation.width, v.translation.height) < 6 { toggleAllSound() }
    }

    private func toggleAllSound() {
        let any: Bool = clips.contains { (c: Clip) -> Bool in c.soundOn && !c.still }
        remember()
        withAnimation(.snappy(duration: 0.2)) { for i in clips.indices where !clips[i].still { clips[i].soundOn = !any } }
    }

    // The tiles against the start, one column: all the one width (22 Nov: "kind of bad since they're different
    // sizes"), only as tall as what each heads, and the room between them and 0:00.
    private static let headWidth: CGFloat = 40, headGap: CGFloat = 8

    /// Where the timeline's line is: the player's own time while it plays, else where it was put.
    private var lineTime: Double {
        guard playing, scrubFrom == nil, barGrab == nil else { return now }
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : now
    }

    /// How many rows of bars the timeline shows under its clips.
    // (only the rows there are: the empty rail to drop onto, kept under them, read as an "extra layer for no reason",
    // 22 Nov. While a bar's lifted it lies over the tools under the timeline, so the timeline's height stays put)
    private var laneCount: Int { min(TimelineRows.most, barRows.count) }
    // the bars as tall as CapCut's, their words readable (21 Nov, design/capcut-timeline-mockup.html: 15 pt bars read as slivers)
    // A clip's row is what's in it: 2 over it, its picture, 2, and its sound's wave (22 Nov, "things not lining up":
    // made 49 in 1.4.25 with the clip left 56 tall, its wave ran into the first row of bars and under it).
    private static let thumbHeight: CGFloat = 44, waveHeight: CGFloat = 18
    private static let rulerHeight: CGFloat = 18, clipRow: CGFloat = 2 + thumbHeight + 2 + waveHeight, laneHeight: CGFloat = 34

    /// The clips and everything over them as one timeline under a line fixed in the middle, as CapCut and Edits lay
    /// it out (21 Nov; design/bigger-preview-mockup.html, then design/pro-ui): a ruler over it, slide it under the line
    /// to look through the video, tap a clip for its tools and drag its ends to trim it, pinch it wider or narrower. A
    /// second is the same width on every row, so each bar sits under the clips it plays over.
    private var timeline: some View {
        GeometryReader { g in
            let mid = g.size.width / 2, pps = perSecond, span = max(total, 0.01)
            let rows = timelineRows(width: CGFloat(span) * pps, span: span, pps: pps)
            let face = ZStack(alignment: .topLeading) {
                // While it plays, slid on every frame the screen draws, from the player's own clock (21 Nov: moved
                // only on the 20-a-second time updates, it stepped along)
                TimelineView(.animation(minimumInterval: nil, paused: !playing || scrubFrom != nil)) { _ in
                    Live { rows.offset(x: mid - CGFloat(min(lineTime, span)) * pps) }
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
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .clipShape(TimelineEdge(below: spareBelow))
            .contentShape(Rectangle())
            slidable(face, mid: mid, pps: pps)
        }
        .frame(height: Self.rulerHeight + 4 + Self.clipRow + (laneCount > 0 ? 3 + CGFloat(laneCount) * (Self.laneHeight + 3) : 0))
        .onDisappear { timelineGone() }
        // edge to edge, as CapCut's
        .padding(.horizontal, -14)
        .zIndex(spareBelow > 0 ? 1 : 0)
    }

    /// The timeline's slide, its glide stopped by a touch, and its pinch.
    private func slidable<Face: View>(_ face: Face, mid: CGFloat, pps: CGFloat) -> some View {
        face
            // alongside the clips' own touches, not after them: as a gesture of its own it waited for a clip's hold
            // (to move it) to give up first, and the timeline stood still a moment before it moved (21 Nov recording)
            .simultaneousGesture(DragGesture(minimumDistance: Self.deadZone)
                .onChanged { (v: DragGesture.Value) in scrubTimeline(by: v.translation.width, from: v.startLocation, mid: mid, pps: pps) }
                .onEnded { (v: DragGesture.Value) in endScrub(velocity: v.velocity.width, pps: pps) })
            // a touch stops a glide at once, before it's gone far enough to be a slide
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .updating($onTimeline) { _, down, _ in down = true }
                .onChanged { _ in touchedTimeline() }
                .onEnded { _ in timelineReleased(false) })
            .onChange(of: onTimeline) { (_: Bool, down: Bool) in timelineReleased(down) }
            // a handle's drag cut short (no end to it): nothing left held, the picture back where the line is
            .onChange(of: trimLive == nil) { (_: Bool, gone: Bool) in trimReleased(gone) }
            .simultaneousGesture(MagnificationGesture()
                .onChanged { (m: CGFloat) in pinched(m) }
                .onEnded { _ in stripZoomFrom = nil })
    }

    private func pinched(_ m: CGFloat) {
        if stripZoomFrom == nil {
            stripZoomFrom = stripZoom
            beganPinch()
        }
        let wanted: CGFloat = (stripZoomFrom ?? 1) * m
        stripZoom = min(4, max(0.4, wanted))
    }

    /// How far under the timeline the rail to drop a lifted bar on shows.
    private var spareBelow: CGFloat { canAddRow ? Self.laneHeight + 8 : 0 }

    /// Whether the lifted bar can have a new row under the last.
    private var canAddRow: Bool {
        guard let id = lifted else { return false }
        return TimelineRows.canAddRow(for: id, rows: barRows.map { (row: [BarItem]) -> [UUID] in row.map(\.id) })
    }

    /// What's under the timeline stands aside for that rail, keeping its room, so the timeline doesn't move under the
    /// finger (22 Nov: "new line covers the UI below"; grown for the rail, the timeline would've slid up from under it).
    private var underOpacity: Double { canAddRow ? 0 : 1 }

    /// The tools under the timeline.
    private var underTimeline: some View {
        Group {
            if selected != nil { actions } else if let b = pickedBar { barTools(b) } else { addTools }
        }
        .opacity(underOpacity)
        .animation(.easeOut(duration: 0.15), value: underOpacity)
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
                             // (0:00 just right of the line's knob, which sat on it)
                             at: CGPoint(x: t < 0.001 ? x + 7 : x, y: size.height - 7), anchor: t < 0.001 ? .bottomLeading : .bottom)
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
                // before 0:00, under the first clip's handle
                allSound.offset(x: -(Self.headWidth + Self.headGap), y: 2)
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                    timelineClip(c, i, w: CGFloat(c.span) * pps).offset(x: CGFloat(starts[i]) * pps, y: 2)
                }
                // the song's beats, as yellow ticks (Stage E)
                let beats: [Double] = songBeats
                ForEach(beats.indices, id: \.self) { b in
                    Rectangle().fill(Color.yellow.opacity(0.85)).frame(width: 1, height: 6)
                        .offset(x: CGFloat(beats[b]) * pps, y: 50).allowsHitTesting(false)
                }
                // the square for each join, in the middle of where one turns into the next
                // (not the picked clip's two: its trim handles are there, and a square under one hid it, 21 Nov)
                ForEach(joins.filter { index == nil || ($0 != index && $0 + 1 != index) }, id: \.self) { i in
                    let at = starts[i + 1] + ClipJoin.overlap(clips, after: i) / 2
                    joinSquare(i).offset(x: CGFloat(at) * pps - 9, y: 16)
                }
                Button { if !motion.justStopped { stopGlide(); adding = true } } label: {
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
        return VStack(spacing: 2) {
            ClipThumb(clip: c)
                .frame(height: Self.thumbHeight)
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
            clipWave(c, at, width: max(6, w - 2))
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

    /// A clip's wave, at the timeline's own detail (design/timeline-waveforms-pro-mockup.html).
    private func clipWave(_ c: Clip, _ at: Int, width: CGFloat) -> some View {
        let url: URL = c.clean ?? c.source
        let heard: Bool = c.soundOn && !c.still && (soundOf == nil || soundOf == c.id)
        let starts: [Double] = ClipJoin.starts(clips)
        let start: Double = starts.indices.contains(at) ? starts[at] : 0
        var under: [ClosedRange<Double>] = []
        if heard {
            for v in sounds where v.kind == "voice" {
                let low: Double = max(0, v.from - start), high: Double = min(c.span, v.to - start)
                if high > low { under.append(low...high) }
            }
        }
        return ClipWave(clip: c, file: waves.files[url], heard: heard, width: width, height: Self.waveHeight, pps: perSecond, under: under,
                        clock: clock, from: start)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .task(id: url) { if !c.still { await waves.load(url) } }
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
        let live: TrimDrag? = trimLive
        let x0 = x + dl, width = max(8, w + dr - dl)
        func handle(_ side: Int) -> some View {
            // (the white is the frame's, drawn whole below: this is where it's caught, and its grip)
            Color.clear.frame(width: 12, height: 48)
                .overlay(Capsule().fill(Color(white: 0.2)).frame(width: 2, height: 14))
                // a thumb's width to catch it by
                .padding(.horizontal, 10).contentShape(Rectangle()).padding(.horizontal, -10)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($trimLive) { v, live, _ in live = TrimDrag(side: side, dx: heldTrim(c, side: side, dx: v.translation.width, pps: pps).dx) }
                    .onChanged { v in
                        let held: (dx: CGFloat, pause: Double?) = heldTrim(c, side: side, dx: v.translation.width, pps: pps)
                        trimHeld(held.pause)
                        if trimDrag == nil { player.pause(); playing = false; UISelectionFeedbackGenerator().selectionChanged() }
                        // a tap the moment it reaches the end of the video
                        let lo = side == 0 ? leftMin : rightMin, hi = side == 0 ? leftMax : rightMax
                        let out = v.translation.width < lo - 0.5 || v.translation.width > hi + 0.5
                        if out, let was = trimDrag, !(was.dx < lo - 0.5 || was.dx > hi + 0.5) { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
                        trimDrag = TrimDrag(side: side, dx: v.translation.width)
                        // the frame it'll start or end on, under the line
                        let d = side == 0 ? min(max(held.dx, leftMin), leftMax) : min(max(held.dx, rightMin), rightMax)
                        let at = side == 0 ? startOf(i) + Double(d / pps) : startOf(i) + c.span + Double(d / pps) - 0.04
                        // (inside the clip: past its ends is the next clip's picture, not this one's)
                        chase(min(max(startOf(i), at), startOf(i) + max(0, c.span - 0.04)))
                    }
                    .onEnded { v in
                        let dx: CGFloat = heldTrim(c, side: side, dx: v.translation.width, pps: pps).dx
                        let d = side == 0 ? min(max(dx, leftMin), leftMax) : min(max(dx, rightMin), rightMax)
                        pauseHeld = nil
                        trimDrag = nil
                        let clicked: Bool = abs(v.translation.width) < TimelineRows.dragStarts
                        if clicked || abs(d) < 0.5 { seek(now) } else { trimEnd(i, side: side, by: Double(d / pps) * r) }
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
            if let live { clipPauses(c, live, x: x + 12 - x0, width: width, pps: pps) }
        }
        .offset(x: x0 - 12, y: 0)
    }

    /// A clip's handle held on a pause in what's said in it (a click still moves nothing; drag past and it lets go).
    private func heldTrim(_ c: Clip, side: Int, dx: CGFloat, pps: CGFloat) -> (dx: CGFloat, pause: Double?) {
        guard !c.still, c.soundOn, abs(dx) >= TimelineRows.dragStarts, let file = waves.files[c.clean ?? c.source] else { return (dx, nil) }
        let perPoint: Double = max(c.speed, 0.01) / Double(max(pps, 1))
        let edge: Double = side == 0 ? c.start : c.end
        // (zoomed right out, seven points is most of the way to the next pause)
        let reach: Double = min(Double(TimelineRows.snapReach) * 1.4 * perPoint, 0.25 * max(c.speed, 0.01))
        guard let p = WaveMath.pause(file.pauses, near: edge + Double(dx) * perPoint, reach: reach) else { return (dx, nil) }
        // (only where the end can go: at least a third of a second left)
        let allowed: Bool = side == 0 ? (p >= 0 && p <= c.end - 0.3) : (p <= c.length && p >= c.start + 0.3)
        guard allowed else { return (dx, nil) }
        return (CGFloat((p - edge) / perPoint), p)
    }

    private func trimHeld(_ pause: Double?) {
        guard pauseHeld != pause else { return }
        if pause != nil { UISelectionFeedbackGenerator().selectionChanged() }
        pauseHeld = pause
    }

    /// The pauses along a clip as it's trimmed. `x`: where the clip's start is, in its frame.
    private func clipPauses(_ c: Clip, _ live: TrimDrag, x: CGFloat, width: CGFloat, pps: CGFloat) -> some View {
        let url: URL = c.clean ?? c.source
        let pauses: [Double] = c.soundOn && !c.still ? (waves.files[url]?.pauses ?? []) : []
        let perSource: CGFloat = pps / CGFloat(max(c.speed, 0.01))
        let place: (Double) -> CGFloat = { (p: Double) -> CGFloat in x + CGFloat(p - c.start) * perSource }
        let left: Double = c.duration + Double(live.dx / perSource) * (live.side == 0 ? -1 : 1)
        let edge: CGFloat = live.side == 0 ? 12 : 12 + width
        let names: Set<String> = [c.source.lastPathComponent]
        return ZStack(alignment: .topLeading) {
            PauseMarks(places: pauses.map(place), held: pauseHeld.map(place), height: Self.waveHeight + 6)
                .frame(width: max(width, 1), height: Self.waveHeight + 6, alignment: .topLeading)
                .offset(y: Self.thumbHeight + 1)
            if let p = pauseHeld {
                pauseBubble(c.id, files: names, at: p, seconds: left / max(c.speed, 0.01))
                    .frame(width: 280)
                    .offset(x: edge - 140, y: 9)
            }
        }
        .frame(width: max(width + 24, 1), height: Self.clipRow, alignment: .topLeading)
        .allowsHitTesting(false)
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
        let rows = Array(barRows.prefix(TimelineRows.most))
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.indices, id: \.self) { r in
                ZStack(alignment: .leading) {
                    // the row's rail, the whole way along, so where each row is shows even where it's empty (CapCut's)
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.13))
                    // where a held bar would go: the row outlined, or a line where it'd be a new row of its own
                    if dropRow == r { dropMark(r, rows[r]) }
                    ForEach(rows[r]) { item in bar(item, w: width, span: span, onTimeline: true, among: rows[r]) }
                }
                .frame(width: width, height: Self.laneHeight, alignment: .leading)
                // (over the other rows' rails while its bar's lifted: under them, it vanished as it was dragged, 22 Nov)
                .zIndex(hasLifted(rows[r]) ? 1 : 0)
            }
            // while a bar's lifted, a rail under the last: a new row for it if it's dropped there
            if canAddRow { emptyRail(wanted: dropRow == rows.count, width: width) }
        }
        // each row's tile (a caption row's, its eye) just before 0:00, lined up with it, under a picked bar's handle
        .background(alignment: .topLeading) { laneHeads.offset(x: -(Self.headWidth + Self.headGap)) }
        .overlay(alignment: .topLeading) { barHandles(rows, width: width, span: span) }
        .onChange(of: onHandle) { (_: Bool, down: Bool) in handleReleased(down) }
        .coordinateSpace(name: "bars")
        .padding(.top, 2)
    }

    private func hasLifted(_ row: [BarItem]) -> Bool {
        // (on its way up too: under the next row's rail, the start of the lift didn't show)
        guard let id = lifted ?? (pressMoved ? nil : pressed) else { return false }
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
    // (22 Nov recording: 36 out from each end and over into the rows above and below, a click or a slide near a bar
    // trimmed it. The grip and 10 more to the side, as a clip's handle, and its own row up and down.)
    private static let gripWidth: CGFloat = 12, catchOutside: CGFloat = 22, catchHeight: CGFloat = 38

    /// How wide a bar's drawn: its length, a short one widened to 16 to tap only as far as the next on its row (22 Nov:
    /// a short caption ran over the one after, a light strip where the two crossed).
    /// The picked one's exactly its length: widened, its far end moved out as the near one was trimmed in.
    private static func drawnWidth(_ item: BarItem, among row: [BarItem], w: CGFloat, span: Double, picked: Bool = false) -> CGFloat {
        let left: CGFloat = w * CGFloat(min(item.from, span) / span)
        let right: CGFloat = w * CGFloat(min(item.to, span) / span)
        let length: CGFloat = right - left
        if picked { return max(2, length) }
        guard length < 16 else { return length }
        var room: CGFloat = 16
        for other in row where other.id != item.id && other.from > item.from {
            let next: CGFloat = w * CGFloat(min(other.from, span) / span)
            room = min(room, next - left)
        }
        return max(2, max(length, room))
    }

    private static func catchInside(_ barWidth: CGFloat) -> CGFloat { min(8, barWidth / 4) }

    /// The picked bar's two white handles, over every row (22 Nov: "not handles?").
    @ViewBuilder private func barHandles(_ rows: [[BarItem]], width w: CGFloat, span: Double) -> some View {
        if lifted == nil, selected == nil, let item = pickedBar, let r = rows.firstIndex(where: { (row: [BarItem]) -> Bool in row.contains { (b: BarItem) -> Bool in b.id == item.id } }) {
            let wide: CGFloat = Self.drawnWidth(item, among: rows[r], w: w, span: span, picked: true)
            // all three from the one top left corner: left to the overlay they were centred on each other first, the
            // frame 5 under its bar and each end's catch off to the right of its grip (22 Nov)
            ZStack(alignment: .topLeading) {
                barFrame(item, row: r, barWidth: wide, w: w, span: span)
                barHandle(item, side: 1, row: r, bars: rows[r], barWidth: wide, w: w, span: span)
                barHandle(item, side: 2, row: r, bars: rows[r], barWidth: wide, w: w, span: span)
                barPauses(item, row: r, w: w, span: span)
            }
        }
    }

    /// The picked bar's frame: one white shape, as a picked clip's is, rounded outside and square inside against the
    /// bar's square ends (22 Nov: two tabs against its round ends left dark wedges in the corners).
    private func barFrame(_ item: BarItem, row: Int, barWidth: CGFloat, w: CGFloat, span: Double) -> some View {
        let left: CGFloat = w * CGFloat(min(item.from, span) / span)
        let grip: CGFloat = Self.gripWidth, h: CGFloat = Self.laneHeight
        let outside = CGRect(x: left - grip, y: 0, width: barWidth + grip * 2, height: h)
        let hole = CGRect(x: left, y: 2, width: barWidth, height: h - 4)
        let trimming: Bool = barGrab?.id == item.id && barGrab?.mode != 0
        let middle = UnitPoint(x: (left + barWidth / 2) / max(w, 1), y: 0.5)
        // Drawn where it is, not drawn and then moved there: its width and its place came a frame apart as it was
        // trimmed, and the far handle jumped, a dark gap in it (22 Nov recording). Trimmed, the bar's colour is its too.
        return ZStack(alignment: .topLeading) {
            if trimming {
                trimGhosts(item, w: w, span: span)
                trimFill(item, hole: hole)
            }
            Path { p in
                p.addRoundedRect(in: outside, cornerSize: CGSize(width: 6, height: 6), style: .continuous)
                p.addRect(hole)
            }
            .fill(Color.white, style: FillStyle(eoFill: true))
            gripMarks(outside, grip: grip)
        }
        .frame(width: max(w, 1), height: h, alignment: .topLeading)
        // (lifting with its bar: left where it was, the bar grew out from inside it)
        .modifier(BarLift(up: false, pressing: holdingBar(item.id), anchor: middle))
        .offset(y: CGFloat(row) * (h + 3))
        .allowsHitTesting(false)
    }

    /// The picked bar as it's trimmed, in the frame.
    private func trimFill(_ item: BarItem, hole: CGRect) -> some View {
        let ink: Color = item.off ? Color.white.opacity(0.5) : Color.black.opacity(0.82)
        return ZStack(alignment: .topLeading) {
            Path(hole).fill(Color(white: 0.13))
            Path(hole).fill(item.colour.opacity(0.88))
            barFace(item, width: hole.width, height: Self.laneHeight, ink: ink)
                .clipped()
                .offset(x: hole.minX)
        }
    }

    /// What's being trimmed off a sound, faded, so it's seen what goes.
    private func trimGhosts(_ item: BarItem, w: CGFloat, span: Double) -> some View {
        let gone: [EditSound] = trimmedAway(item)
        return ZStack(alignment: .topLeading) {
            ForEach(gone.indices, id: \.self) { (i: Int) in ghost(gone[i], w: w, span: span) }
        }
    }

    private func ghost(_ s: EditSound, w: CGFloat, span: Double) -> some View {
        let left: CGFloat = w * CGFloat(s.from / span)
        let wide: CGFloat = w * CGFloat(s.length / span)
        let file: WaveFile? = s.url.flatMap { (u: URL) -> WaveFile? in waves.files[u] }
        return SoundBarWave(sound: s, file: file, width: wide, height: Self.laneHeight, pps: perSecond, ink: Self.waveInk(s.kind), clock: clock)
            .background(Self.soundColour(s.kind))
            .opacity(0.3)
            .offset(x: left)
    }

    private func trimmedAway(_ item: BarItem) -> [EditSound] {
        guard item.kind == 1, let g = barGrab, g.id == item.id, g.mode != 0 else { return [] }
        guard let s = sounds.first(where: { (x: EditSound) -> Bool in x.id == g.id }), s.kind != "song" else { return [] }
        let low: Double = g.mode == 1 ? g.from : s.to
        let high: Double = g.mode == 1 ? s.from : g.to
        guard high - low > 0.02 else { return [] }
        var part: EditSound = s
        part.from = low
        part.start = g.start + (low - g.from) * s.speed
        part.length = high - low
        part.fadeIn = nil
        part.fadeOut = nil
        return [part]
    }

    private func gripMarks(_ outside: CGRect, grip: CGFloat) -> some View {
        let size = CGSize(width: 2, height: 14), top: CGFloat = outside.midY - 7
        let first = CGRect(origin: CGPoint(x: outside.minX + (grip - 2) / 2, y: top), size: size)
        let second = CGRect(origin: CGPoint(x: outside.maxX - (grip + 2) / 2, y: top), size: size)
        return Path { p in
            p.addRoundedRect(in: first, cornerSize: CGSize(width: 1, height: 1))
            p.addRoundedRect(in: second, cornerSize: CGSize(width: 1, height: 1))
        }
        .fill(Color(white: 0.2))
    }

    /// side: 1 its start, 2 its end (as BarGrab's modes).
    private func barHandle(_ item: BarItem, side: Int, row: Int, bars: [BarItem], barWidth: CGFloat, w: CGFloat, span: Double) -> some View {
        let left: CGFloat = w * CGFloat(min(item.from, span) / span)
        let out: CGFloat = Self.catchOutside, tall: CGFloat = Self.catchHeight, inside: CGFloat = Self.catchInside(barWidth)
        let x: CGFloat = side == 1 ? left - out : left + barWidth - inside
        let y: CGFloat = CGFloat(row) * (Self.laneHeight + 3) - (tall - Self.laneHeight) / 2
        // (the white and its grips are the frame's: this is only where it's caught)
        return Color.clear
            .frame(width: out + inside, height: tall)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("bars"))
                .updating($onHandle) { _, down, _ in down = true }
                .onChanged { handleChanged($0, item, side: side, w: w, span: span) }
                .onEnded { handleEnded($0, item, bars: bars, w: w, span: span) })
            .accessibilityLabel(side == 1 ? "Start of \(item.label)" : "End of \(item.label)")
            .offset(x: x, y: y)
    }

    private func handleChanged(_ v: DragGesture.Value, _ item: BarItem, side: Int, w: CGFloat, span: Double) {
        if !handleDown { handleDown = true }   // from the moment it's touched, before it's gone far enough to be a drag
        if barGrab == nil {
            // (a click moves nothing: a point's wobble trimmed it, and held it on the nearest edge 8 points off)
            let dx: CGFloat = abs(v.translation.width), dy: CGFloat = abs(v.translation.height)
            guard scrubFrom == nil, dx >= TimelineRows.dragStarts, dx > dy else { return }
            grabBar(item, mode: side)
        }
        guard barGrab?.id == item.id else { return }
        moveBar(v, item, w: w, span: span)
    }

    /// A handle let go. Only clicked, it's the bar under it that was meant, if there's one (a short caption beside it).
    private func handleEnded(_ v: DragGesture.Value, _ item: BarItem, bars: [BarItem], w: CGFloat, span: Double) {
        let clicked: Bool = barGrab == nil && hypot(v.translation.width, v.translation.height) < TimelineRows.dragStarts
        handleDown = false
        letGo(item)
        guard clicked else { return }
        let t: Double = Double(v.startLocation.x / max(w, 1)) * span
        let under: BarItem? = bars.first { (b: BarItem) -> Bool in b.id != item.id && t >= b.from && t < b.to }
        if let under { pickBar(under) }
    }

    /// A handle's drag over, cut short or not: nothing left held.
    private func handleReleased(_ down: Bool) {
        guard !down else { return }
        handleDown = false
        guard let g = barGrab, g.mode != 0 else { return }
        if let item = barItems.first(where: { (b: BarItem) -> Bool in b.id == g.id }) { letGo(item) }
    }

    /// A tile for each row of bars, against the timeline's start and lined up with its row: what's on it (captions, text,
    /// stickers, voice, music, sound FX, overlays; mixed, a stack), as CapCut heads its tracks.
    private var laneHeads: some View {
        let rows = Array(barRows.prefix(TimelineRows.most))
        return VStack(spacing: 3) {
            ForEach(rows.indices, id: \.self) { r in laneHead(rows[r]) }
        }
    }

    /// One row's tile: what's on it; a row of captions', the eye that switches them on and off.
    @ViewBuilder private func laneHead(_ row: [BarItem]) -> some View {
        let caps: Set<UUID> = captionsOn(row)
        if caps.isEmpty {
            laneTile(laneIcon(row), lit: true).allowsHitTesting(false)
        } else {
            let showing: Bool = row.contains { (b: BarItem) -> Bool in caps.contains(b.id) && !b.off }
            laneTile(showing ? "eye" : "eye.slash", lit: showing)
                .contentShape(Rectangle())
                // by the screen's measure, as Clip sound: a slide of the timeline that starts here mustn't switch it
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onEnded { tappedEye($0, caps, hide: showing) })
                .accessibilityElement()
                .accessibilityLabel(showing ? "Switch this row's captions off" : "Switch this row's captions on")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { switchCaptions(caps, hide: showing) }
        }
    }

    private func laneTile(_ icon: String, lit: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(lit ? 0.85 : 0.4))
            .frame(width: Self.headWidth, height: Self.laneHeight)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func captionsOn(_ row: [BarItem]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for b in row where b.kind == 0 { ids.insert(b.id) }
        guard !ids.isEmpty else { return [] }
        var out: Set<UUID> = []
        for t in texts where t.kind == "caption" && ids.contains(t.id) { out.insert(t.id) }
        return out
    }

    private func tappedEye(_ v: DragGesture.Value, _ ids: Set<UUID>, hide: Bool) {
        if !motion.justStopped, hypot(v.translation.width, v.translation.height) < 6 { switchCaptions(ids, hide: hide) }
    }

    /// A row's captions switched off, or on.
    private func switchCaptions(_ ids: Set<UUID>, hide: Bool) {
        remember()
        // every bar keeps its row: one on and one off don't share
        pinRows(barRows.map { (row: [BarItem]) -> [UUID] in row.map(\.id) })
        for i in texts.indices where ids.contains(texts[i].id) { texts[i].hidden = hide ? true : nil }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Every bar on the row these rows give it.
    private func pinRows(_ rows: [[UUID]]) {
        var lane: [UUID: Int] = [:]
        for (r, ids) in rows.enumerated() { for id in ids { lane[id] = r } }
        var t = texts, s = sounds, p = pips
        for k in t.indices { t[k].lane = lane[t[k].id] }
        for k in s.indices { s[k].lane = lane[s[k].id] }
        for k in p.indices { p[k].lane = lane[p[k].id] }
        texts = t
        if s != sounds { sounds = s }
        if p != pips { pips = p }
    }

    /// The captions changed to these, and put in their layers' rows.
    private func setLayered(_ changed: [EditText], sounds laid: [EditSound]) {
        let before: [[UUID]] = barRows.map { (row: [BarItem]) -> [UUID] in row.map(\.id) }
        var live: Set<UUID> = []
        for t in changed where t.kind != "caption" { live.insert(t.id) }
        for s in laid { live.insert(s.id) }
        for p in pips { live.insert(p.id) }
        let rows: [[UUID]] = CaptionLayers.rows(before, texts: changed, sounds: laid, live: live)
        texts = changed
        pinRows(rows)
    }

    /// A voiceover or the clips under it moved: the video's captions switched off are those under it now.
    private func settleLayers() {
        let settled: [EditText] = CaptionLayers.settled(texts, sounds: sounds)
        if settled != texts { setLayered(settled, sounds: sounds) }
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

    private static let deadZone: CGFloat = 6

    /// The timeline slid by a finger, point for point: the video under the line follows it, with a tick over each
    /// clip's edge. (22 Nov: held within 8 points of an edge, and the first 6 points all at once, it went in jerks.)
    private func scrubTimeline(by dx: CGFloat, from start: CGPoint, mid: CGFloat, pps: CGFloat) {
        if scrubSkip { return }
        // a bar held and lifted, or being moved: the timeline keeps still under it from then on
        if lifted != nil || barGrab != nil { return }
        if motion.gliding { touchedTimeline() }
        var origin: Double
        if let from = scrubFrom {
            origin = from
        } else {
            // a bar or a clip's end being dragged has the finger: the timeline keeps still under it. Told by where the
            // finger came down, not only by the bar's own drag having begun: that came too late, and the timeline slid
            // under a trim handle being dragged, the handle drifting from the finger (21 Nov recording)
            // (the handle's own word for it first: a touch just outside its box is still given to it, and then the
            // timeline slid and the bar trimmed at once, 22 Nov recording)
            if handleDown || barGrab != nil || trimDrag != nil || onHandleOrBar(start, mid: mid, pps: pps) { scrubSkip = true; return }
            origin = now
            // (from what's on the screen as it plays, not the last of its twenty a second)
            if player.rate != 0 {
                let t: Double = player.currentTime().seconds
                if t.isFinite { origin = t }
            }
            motion.slip = CGFloat(TimelineGlide.slip(Double(dx), deadZone: Double(Self.deadZone)))
            motion.ready()
            scrubFrom = origin
            wasPlaying = player.rate != 0
            player.pause(); playing = false
            now = origin
        }
        _ = moveLine(to: origin - Double((dx - motion.slip) / max(pps, 1)))
    }

    /// The line put at 't' under a slide or a glide; false at either end of the video.
    private func moveLine(to t: Double) -> Bool {
        // (short of the very end, where the preview goes round to the start again)
        let last: Double = max(0, max(total, 0.01) - 0.12)
        let to: Double = min(max(0, t), last)
        let old: Double = now
        if to != old {
            var edges: [Double] = Array(ClipJoin.starts(clips).dropFirst())
            edges.append(0)
            edges.append(last)
            if TimelineGlide.crossed(edges, from: old, to: to) { motion.tick() }
            chase(to)
            now = to
        }
        return t > 0 && t < last
    }

    /// Let go: it glides on from a flick; from still, it settles on a clip's edge it's right by.
    private func endScrub(velocity: CGFloat, pps: CGFloat) {
        if scrubSkip { scrubSkip = false; return }
        guard scrubFrom != nil, !motion.gliding else { return }
        let points: Double = Double(max(pps, 1))
        let speed: Double = Double(velocity)
        if abs(speed) > TimelineGlide.starts {
            let from: Double = now
            motion.glide(velocity: speed,
                         move: { (gone: Double) -> Bool in moveLine(to: from - gone / points) },
                         ended: { finishScrub(resume: true) })
            return
        }
        let reach: Double = TimelineGlide.settles / points
        let edges: [Double] = Array(ClipJoin.starts(clips).dropFirst())
        if let edge = edges.min(by: { (a: Double, b: Double) -> Bool in abs(a - now) < abs(b - now) }), abs(edge - now) < reach {
            _ = moveLine(to: edge)
        }
        finishScrub(resume: true)
    }

    private func finishScrub(resume: Bool) {
        guard scrubFrom != nil else { return }
        scrubFrom = nil
        seek(now)
        if resume, wasPlaying == true { player.play(); playing = true }
        wasPlaying = nil
    }

    private func stopGlide() {
        guard motion.gliding else { return }
        motion.end()
        finishScrub(resume: false)
    }

    private func panelChanged() {
        endVoice()
        trimDrag = nil
        fingerHeld = false
        stopGlide()
    }

    /// The timeline taken away (a panel, full screen) with a slide or glide under way.
    private func timelineGone() {
        motion.end()
        motion.clearTouch()
        scrubSkip = false
        finishScrub(resume: false)
    }

    private func stripGone() {
        if scrubFrom == nil, wasPlaying != nil { wasPlaying = nil }
    }

    private func touchedTimeline() {
        guard motion.gliding else { return }
        motion.stopByTouch()
        finishScrub(resume: false)
    }

    /// The finger off the timeline, however that drag ended: cut short, it has no end of its own.
    private func timelineReleased(_ down: Bool) {
        guard !down else { return }
        DispatchQueue.main.async {
            guard !onTimeline else { return }
            scrubSkip = false
            if !motion.gliding { finishScrub(resume: true) }
        }
        // (after the tap that lifting it is)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if !onTimeline { motion.clearTouch() }
        }
    }

    /// Two fingers: a pinch, not a slide.
    private func beganPinch() {
        motion.end()
        finishScrub(resume: false)
        scrubSkip = true
    }

    private func trimReleased(_ gone: Bool) {
        if gone, pauseHeld != nil, barGrab == nil { pauseHeld = nil }
        guard gone, trimDrag != nil else { return }
        trimDrag = nil
        seek(now)
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
        guard selected == nil, let item = pickedBar, let r = rowOf(item.id), r < TimelineRows.most else { return false }
        let top: CGFloat = lanesTop + CGFloat(r) * (Self.laneHeight + 3) - (Self.catchHeight - Self.laneHeight) / 2
        guard p.y >= top, p.y <= top + Self.catchHeight else { return false }
        let span: Double = max(total, 0.01)
        let x0: CGFloat = shift + CGFloat(min(item.from, span)) * pps
        let barWidth: CGFloat = Self.drawnWidth(item, among: barRows[r], w: CGFloat(span) * pps, span: span, picked: true)
        let inside: CGFloat = Self.catchInside(barWidth), outside: CGFloat = Self.catchOutside
        let x1: CGFloat = x0 + barWidth
        return (p.x >= x0 - outside && p.x <= x0 + inside) || (p.x >= x1 - inside && p.x <= x1 + outside)
    }

    /// A finger looking through the video: the engine only notes where it's wanted and draws that the next frame
    /// (the wait for one seek before the next, Apple's way for its player, put each step a frame or more behind).
    private func chase(_ t: Double) {
        let near = CMTime(seconds: 0.04, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: near, toleranceAfter: near)
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
        Button { stopGlide(); run() } label: {
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
        let c: Clip = clips[i]
        let sub: String = String(format: "%.1f s of %.1f s", c.duration, c.length)
        return VStack(spacing: 0) {
            ProLead(title: "Clip \(i + 1)", sub: sub) { EmptyView() }
            ProBody(height: 144, spacing: 20) {
                trimStrip(i, c)
                trimNumbers(c)
            }
        }
    }

    private func trimStrip(_ i: Int, _ c: Clip) -> some View {
        RangeBar(length: c.length, start: c.start, end: c.end, colour: .white, background: { ClipThumb(clip: c, whole: true) }) { s, e in
            guard clips.indices.contains(i) else { return }
            clips[i].start = s; clips[i].end = e
            // its sound kept inside what's kept of the picture
            if let ss = clips[i].soundStart { clips[i].soundStart = max(s, min(ss, e)) }
            if let se = clips[i].soundEnd { clips[i].soundEnd = max(s, min(se, e)) }
        } began: {
            editHeld(true)
        } ended: {
            editHeld(false)
        }
        .frame(height: 56)
        .overlay { Live { trimLine(i) } }
    }

    /// Where the line is in the clip's whole file, on its strip.
    private func trimLine(_ i: Int) -> some View {
        let at: Double? = clips.indices.contains(i) ? fileTime(i) : nil
        let length: Double = clips.indices.contains(i) ? max(clips[i].length, 0.01) : 1
        return GeometryReader { g in
            if let at {
                Rectangle().fill(Color.white).frame(width: 2, height: g.size.height + 10)
                    .offset(x: g.size.width * CGFloat(min(1, at / length)) - 1, y: -5)
            }
        }
        .allowsHitTesting(false)
    }

    private func trimNumbers(_ c: Clip) -> some View {
        HStack(spacing: 0) {
            trimNumber("Start", Self.tenths(c.start))
            Spacer(minLength: 0)
            trimNumber("Kept", String(format: "%.1f s", c.duration))
            Spacer(minLength: 0)
            trimNumber("End", Self.tenths(c.end))
        }
    }

    private func trimNumber(_ name: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Text(name).font(.system(size: 11)).foregroundStyle(ProInk.quiet)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    /// A time to the tenth, as "00:08.0".
    static func tenths(_ s: Double) -> String {
        let all: Int = Int((max(0, s) * 10).rounded())
        return String(format: "%02d:%02d.%d", all / 600, (all / 10) % 60, all % 10)
    }

    private func soundPanel(_ i: Int) -> some View {
        let c: Clip = clips[i]
        return VStack(spacing: 0) {
            ProLead(title: "Clip \(i + 1)", sub: "") {
                if !c.still { clipSoundActions(i, c) }
            }
            if c.still {
                ProBody(height: 144) { ProHint(words: "A photo has no sound of its own.") }
            } else {
                soundTabs(beats: false)
                ProBody {
                    if !c.soundOn {
                        ProHint(words: "This clip's sound is off. Tap Muted to bring it back.")
                    } else if soundTool == .fade {
                        fadePanel(i)
                    } else {
                        volumePanel(i)
                    }
                }
            }
        }
        .task(id: c.clean ?? c.source) { if !c.still { await waves.load(c.clean ?? c.source) } }
    }

    @ViewBuilder private func clipSoundActions(_ i: Int, _ c: Clip) -> some View {
        ProAction(icon: c.soundOn ? "speaker.slash" : "speaker.slash.fill", name: c.soundOn ? "Mute" : "Muted", on: !c.soundOn,
                  run: { toggleClipSound(i) })
        ProAction(icon: "music.note", name: "Use for all", on: soundOf == c.id, run: { toggleSoundForAll(c.id) })
        ProAction(icon: "waveform", name: "Clearer", on: c.clean != nil, run: { clearer(i) })
    }

    private func toggleClipSound(_ i: Int) {
        guard clips.indices.contains(i) else { return }
        remember()
        clips[i].soundOn.toggle()
    }

    private func toggleSoundForAll(_ id: UUID) {
        remember()
        soundOf = soundOf == id ? nil : id
    }

    /// Volume and Fade, and for music Cut to beat.
    private func soundTabs(beats: Bool) -> some View {
        var names: [String] = ["Volume", "Fade"]
        if beats { names.append("Cut to beat") }
        var here = "Volume"
        if soundTool == .fade { here = "Fade" } else if beats && soundTool == .beats { here = "Cut to beat" }
        return ProTabs(names: names, on: here, pick: { (name: String) in
            switch name {
            case "Fade": soundTool = .fade
            case "Cut to beat": soundTool = .beats
            default: soundTool = .volume
            }
        })
    }


    /// Where the line is in the clip's own file, if the line is inside it.
    private func fileTime(_ i: Int) -> Double? {
        let into = now - startOf(i)
        guard into >= -0.01, into <= clips[i].span + 0.01 else { return nil }
        return clips[i].start + min(max(0, into) * clips[i].speed, clips[i].duration)
    }

    /// Volume: with keyframes, the number and slider are the level at the line, and the diamond adds one there (or
    /// takes away the one it's on), as CapCut's does.
    private func volumePanel(_ i: Int) -> some View {
        let c: Clip = clips[i]
        let at: Double? = fileTime(i)
        let near: Int? = at.flatMap { (t: Double) -> Int? in c.keys.firstIndex { (k: VolumeKey) -> Bool in abs(k.at - t) < 0.15 } }
        var shown: Float = c.volume
        if !c.keys.isEmpty, let at { shown = c.level(at: at) }
        let span: Double = max(c.duration, 0.01)
        let marks: [StripKey] = c.keys.map { (k: VolumeKey) -> StripKey in StripKey(at: (k.at - c.start) / span, level: Double(k.volume)) }
        let line: Double? = at.map { (t: Double) -> Double in (t - c.start) / span }
        return VStack(spacing: 14) {
            volumeSlide(Double(shown), set: { (v: Double) in setVolume(i, Float(v)) })
            HStack(spacing: 12) {
                keyAction(near != nil, enabled: at != nil, run: { toggleClipKey(i) })
                KeyframeStrip(levels: clipLevels(c), colour: Self.clipGreen, keys: marks, line: line,
                              scrub: { (f: Double) in scrubClipStrip(i, f) })
            }
        }
    }

    private static let clipGreen = Color(red: 0.24, green: 0.86, blue: 0.52)

    /// A clip's wave for its panels' strips.
    private func clipLevels(_ c: Clip) -> [Float] {
        waves.files[c.clean ?? c.source]?.part(from: c.start, to: c.end, count: 120) ?? []
    }

    private func volumeSlide(_ value: Double, set: @escaping (Double) -> Void) -> some View {
        ProSlide(name: "Volume", value: value, range: 0...1, shown: ProSlide.percent(value),
                 held: { (on: Bool) in editHeld(on) }, set: set)
    }

    private func keyAction(_ here: Bool, enabled: Bool, run: @escaping () -> Void) -> some View {
        ProAction(icon: here ? "diamond.fill" : "diamond", name: here ? "Remove" : "Keyframe", on: here, enabled: enabled,
                  lit: ProInk.key, run: run)
            .frame(width: 74, alignment: .leading)   // the same width whichever it says (21 Nov: the strip beside it jumped)
    }

    private func toggleClipKey(_ i: Int) {
        guard clips.indices.contains(i), let at = fileTime(i) else { return }
        let c: Clip = clips[i]
        remember()
        if let near = c.keys.firstIndex(where: { (k: VolumeKey) -> Bool in abs(k.at - at) < 0.15 }) {
            clips[i].keys.remove(at: near)
        } else {
            let level: Float = c.keys.isEmpty ? c.volume : c.level(at: at)
            clips[i].keys.append(VolumeKey(at: at, volume: level))
        }
    }

    private func scrubClipStrip(_ i: Int, _ f: Double) {
        guard clips.indices.contains(i) else { return }
        stripSeek(startOf(i) + f * clips[i].span)
    }

    /// The line moved from a sound's strip.
    private func stripSeek(_ t: Double) {
        if player.rate != 0 { player.pause(); playing = false }
        seek(min(max(0, t), max(0, total - 0.01)))
    }



    /// The slider moved: the clip's volume, or with keyframes the one at the line (made there if there isn't one).
    private func setVolume(_ i: Int, _ v: Float) {
        guard clips.indices.contains(i) else { return }
        guard !clips[i].keys.isEmpty, let at = fileTime(i) else { clips[i].volume = v; return }
        if let k = clips[i].keys.firstIndex(where: { abs($0.at - at) < 0.15 }) { clips[i].keys[k].volume = v }
        else { clips[i].keys.append(VolumeKey(at: at, volume: v)) }
    }

    /// Fade: how long it fades in and out, each up to 3 seconds (and never past half the clip).
    private func fadePanel(_ i: Int) -> some View {
        let c: Clip = clips[i]
        let most: Double = max(0.1, min(3, c.duration / 2))
        let span: Double = max(c.duration, 0.01)
        return VStack(spacing: 4) {
            FadeWave(levels: clipLevels(c), colour: Self.clipGreen, fadeIn: c.fadeIn / span, fadeOut: c.fadeOut / span)
            fadeRow("Fade in", value: clipValue(i, \.fadeIn, most: most), most: most)
            fadeRow("Fade out", value: clipValue(i, \.fadeOut, most: most), most: most)
        }
    }

    private func clipValue(_ i: Int, _ key: WritableKeyPath<Clip, Double>, most: Double) -> Binding<Double> {
        Binding<Double>(get: { clips.indices.contains(i) ? min(clips[i][keyPath: key], most) : 0 },
                        set: { (v: Double) in if clips.indices.contains(i) { clips[i][keyPath: key] = v } })
    }

    private func fadeRow(_ title: String, value: Binding<Double>, most: Double) -> some View {
        ProSlide(name: title, value: value.wrappedValue, range: 0...most, shown: ProSlide.seconds(value.wrappedValue),
                 held: { (on: Bool) in editHeld(on) }, set: { (v: Double) in value.wrappedValue = v })
    }


    // MARK: doing things

    private func select(_ id: UUID) {
        if motion.gliding || motion.justStopped { return }   // (that touch was to stop the timeline)
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
        guard barGrab == nil, restoring == nil else { return }
        let ids: Set<UUID> = Set(sounds.map { (s: EditSound) -> UUID in s.id })
        let tied = texts.contains { (t: EditText) -> Bool in
            guard t.kind == "caption", let words = t.words else { return false }
            return words.contains { (w: EditText.Word) -> Bool in w.clip.map { ids.contains($0) } ?? false }
        }
        let kept: Bool = sounds.contains { (s: EditSound) -> Bool in s.cut != nil }
        if tied || kept {
            let out: (texts: [EditText], sounds: [EditSound]) = CaptionLayers.trimmed(texts, clips: clips, sounds: sounds)
            texts = out.texts
            if out.sounds != sounds { sounds = out.sounds }
        }
        settleLayers()
    }

    private var snap: Snap {
        Snap(clips: clips, sounds: sounds, texts: texts, pips: pips, look: look, soundOf: soundOf, cut: cutWords, plan: plan,
             recipe: SameJSON(value: recipe), attached: SameJSON(value: attached))
    }

    /// A change is about to be made that's a step of its own: what's been changed till now is the step before it.
    private func remember() { edits.record(snap) }

    private func startHistory() {
        // (a draft's parts go in as it appears, and what follows from them)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if edits.base == nil { edits.start(snap) }
        }
    }

    private func editChanged() {
        if restoring == nil, !edits.changed { edits.touched() }
    }

    private func midEdit() -> Bool {
        if barGrab != nil || typing != nil || recording || fingerHeld { return true }
        return captionScreen != .main && (editingCaption ?? editingText) != nil   // the wheel and the eyedropper: one step
    }

    private func recordEdit() { edits.record(snap) }
    private func follow(from old: [Clip], to new: [Clip]) {
        // (Undo has put what's over them where it was: followed as well, a voiceover's captions lost their hand trims)
        if let back = restoring, back == new { return }
        guard !old.isEmpty, !new.isEmpty else { return }
        let before = EditCarry(clips: old, texts: texts, sounds: sounds, pips: pips, cut: cutWords)
        let after: EditCarry = before.moved(to: new)
        texts = after.texts
        if after.sounds != sounds { sounds = after.sounds }
        if after.pips != pips { pips = after.pips }
        if after.cut != cutWords { cutWords = after.cut }
        // (reanchor ends each where the next in its layer begins: 21 Nov, "Unglazed" drawn over "turns black")
        settleLayers()
        if recipe != nil { remakeRecipe() }
    }

    private func change(_ f: ([Clip]) -> [Clip]) { remember(); withAnimation(.snappy) { clips = f(clips) } }
    private func undo() {
        if recording {
            endVoice()   // (kept: the same tap took off what it had just recorded)
            return
        }
        endVoice()
        stopGlide()
        let current: Snap = snap
        var h: EditHistory<Snap> = edits
        let last: Snap? = h.undo(from: current)
        edits = h
        if let last { restore(last) }
    }
    private func redo() {
        if recording {
            endVoice()   // (kept: the same tap took off what it had just recorded)
            return
        }
        endVoice()
        stopGlide()
        let current: Snap = snap
        var h: EditHistory<Snap> = edits
        let next: Snap? = h.redo(from: current)
        edits = h
        if let next { restore(next) }
    }
    private func restore(_ s: Snap) {
        restoring = s.clips
        restores += 1
        let turn: Int = restores
        fingerHeld = false
        let carried: Bool = s.attached != SameJSON(value: attached)
        withAnimation(.snappy) {
            clips = s.clips; soundOf = s.soundOf; look = s.look
            recipe = s.recipe.value; plan = s.plan
            layBack(s)
        }
        if carried {
            attached = s.attached.value
            attach(s.attached.value)
        }
        closeGone(s)
        // what's over them as it was with these clips: put back after follow() has moved it with the clips
        DispatchQueue.main.async { layBack(s) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard turn == restores else { return }   // (a second Undo meanwhile has its own)
            edits.absorb(snap)
            restoring = nil
        }
    }

    private func layBack(_ s: Snap) {
        sounds = s.sounds; texts = s.texts; pips = s.pips; cutWords = s.cut
    }

    /// What's picked, and its panel, let go if Undo or Redo took it away.
    private func closeGone(_ s: Snap) {
        var gone = false
        if let id = selected, !s.clips.contains(where: { (c: Clip) -> Bool in c.id == id }) { selected = nil; gone = true }
        if let id = selectedText, !s.texts.contains(where: { (t: EditText) -> Bool in t.id == id }) { selectedText = nil; gone = true }
        if let id = selectedSound, !s.sounds.contains(where: { (x: EditSound) -> Bool in x.id == id }) { selectedSound = nil; gone = true }
        if let id = selectedPip, !s.pips.contains(where: { (p: EditPip) -> Bool in p.id == id }) { selectedPip = nil; gone = true }
        if s.recipe.value == nil, panel == .recipe || panel == .recipeSteps { gone = true }
        captionScreen = .main
        movedAll = nil
        if gone { panel = nil }
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
        let home: Clip = clips[ci]
        let said: [EditText] = CaptionLayers.returned(texts, from: s, clip: home)
        let kept: [EditText] = CaptionLayers.returned(s.cut ?? [], from: s, clip: home)
        withAnimation(.snappy) {
            panel = nil; selectedSound = nil
            texts = said
            cutWords += kept
            sounds.removeAll { $0.id == id }
            clips[ci].soundOn = true
        }
    }

    private func takeOff(_ id: UUID) {
        remember()
        if let s = sounds.first(where: { (x: EditSound) -> Bool in x.id == id && x.kind == "clip" }) {
            // (tied to a sound that's gone, its captions went for good at the next trim)
            let home: Clip? = clips.first { (c: Clip) -> Bool in c.id == s.clip }
            texts = CaptionLayers.returned(texts, from: s, clip: home)
        }
        withAnimation(.snappy) {
            panel = nil; selectedSound = nil
            // a voiceover takes its captions with it, and the video's own under it come back on
            if sounds.contains(where: { (s: EditSound) -> Bool in s.id == id && s.kind == "voice" }) {
                let kept: [EditText] = CaptionLayers.removed(id, texts: texts, sounds: sounds)
                if kept != texts { setLayered(kept, sounds: sounds) }
            }
            sounds.removeAll { $0.id == id }
        }
    }

    private func seek(_ s: Double) {
        // gone somewhere else: a glide's over
        if motion.gliding {
            motion.end()
            scrubFrom = nil
            wasPlaying = nil
        }
        player.seek(to: CMTime(seconds: max(0, s), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        now = s
        followCaption(s)
    }

    /// A caption being edited, and the line moves on (played or slid) into another: that one's picked, as CapCut
    /// does, so the panel is always for the caption on screen.
    private func followCaption(_ t: Double) {
        // (not while it's being changed: the colour or size went onto the next one as the line went into it)
        if fingerHeld || captionScreen != .main { return }
        guard let id = selectedText, let cur = texts.first(where: { (x: EditText) -> Bool in x.id == id }), cur.kind == "caption" else { return }
        guard t < cur.from || t >= cur.to else { return }
        // (the next in its own layer)
        let voices: Set<UUID> = CaptionLayers.voiceIDs(sounds)
        let layer: UUID? = CaptionLayers.track(cur, voices: voices)
        let off: Bool = cur.hidden == true
        for x in texts where x.kind == "caption" && t >= x.from && t < x.to && (x.hidden == true) == off {
            if CaptionLayers.track(x, voices: voices) == layer { selectedText = x.id; return }
        }
    }

    /// The whole video as one bar, a stretch for each clip, to drag along (19 Nov: it could only be played through or
    /// jumped to a clip's start, not scrubbed as a single video can). The preview follows the finger, held still;
    /// let go, it plays on if it was playing.
    private var scrubBar: some View { Live { scrubStrip() } }

    private func scrubStrip(slim: Bool = false) -> some View {
        let tall: CGFloat = slim ? 22 : 26, room: CGFloat = slim ? 28 : 38
        let lineWide: CGFloat = slim ? 2 : 3.5, lineTall: CGFloat = slim ? 28 : 36, corner: CGFloat = slim ? 3 : 6
        return GeometryReader { g in
            let w = g.size.width, span = max(total, 0.01)
            ZStack(alignment: .leading) {
                // the clips' frames along it, as the single editor's strip shows its one clip's; the one picked lit
                let starts = ClipJoin.starts(clips)
                ZStack(alignment: .leading) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                        ClipThumb(clip: c)
                            .frame(width: max(2, w * CGFloat(c.span / span) - 2), height: tall)
                            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.black.opacity(c.id == selected || selected == nil ? 0 : 0.35)))
                            .offset(x: w * CGFloat(starts[i] / span))
                    }
                }
                .frame(width: w, height: tall, alignment: .leading).clipped()
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(.white.opacity(slim ? 0 : 0.45), lineWidth: 1))
                // the song's beats, as yellow ticks (Stage E)
                let beats: [Double] = songBeats
                ForEach(beats.indices, id: \.self) { b in
                    Rectangle().fill(Color.yellow.opacity(0.8)).frame(width: 1, height: 10)
                        .offset(x: w * CGFloat(beats[b] / span), y: slim ? 6 : 14).allowsHitTesting(false)
                }
                // where it is: yellow while a finger looks through it, as in the single editor; white as it plays
                Capsule().fill(wasPlaying != nil ? Color.yellow : Color.white).frame(width: lineWide, height: lineTall)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(x: min(max(0, w * CGFloat(now / span) - lineWide / 2), w - lineWide))
            }
            .frame(width: w, height: room)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if wasPlaying == nil { stopGlide(); wasPlaying = player.rate != 0; player.pause(); playing = false }
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
                    snapped = nil
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
        .frame(height: room)
        .onDisappear { stripGone() }
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
                if voiceRanOut(at: t) {
                    stopVoice()
                    return
                }
                now = t
                if playing != (player.rate != 0) { playing = player.rate != 0 }
                followCaption(t)
            }
            player.onSize = { frameSize = $0 }
        }
        player.update(clips: clips, soundOf: soundOf, look: look, sounds: sounds, pips: pips, swap: proxies)
        frameSize = player.frameSize
        if player.rate == 0, abs(player.currentTime().seconds - now) > 0.001 { seek(min(now, max(0, total - 0.05))) }
        if !recording { Sound.on(.moviePlayback) }   // (a 4K copy finishing switched the microphone off mid-take)
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
        let ok: Bool = await saveNow(tidy: false)
        if ok { saveWarned = false } else if !saveWarned {
            saveWarned = true
            flash("Changes aren't being saved. Check your storage before you leave the editor.")
        }
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

    /// Speed (design/editor-panels-mockup.html, 1): a quarter to four times on a ruler, the clip on the strip as long
    /// as it now lasts.
    private func speedPanel(_ i: Int) -> some View {
        let c: Clip = clips[i]
        let lasts: String = String(format: "%.1f s → %.1f s", c.duration, c.span) + ". Its sound keeps its pitch."
        let normal: Bool = abs(c.speed - 1) < 0.001
        return VStack(spacing: 0) {
            ProLead(title: "Clip \(i + 1)", sub: "") {
                ProAction(icon: "arrow.counterclockwise", name: "Reset", enabled: !normal, run: { resetSpeed(i) })
            }
            ProBody(height: 144, spacing: 4) {
                Text(Self.speedText(c.speed)).font(.system(size: 25, weight: .bold)).monospacedDigit().frame(height: 30)
                SpeedRuler(speed: c.speed, held: { (on: Bool) in editHeld(on) }, set: { (v: Double) in setSpeed(i, v) })
                Text(lasts).font(.system(size: 12)).foregroundStyle(ProInk.quiet)
            }
        }
    }

    private func setSpeed(_ i: Int, _ v: Double) {
        guard clips.indices.contains(i), clips[i].speed != v else { return }
        clips[i].speed = v
    }

    private func resetSpeed(_ i: Int) {
        remember()
        setSpeed(i, 1)
    }

    /// The frame at the line held for 2 seconds, as a clip of its own put in there (the clip split round it).
    private func freezeHere() {
        guard let i = index, let at = fileTime(i) else { return }
        let c = clips[i], into = at - c.start
        joining = true; player.pause()
        Task {
            defer { joining = false }
            guard let img = await ClipJoin.frame(c, at: at), let url = await ClipJoin.still(img, seconds: 2),
                  let still = await ClipJoin.clip(url, still: true) else { flash("Couldn't freeze that frame. Try again."); return }   // (a still has no sound)
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
        endVoice()
        SongPlayer.shared.stop()
        Sound.on(.moviePlayback)   // (Cancel, or it failing, comes back here)
        motion.end()
        finishScrub(resume: false)
        joining = true; progress = 0; player.pause()
        let edit = clips, sound = soundOf, shape = look, laid = sounds, on = pips
        let items = CaptionLayers.placed(texts, sounds: sounds), size = frameSize
        making = Task {
            guard await EditOverlays.prepare(items) else {
                // (22 Nov: made without its frames, a GIF was a yellow box in the video)
                if !Task.isCancelled { joining = false; progress = nil; making = nil; flash("A GIF didn't load. Check your connection and try again, or take it off.") }
                return
            }
            let over = EditOverlays.pieces(items, frame: size)
            let url = await ClipJoin.join(edit, soundOf: sound, look: shape, overlays: over, sounds: laid, pips: on) { p in if progress != nil { progress = p } }
            guard !Task.isCancelled else { return }
            guard let url else {
                joining = false; progress = nil; making = nil
                trouble = .video
                return
            }
            // (saved to this moment first: Back to the clips opens the draft, and autosave waits a second)
            let kept: Bool = keepsDraft ? await saveNow(tidy: false) : true
            joining = false; progress = nil; making = nil
            guard kept else { trouble = .draft; return }
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

    /// What's over the video: the overlays to drag (VideoOverlays), the eyedropper, and what a move did.
    private var overVideo: some View {
        ZStack(alignment: .top) {
            videoLayer
            if captionScreen == .dropper, let id = editingCaption ?? editingText {
                VideoDropper(engine: player, frameSize: frameSize, pick: { (hex: String) in pickedColour(id, hex) })
            } else if let m = movedAll, !full {
                movedPill(m).padding(.top, 8)
            }
        }
    }

    private var videoLayer: VideoOverlays {
        VideoOverlays(clock: clock, texts: texts, sounds: sounds, pips: pips, frameSize: frameSize,
                      selected: selectedText, selectedPip: selectedPip, playing: playing,
                      rounded: panel != nil,
                      held: { (on: Bool) in overlayHeld(on) },
                      pick: { (id: UUID) in selectText(id) },
                      pickPip: { (id: UUID) in selectPip(id) },
                      placed: { (item: EditText, moved: Bool, sized: Bool) in placedByHand(item, moved: moved, sized: sized) },
                      setPip: { (id: UUID, to: MoveKey) in movePip(id, to) })
    }

    /// The caption whose panel is open.
    private var editingCaption: UUID? {
        guard panel == .text, let id = selectedText else { return nil }
        let isCaption: Bool = texts.contains { (t: EditText) -> Bool in t.id == id && t.kind == "caption" }
        return isCaption ? id : nil
    }

    /// The text whose panel is open.
    private var editingText: UUID? {
        guard panel == .text, let id = selectedText else { return nil }
        let isText: Bool = texts.contains { (t: EditText) -> Bool in t.id == id && t.kind == "text" }
        return isText ? id : nil
    }

    private func overlayHeld(_ on: Bool) {
        if on {
            endVoice()
            stopGlide()
            captionStep()
            if player.rate != 0 { player.pause() }
            playing = false
            movedAll = nil
        }
        fingerHeld = on
    }

    private func movePip(_ id: UUID, _ to: MoveKey) {
        setPip(id) { (m: inout MoveKey) in
            m.x = to.x
            m.y = to.y
            m.size = to.size
        }
    }

    /// Let go on the video. A caption takes every caption in its layer with it (design/caption-move-mockup.html).
    private func placedByHand(_ item: EditText, moved: Bool, sized: Bool) {
        guard let mine = texts.first(where: { (t: EditText) -> Bool in t.id == item.id }) else { return }
        let put: (inout EditText) -> Void = { (t: inout EditText) in
            if moved {
                t.x = item.x
                t.y = item.y
            }
            if sized { t.size = item.size }
        }
        guard mine.kind == "caption" else {
            changeText(item.id, put)
            return
        }
        let voices: Set<UUID> = CaptionLayers.voiceIDs(sounds)
        let layer: UUID? = CaptionLayers.track(mine, voices: voices)
        var was: [UUID: Placing] = [:]
        var count = 0
        changeEveryCaption { (t: inout EditText) in
            guard CaptionLayers.track(t, voices: voices) == layer else { return }
            if was[t.id] == nil {
                was[t.id] = Placing(x: t.x, y: t.y, size: t.size, byHand: t.byHand)
                count += 1
            }
            put(&t)
            if moved && layer == nil { t.byHand = true }
        }
        guard count > 1 else { return }
        let note = MovedAll(caption: item.id, sized: sized && !moved, was: was)
        movedAll = note
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if movedAll?.id == note.id { movedAll = nil }
        }
    }

    private func movedPill(_ m: MovedAll) -> some View {
        HStack(spacing: 8) {
            Text(m.sized ? "Sized every caption" : "Moved every caption")
            Text("·").foregroundStyle(Color.black.opacity(0.4))
            Button { justThisOne(m) } label: {
                Text("Just this one").fontWeight(.bold).frame(height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.black)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.white, in: Capsule())
    }

    private func justThisOne(_ m: MovedAll) {
        remember()
        changeEveryCaption { (t: inout EditText) in
            guard t.id != m.caption, let p = m.was[t.id] else { return }
            t.x = p.x
            t.y = p.y
            t.size = p.size
            t.byHand = p.byHand
        }
        movedAll = nil
    }

    private func changeText(_ id: UUID, _ edit: (inout EditText) -> Void) {
        guard let i = texts.firstIndex(where: { (t: EditText) -> Bool in t.id == id }) else { return }
        var t: EditText = texts[i]
        edit(&t)
        if t != texts[i] { texts[i] = t }
    }

    /// Every caption, and those kept of what's trimmed off, which come back looking the same.
    private func changeEveryCaption(_ edit: (inout EditText) -> Void) {
        var all: [EditText] = texts
        for i in all.indices where all[i].kind == "caption" { edit(&all[i]) }
        texts = all
        changeKept(edit)
    }

    /// The captions kept of what's trimmed off clips and sounds.
    private func changeKept(_ edit: (inout EditText) -> Void) {
        var kept: [EditText] = cutWords
        for i in kept.indices { edit(&kept[i]) }
        if kept != cutWords { cutWords = kept }
        var laid: [EditSound] = sounds
        for k in laid.indices {
            guard var cut = laid[k].cut else { continue }
            for i in cut.indices { edit(&cut[i]) }
            laid[k].cut = cut
        }
        if laid != sounds { sounds = laid }
    }

    private func pickedColour(_ id: UUID, _ hex: String) {
        let part: CaptionPart = captionPart
        changeText(id) { (t: inout EditText) in
            if t.kind == "caption" { t.paint(part, hex: hex) } else { t.colour = hex }
        }
    }

    private func selectText(_ id: UUID) {
        selected = nil
        selectedText = id
        captionScreen = .main
        changingSticker = false
        player.pause(); playing = false
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
        case 2: remember(); pips.removeAll { $0.id == b.id }
        default: removeText(b.id)
        }
        selectedText = nil; selectedSound = nil; selectedPip = nil
    }

    /// A text, sticker or caption taken off, and what was kept of it trimmed off with it.
    private func removeText(_ id: UUID) {
        remember()
        texts.removeAll { (t: EditText) -> Bool in t.id == id }
        cutWords.removeAll { (t: EditText) -> Bool in t.id == id }
        for k in sounds.indices {
            guard let cut = sounds[k].cut else { continue }
            let left: [EditText] = cut.filter { (t: EditText) -> Bool in t.id != id }
            if left.count != cut.count { sounds[k].cut = left.isEmpty ? nil : left }
        }
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
                    if sounds.contains(where: { $0.kind == "song" }) { withAnimation(.snappy) { panel = .beats } } else { openSongs() }
                }
                action("square.grid.2x2", "Templates", on: true) { hearAlone(); templating = true }
        }
        .padding(.top, 2)
    }

    /// Everything laid over the video as bars, in rows so none covers another: drag one along, or by an end for when it
    /// starts and stops; tap it to change it. Text and stickers, then the sounds.
    private var barItems: [BarItem] {
        let key = ItemsKey(texts: texts, sounds: sounds, pips: pips)
        return keptItems.get(for: key) { makeItems() }
    }

    private func makeItems() -> [BarItem] {
        textBars
            + sounds.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: Self.soundMark($0.kind) + $0.name, colour: Self.soundColour($0.kind), kind: 1, lane: $0.lane) }
            + pips.map { BarItem(id: $0.id, from: $0.from, to: $0.to, label: "▣ Overlay" + ($0.keys.isEmpty ? "" : " · ◆"), colour: Color(red: 0.36, green: 0.82, blue: 0.56), kind: 2, lane: $0.lane) }
    }

    /// The texts' bars: a caption switched off greyed.
    private var textBars: [BarItem] {
        texts.map { (t: EditText) -> BarItem in
            let off: Bool = t.hidden == true
            let colour: Color = off ? Self.offBar : t.barColour
            return BarItem(id: t.id, from: t.from, to: t.to, label: t.barLabel, colour: colour, kind: 0, lane: t.lane, off: off)
        }
    }
    private static let offBar = Color(red: 0.2, green: 0.25, blue: 0.28)

    /// The bars in rows: one put on a row (held and dragged there) is on it; the rest in rows of their own kind where
    /// they don't cover another, as before. Empty rows close up.
    private var barRows: [[BarItem]] {
        let key = RowsKey(items: ItemsKey(texts: texts, sounds: sounds, pips: pips), held: heldRows)
        return keptRows.get(for: key) { makeRows() }
    }

    private func makeRows() -> [[BarItem]] {
        let items: [BarItem] = barItems
        var rows: [[BarItem]] = []
        // (while one's held, each keeps the row it had: packed again as it moved, the bar under the finger jumped
        // rows, so was a new view each time and lost the finger, 22 Nov)
        let held = heldRows
        for t in items {
            guard let lane = held[t.id] ?? t.lane else { continue }
            let l = max(0, lane)
            while rows.count <= l { rows.append([]) }
            rows[l].append(t)
        }
        rows = rows.filter { !$0.isEmpty }.map { $0.sorted { $0.from < $1.from } }
        for t in items.filter({ held[$0.id] == nil && $0.lane == nil }).sorted(by: { $0.from < $1.from }) {
            // (the chosen rows too: kept out of them, a caption made after a bar had been moved got a row to itself)
            let free = rows.indices.first { (r: Int) -> Bool in joins(t, rows[r]) }
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

    /// Whether two bars are over each other: more than the tenth of a second that a caption is always given, which
    /// can run a very short one into the next.
    private static func covers(_ a: BarItem, _ b: BarItem) -> Bool { min(a.to, b.to) - max(a.from, b.from) > 0.12 }

    /// Whether a bar can be on a row as it is: only with its own kind (sound with sound, as CapCut's tracks) and
    /// covering none there.
    private func joins(_ item: BarItem, _ row: [BarItem]) -> Bool {
        for o in row where o.id != item.id {
            if o.kind != item.kind || o.off != item.off { return false }
            if Self.covers(o, item) { return false }
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
        let to: Int = min(max(0, target), rows.count)
        let fits: Bool = to < shown.count && joins(item, shown[to])
        rows = TimelineRows.moved(id, from: from, to: to, rows: rows, fits: fits)
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


    /// Where a bar's edge at `t` is held: the nearest within `reach` of a clip's start or end, another bar's start or end,
    /// or the line.
    private func snapTarget(_ t: Double, reach: Double, except: UUID) -> Double? {
        var captions: Set<UUID> = []
        for x in texts where x.kind == "caption" { captions.insert(x.id) }
        var bars: [(from: Double, to: Double, caption: Bool, off: Bool)] = []
        for b in barItems where b.id != except { bars.append((from: b.from, to: b.to, caption: captions.contains(b.id), off: b.off)) }
        let fixed: [Double] = ClipJoin.starts(clips) + [total, now]
        let targets: [Double] = TimelineRows.snapTargets(fixed: fixed, bars: bars, movingCaption: captions.contains(except))
        guard let best = targets.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= reach else { return nil }
        return best
    }

    /// The pause in what's said that a trimmed sound's end is by.
    private func soundPause(_ g: BarGrab, dt: Double, reach: Double) -> (dt: Double, at: Double, file: Double)? {
        guard let s = sounds.first(where: { (x: EditSound) -> Bool in x.id == g.id }), s.kind == "voice" || s.kind == "clip" else { return nil }
        guard let url = s.url, let file = waves.files[url] else { return nil }
        let edge: Double = g.mode == 1 ? g.from : g.to
        let at: Double = g.start + (edge + dt - g.from) * s.speed
        guard let p = WaveMath.pause(file.pauses, near: at, reach: min(reach, 0.25) * s.speed) else { return nil }
        let video: Double = g.from + (p - g.start) / s.speed
        guard video >= 0 else { return nil }
        // (as far as dragSound lets it)
        let moved: Double = video - edge, length: Double = g.to - g.from
        if g.mode == 1 {
            guard moved >= max(-g.start / s.speed, -g.from) - 0.001, moved <= length - 0.3 else { return nil }
        } else {
            let span: Double = max(total, 0.01)
            let whole: Double = s.full > 0 ? s.full : g.start + length * s.speed
            let room: Double = s.loopStart != nil ? span - g.from : min((whole - g.start) / s.speed, span - g.from)
            guard length + moved >= 0.3, length + moved <= room + 0.001 else { return nil }
        }
        return (moved, video, p)
    }

    /// The pauses along a sound as it's trimmed, and the words either side of the one it's held on.
    @ViewBuilder private func barPauses(_ item: BarItem, row: Int, w: CGFloat, span: Double) -> some View {
        if let g = barGrab, g.id == item.id, g.mode != 0, item.kind == 1,
           let s = sounds.first(where: { (x: EditSound) -> Bool in x.id == g.id }), s.kind == "voice" || s.kind == "clip" {
            pauseGuide(s, g, row: row, w: w, span: span)
        }
    }

    private func pauseGuide(_ s: EditSound, _ g: BarGrab, row: Int, w: CGFloat, span: Double) -> some View {
        let pauses: [Double] = s.url.flatMap { (u: URL) -> [Double]? in waves.files[u]?.pauses } ?? []
        let place: (Double) -> CGFloat = { (p: Double) -> CGFloat in w * CGFloat((g.from + (p - g.start) / s.speed) / span) }
        let shown: [CGFloat] = pauses.map(place).filter { (x: CGFloat) -> Bool in x >= 0 && x <= w }
        let held: CGFloat? = pauseHeld.map(place)
        let top: CGFloat = CGFloat(row) * (Self.laneHeight + 3)
        return ZStack(alignment: .topLeading) {
            PauseMarks(places: shown, held: held, height: Self.laneHeight + 16)
                .frame(width: max(w, 1), height: Self.laneHeight + 16, alignment: .topLeading)
                .offset(y: top - 8)
            if let held, let p = pauseHeld {
                // (up over the clips' frames, off the captions)
                pauseBubble(s.id, files: saidIn(s), at: p, seconds: s.length)
                    .frame(width: 280)
                    .offset(x: held - 140, y: -(Self.clipRow - 2))
            }
        }
        .allowsHitTesting(false)
    }

    private func pauseBubble(_ id: UUID, files: Set<String>, at p: Double, seconds: Double) -> some View {
        let sides: (before: String, after: String) = WaveMath.between(wordsSaid(id, files: files), p)
        return PauseBubble(before: sides.before, after: sides.after, seconds: seconds)
    }

    /// The words said in a clip or sound, by when in its file, those trimmed off it too.
    /// The files a sound's words are known by: a separated clip sound's are the clip's as well.
    private func saidIn(_ s: EditSound) -> Set<String> {
        guard s.kind == "clip", let c = clips.first(where: { (x: Clip) -> Bool in x.id == s.clip }) else { return [] }
        return [c.source.lastPathComponent]
    }

    private func wordsSaid(_ id: UUID, files: Set<String>) -> [(text: String, at: Double)] {
        // (captions just made aren't tied to their clips till the clips change)
        let shown: [EditText] = texts.filter { (t: EditText) -> Bool in t.kind == "caption" }
        var all: [EditText] = EditOverlays.anchor(shown, clips: clips)
        all += cutWords
        for s in sounds { all += s.cut ?? [] }
        var out: [(text: String, at: Double)] = []
        for t in all {
            for word in t.words ?? [] {
                guard let at = word.src else { continue }
                let inFile: Bool = word.file.map { (f: String) -> Bool in files.contains(f) } ?? false
                if word.clip == id || inFile { out.append((text: word.text, at: at)) }
            }
        }
        return out
    }

    /// `onTimeline`: there the line stays put while a bar's dragged (else the timeline slides under the finger), and
    /// goes to the bar after.
    private func bar(_ item: BarItem, w: CGFloat, span: Double, onTimeline: Bool = false, among row: [BarItem] = []) -> some View {
        let x0: CGFloat = w * CGFloat(min(item.from, span) / span)
        let on: Bool = item.id == selectedText || item.id == selectedSound || item.id == selectedPip
        // (on the timeline a slim tag, design/pro-ui)
        let h: CGFloat = onTimeline ? Self.laneHeight : 18, up = lifted == item.id
        // picked on the timeline, its frame is the outline, and its ends are square against that
        let framed: Bool = onTimeline && on && lifted == nil && selected == nil
        let width: CGFloat = Self.drawnWidth(item, among: row, w: w, span: span, picked: framed)
        let corner: CGFloat = framed ? 0 : (onTimeline ? 7 : 5)
        let outline: Color = on && !framed ? Color.white : Color.clear
        let ink: Color = item.off ? Color.white.opacity(0.5) : Color.black.opacity(0.82)
        return barFace(item, width: width, height: h, ink: ink)
            .background(item.colour.opacity(onTimeline && !up ? 0.88 : 1), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(outline, lineWidth: 1.5))
            .contentShape(Rectangle())
            // held, it lifts (as CapCut's do): solid, a little bigger, a shadow under it, in the row it would go on
            // (22 Nov: see-through and loose under the finger, "doesn't feel as smooth as CapCut")
            .modifier(BarLift(up: up, pressing: holdingBar(item.id)))
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

    /// What's in a bar: a sound's wave and its name, anything else's name.
    @ViewBuilder private func barFace(_ item: BarItem, width: CGFloat, height: CGFloat, ink: Color) -> some View {
        if item.kind == 1, let s = sounds.first(where: { (x: EditSound) -> Bool in x.id == item.id }) {
            soundFace(s, label: item.label, width: width, height: height)
        } else {
            Text(item.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).foregroundStyle(ink)
                .padding(.horizontal, 8).frame(width: width, height: height, alignment: .leading)
        }
    }

    private func soundFace(_ s: EditSound, label: String, width: CGFloat, height: CGFloat) -> some View {
        let url: URL? = s.url
        let file: WaveFile? = url.flatMap { (u: URL) -> WaveFile? in waves.files[u] }
        let corner = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return SoundBarWave(sound: s, file: file, width: width, height: height, pps: perSecond, ink: Self.waveInk(s.kind), clock: clock)
            .clipShape(corner)
            .overlay(alignment: .topLeading) {
                if width > 24 { PinnedName(name: label, width: width) }
            }
            .task(id: url) {
                if let url { await waves.load(url) }
            }
    }

    private static func waveInk(_ kind: String) -> Color {
        switch kind {
        case "voice": return Color(red: 0.43, green: 0.08, blue: 0.125)
        case "song": return Color(red: 0.25, green: 0.125, blue: 0.435)
        case "clip": return Color(red: 0.06, green: 0.27, blue: 0.36)
        default: return Color(red: 0.06, green: 0.3, blue: 0.3)
        }
    }

    /// Whether a finger's holding still on this bar, on its way to lifting it.
    private func holdingBar(_ id: UUID) -> Bool { pressed == id && !pressMoved && lifted == nil && barGrab == nil }

    /// A finger on a bar, moving (kept out of bar()'s chain: the compiler timed out on a long one, 1.4.21).
    private func barChanged(_ v: DragGesture.Value, _ item: BarItem, x0: CGFloat, width: CGFloat, endsTrim: Bool, w: CGFloat, span: Double, rowHeight: CGFloat) {
        let dist = hypot(v.translation.width, v.translation.height)
        if pressed != item.id {
            pressed = item.id; pressMoved = false; lifted = nil
            pressCount += 1
            let press = pressCount   // (a tap's hold, still counting, mustn't lift the press after it)
            Task { @MainActor in
                // (22 Nov: 300 was "a little long", 225 "could be quicker still")
                try? await Task.sleep(for: .milliseconds(170))
                guard press == pressCount, pressed == item.id, !pressMoved, barGrab == nil, scrubFrom == nil, !handleDown, !motion.justStopped else { return }
                holdRows()
                lifted = item.id
                player.pause(); playing = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        if dist > TimelineRows.dragStarts, lifted == nil, barGrab == nil { pressMoved = true }
        if barGrab == nil {
            // by its ends once it's picked, or anywhere once it's lifted to move it
            let at = v.startLocation.x - x0   // (where on the bar: it hasn't moved yet)
            let mode = lifted == item.id ? 0 : (at < 12 ? 1 : (at > width - 12 ? 2 : 0))
            // (lifted isn't moved: caught as it lifted, a long click pulled it to the nearest edge, 22 Nov)
            guard dist >= TimelineRows.dragStarts, lifted == item.id || (mode != 0 && endsTrim) else { return }
            grabBar(item, mode: mode)
        }
        // lifted: up or down a row at a time, into the row it would go on (the empty rail under the last too)
        if lifted == item.id, barGrab != nil, let here = rowOf(item.id) {
            let want: Int = here + Int((v.translation.height / rowHeight).rounded())
            let count: Int = barRows.count
            let last: Int = canAddRow ? count : count - 1
            let to: Int = min(max(0, want), last)
            // pulled down for a new row when it has one to itself at the bottom already: said when it's let go
            pulledPast = want > last
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
        // held on a clip's start or end, another bar's, or the line, when it comes within 5 points of
        // one, with a tap; anywhere else it goes where the finger puts it (21 Nov: the owner, "snap to
        // the in or outs or where the cursor is")
        let reach = Double(TimelineRows.snapReach / max(w, 1)) * span
        let edges = g.mode == 2 ? [g.to] : (g.mode == 1 ? [g.from] : [g.from, g.to])
        var held: (dt: Double, at: Double)?
        for e in edges {
            if let at = snapTarget(e + dt, reach: reach, except: g.id), held == nil || abs(at - e - dt) < abs(held!.dt - dt) {
                held = (at - e, at)
            }
        }
        var pause: Double?
        if item.kind == 1, g.mode != 0, let near = soundPause(g, dt: dt, reach: reach * 1.4) {
            let better: Bool = held.map { (h: (dt: Double, at: Double)) -> Bool in abs(near.dt - dt) <= abs(h.dt - dt) } ?? true
            if better {
                held = (near.dt, near.at)
                pause = near.file
            }
        }
        if pauseHeld != pause { pauseHeld = pause }
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
        // a tap (not moved, however long it was down): it's picked. On the timeline, only picked: the timeline stays, with its trim
        // frame, and the row under it is its tools (CapCut's, 21 Nov: the panel opened at once and hid the timeline
        // the bar was on, so its ends couldn't be trimmed nor it held there). In a panel's bars, its panel, as before.
        if barGrab == nil, !motion.justStopped, hypot(v.translation.width, v.translation.height) < 6 {
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
            let covers = barRows[here].contains { (o: BarItem) -> Bool in o.id != moved.id && Self.covers(o, moved) }
            // onto the row it was dragged to; moved over another on its own row, a row of its own beside it
            if let d = dropRow { dropBar(item.id, on: d) } else if covers { dropBar(item.id, on: here) }
            else if pulledPast {
                // (22 Nov, "can't go to a new line?": it was offered one, and the row it left closed up behind it)
                flash(barRows[here].count == 1 ? "It's already on a row of its own." : "\(TimelineRows.most) rows is the most the timeline shows.")
            }
        }
        pulledPast = false
        dropRow = nil; liftDY = 0; heldRows = [:]
        pressed = nil; pressMoved = false; lifted = nil
        // (the line left where it was: 21 Nov, it jumped to the bar's start when it was let go)
        let changed = barGrab != nil
        barSnap = nil
        pauseHeld = nil
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
            var s: EditSound = sounds[i]   // (all three at once: one by one, its end moved between them)
            s.from = g.from + d; s.start = g.start + d * r; s.length = length - d
            sounds[i] = s
        case 2:
            var s: EditSound = sounds[i]
            let most: Double = s.loopStart != nil ? span - g.from : min((whole - g.start) / r, span - g.from)
            s.length = max(0.3, min(length + dt, most))
            // a song drawn out to the end stays there (one from before this too)
            if s.kind == "song" {
                let reaches: Bool = s.to >= span - 0.05
                s.toEnd = reaches ? true : nil
                if reaches, s.fadeOut == nil { s.fadeOut = 1.2 }
            }
            sounds[i] = s
        default:
            var s: EditSound = sounds[i]
            s.from = min(max(0, g.from + dt), max(0, span - 0.3))
            if s.toEnd == true { s.length = max(0.3, span - s.from) }
            sounds[i] = s
        }
        if follow { seek(g.mode == 2 ? max(0, sounds[i].to - 0.05) : sounds[i].from) }
    }

    // MARK: Stage C: voice and sound

    private func selectSound(_ id: UUID) {
        selected = nil; selectedText = nil
        selectedSound = id
        let picked: EditSound? = sounds.first { (s: EditSound) -> Bool in s.id == id }
        if let picked { seek(picked.from) }
        // (music has the one panel: its beats are there too)
        let open: Panel = picked?.kind == "song" ? .beats : .soundItem
        withAnimation(.snappy) { panel = open }
    }

    /// Voiceover: tap to start and stop, or hold to talk, from the line while the video plays (its sound off, so the
    /// microphone hears only you); it lands as a bar.
    private var voicePanel: some View {
        VStack(spacing: 0) {
            Live {
                ProLead(title: recording ? "Recording" : "From \(Self.code(now))",
                        sub: recording ? "from \(Self.code(recordFrom))" : "") {
                    if recording { RecordTimer(began: recordBegan) } else { clearVoiceSwitch }
                }
            }
            ProBody(height: 144, spacing: 6) {
                if recording { LiveMeter(meter: recorder.meter) } else { countdownPick }
                RecordButton(recording: recording, count: count, pressed: { voicePressed() }, released: { (seconds: Double?) in voiceReleased(after: seconds) })
                Text(voiceHint).font(.system(size: 12)).foregroundStyle(ProInk.quiet).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        // (asked as it opens: asked at the first tap, the question itself called that take off)
        .task { _ = await VoiceRecorder.allowed() }
    }

    private var voiceHint: String {
        if count != nil { return "Tap to cancel" }
        guard recording else { return "Tap to start, or hold to talk" }
        let how: String = press.phase == .going ? "Tap to stop." : "Let go to stop."
        return how + " The clips get quieter while you talk."
    }

    private var countdownPick: some View {
        HStack(spacing: 14) {
            Text("Countdown").font(.system(size: 11)).foregroundStyle(ProInk.quiet)
            countdownChoice("Off", on: false)
            countdownChoice("3 s", on: true)
        }
        .frame(height: 24)
    }

    private func countdownChoice(_ name: String, on: Bool) -> some View {
        let here: Bool = countdown == on
        return Button {
            guard press.phase == .idle else { return }
            countdown = on
        } label: {
            Text(name).font(.system(size: 13, weight: here ? .semibold : .regular))
                .foregroundStyle(here ? Color.white : ProInk.quiet)
                .frame(minWidth: 30, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func voicePressed() {
        var p: VoicePress = press
        let act: VoicePress.Act = p.pressed(countdown: countdown)
        press = p
        voiceAct(act)
        guard p.phase == .down else { return }
        pressTask?.cancel()
        pressTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(VoicePress.hold))
            guard !Task.isCancelled else { return }
            var held: VoicePress = press
            let next: VoicePress.Act = held.heldLong()
            press = held
            voiceAct(next)
        }
    }

    private func voiceReleased(after seconds: Double?) {
        var p: VoicePress = press
        let act: VoicePress.Act = p.released(after: seconds)
        press = p
        // (the hold's timing over; a countdown just begun times itself)
        if act != .count, p.phase != .counting {
            pressTask?.cancel()
            pressTask = nil
        }
        voiceAct(act)
    }

    private func voiceAct(_ act: VoicePress.Act) {
        switch act {
        case .none:
            break
        case .start:
            count = nil
            startVoice()
        case .count:
            countDown()
        case .stopCount:
            pressTask?.cancel()
            pressTask = nil
            count = nil
        case .stop:
            stopVoice()
        }
    }

    private func countDown() {
        stopGlide()
        hearAlone()
        pressTask?.cancel()
        pressTask = Task { @MainActor in
            for n in [3, 2, 1] {
                count = n
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            var p: VoicePress = press
            let act: VoicePress.Act = p.counted()
            press = p
            voiceAct(act)
        }
    }

    /// Anything else done: the countdown's off, and what's recorded is kept.
    private func endVoice() {
        guard recording || holding || count != nil || press.phase != .idle else { return }
        stopVoice()
    }

    /// Recording, and played to the end of the video (it goes round again there): stopped.
    private func voiceRanOut(at t: Double) -> Bool {
        guard recording else { return false }
        return t < recordFrom - 0.2 || t >= total - 0.07
    }

    private var clearVoiceSwitch: some View {
        HStack(spacing: 2) {
            Text("Clear voice").font(.system(size: 11)).foregroundStyle(ProInk.soft)
            Toggle("Clear voice (less background noise)", isOn: $clearVoice).labelsHidden()
                .tint(Color(red: 0.19, green: 0.82, blue: 0.35))
                .scaleEffect(0.72).frame(width: 44)
        }
    }


    private func startVoice() {
        holding = true
        stopGlide()
        hearAlone()
        Task {
            guard await VoiceRecorder.allowed() else {
                holding = false
                press.reset()
                flash("Voiceovers need the microphone: allow it in Settings › Cheat Days.")
                return
            }
            // (nor once the editor's closed)
            guard holding, !recording, player.onTime != nil else { return }
            // (a finger still on the strip would have moved it on under the take)
            finishScrub(resume: false)
            wasPlaying = nil
            guard total - now > 0.35 else {
                holding = false
                press.reset()
                flash("Move the line back from the end to record there.")
                return
            }
            do {
                recordFrom = now
                try recorder.start(clear: clearVoice)
                recorder.broke = { endVoice() }
                recordBegan = Date()
                recording = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                player.isMuted = true
                player.loops = false
                player.play(); playing = true
            } catch {
                _ = recorder.stop()
                Sound.on(.moviePlayback)
                holding = false
                press.reset()
                flash("Couldn't start recording.")
            }
        }
    }

    private func stopVoice() {
        holding = false
        pressTask?.cancel()
        pressTask = nil
        count = nil
        press.reset()
        guard recording else { return }
        recording = false
        player.loops = true
        player.pause(); player.isMuted = false
        playing = false
        if let (url, length) = recorder.stop() {
            remember()
            let n = sounds.filter { $0.kind == "voice" }.count + 1
            let take = EditSound(kind: "voice", name: "Voice \(n)", file: url, from: recordFrom, length: max(0.3, min(length, total - recordFrom)), full: length)
            sounds.append(take)
            selectedSound = take.id
        }
        Sound.on(.moviePlayback)
    }

    /// A few short sounds: tap one to hear it, + to drop it in at the line.
    private var effectsPanel: some View {
        VStack(spacing: 0) {
            ProLead(title: "Goes in at \(Self.code(now))", sub: "tap one to hear it") { EmptyView() }
            ProBody(height: 144) {
                EffectsBoard(hearing: { hearAlone() }, add: { (name: String) in addEffect(name) })
            }
        }
    }


    private func addEffect(_ name: String) {
        let length: Double = SoundEffects.length(name)
        remember()
        sounds.append(EditSound(kind: "effect", name: name, from: now, length: max(0.05, min(length, total - now)), full: length))
        UISelectionFeedbackGenerator().selectionChanged()
        flash("\(name) added at \(Self.code(now)).")
    }

    /// A sound's bar picked (a voiceover, an effect, or a clip's separated sound): the clip Sound panel's tools
    /// (21 Nov; design/separate-audio-mockup.html, 4): Volume with keyframes, Fade, Put back, Take off.
    private func soundItemPanel(_ k: Int) -> some View {
        let s: EditSound = sounds[k]
        return VStack(spacing: 0) {
            ProLead(title: s.name, sub: "") { soundItemActions(s) }
            soundTabs(beats: false)
            ProBody {
                if soundTool == .fade { barFadePanel(k) } else { barVolumePanel(k) }
            }
        }
    }

    @ViewBuilder private func soundItemActions(_ s: EditSound) -> some View {
        if s.kind == "voice" || s.kind == "clip" {
            ProAction(icon: "captions.bubble", name: "Caption this", run: { makeCaptions(.sound(s.id)) })
        }
        if s.kind == "clip" && clips.contains(where: { (c: Clip) -> Bool in c.id == s.clip }) {
            ProAction(icon: "arrow.up.to.line", name: "Put back", run: { putBack(s.id) })
        }
        ProDelete(name: "Take off", run: { takeOff(s.id) })
    }

    /// Where the line is in a sound's own seconds, if the line is over its bar.
    private func barFileTime(_ k: Int) -> Double? {
        let s = sounds[k]
        guard now >= s.from - 0.01, now <= s.to + 0.01 else { return nil }
        return s.fileTime(min(max(now, s.from), s.to))
    }

    /// A bar's volume: as a clip's (volumePanel), the number and slider the level at the line, the diamond a keyframe.
    private func barVolumePanel(_ k: Int) -> some View {
        let s: EditSound = sounds[k]
        let at: Double? = barFileTime(k)
        let keys: [VolumeKey] = s.keys ?? []
        let near: Int? = at.flatMap { (t: Double) -> Int? in keys.firstIndex { (key: VolumeKey) -> Bool in abs(key.at - t) < 0.15 } }
        let shown: Float = keys.isEmpty ? s.volume : s.keyLevel(at: at ?? s.start)
        let span: Double = max(s.length, 0.01)
        let marks: [StripKey] = keys.map { (key: VolumeKey) -> StripKey in
            StripKey(at: (s.videoTime(key.at) - s.from) / span, level: Double(key.volume))
        }
        let line: Double? = at == nil ? nil : (now - s.from) / span
        let colour: Color = Self.soundColour(s.kind)
        return VStack(spacing: 14) {
            volumeSlide(Double(shown), set: { (v: Double) in setBarVolume(k, Float(v)) })
            HStack(spacing: 12) {
                keyAction(near != nil, enabled: at != nil, run: { toggleBarKey(k) })
                SoundWaveLoader(sound: s) { (wave: [Float]) in
                    KeyframeStrip(levels: wave, colour: colour, keys: marks, line: line,
                                  scrub: { (f: Double) in stripSeek(s.from + f * span) })
                }
            }
        }
    }

    private func toggleBarKey(_ k: Int) {
        guard sounds.indices.contains(k), let at = barFileTime(k) else { return }
        let s: EditSound = sounds[k]
        var all: [VolumeKey] = s.keys ?? []
        remember()
        if let near = all.firstIndex(where: { (key: VolumeKey) -> Bool in abs(key.at - at) < 0.15 }) {
            all.remove(at: near)
        } else {
            let level: Float = all.isEmpty ? s.volume : s.keyLevel(at: at)
            all.append(VolumeKey(at: at, volume: level))
        }
        sounds[k].keys = all.isEmpty ? nil : all
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
        let s: EditSound = sounds[k]
        let most: Double = max(0.1, min(3, s.length / 2))
        let span: Double = max(s.length, 0.01)
        let colour: Color = Self.soundColour(s.kind)
        return VStack(spacing: 4) {
            SoundWaveLoader(sound: s) { (wave: [Float]) in
                FadeWave(levels: wave, colour: colour, fadeIn: (s.fadeIn ?? 0) / span, fadeOut: (s.fadeOut ?? 0) / span)
            }
            fadeRow("Fade in", value: barFade(k, \.fadeIn, most: most), most: most)
            fadeRow("Fade out", value: barFade(k, \.fadeOut, most: most), most: most)
        }
    }

    private func barFade(_ k: Int, _ key: WritableKeyPath<EditSound, Double?>, most: Double) -> Binding<Double> {
        Binding<Double>(get: { () -> Double in
            guard sounds.indices.contains(k) else { return 0 }
            return min(sounds[k][keyPath: key] ?? 0, most)
        }, set: { (v: Double) in
            guard sounds.indices.contains(k) else { return }
            sounds[k][keyPath: key] = v < 0.05 ? nil : v
        })
    }

    /// A clip's sound made clearer (Clarity), or back as it was.
    private func clearer(_ i: Int) {
        guard clips.indices.contains(i) else { return }
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
        return s.beatTimes(until: total)
    }

    /// A song from the app's music under the whole edit (one at a time), its beats found.
    private func addSong(_ s: Song) async {
        joining = true
        defer { joining = false }
        guard let mix = await SongMix.make(s, song: 1, clip: 1) else { flash("Couldn't get that song. Check your connection."); return }
        let beats = await Beats.find(mix.file, from: mix.from, length: mix.span)
        remember()
        sounds.removeAll { $0.kind == "song" }
        var song = EditSound(kind: "song", name: s.title, file: mix.file, from: 0, start: mix.from, length: max(0.5, total),
                             full: mix.from + mix.span, beats: beats)
        Self.runToEnd(&song, loopFrom: mix.from)
        sounds.append(song)
        withAnimation(.snappy) { panel = .beats }
    }

    /// A song to the end of the edit, round again as often as that takes, fading out there.
    private static func runToEnd(_ song: inout EditSound, loopFrom: Double) {
        song.loopFrom = loopFrom
        song.toEnd = true
        song.fadeOut = min(1.2, song.length / 4)
    }

    /// Music: the song, its volume with keyframes, its fades, and its beats with the clips cut to land on them.
    @ViewBuilder private var beatsPanel: some View {
        if let k = sounds.firstIndex(where: { (s: EditSound) -> Bool in s.kind == "song" }) {
            musicPanel(k)
        } else {
            ProLead(title: "No song", sub: "") {
                ProAction(icon: "plus", name: "Add a song", run: { openSongs() })
            }
        }
    }

    private func musicPanel(_ k: Int) -> some View {
        let s: EditSound = sounds[k]
        return VStack(spacing: 0) {
            ProLead(title: s.name, sub: s.toEnd == true ? "to the end" : "") {
                ProAction(icon: "arrow.left.arrow.right", name: "Change", run: { openSongs() })
                ProDelete(name: "Take off", run: { takeOff(s.id) })
            }
            soundTabs(beats: true)
            ProBody {
                switch soundTool {
                case .volume: barVolumePanel(k)
                case .fade: barFadePanel(k)
                case .beats: beatCuts(s)
                }
            }
        }
    }

    @ViewBuilder private func beatCuts(_ s: EditSound) -> some View {
        let found: [Double] = songBeats
        let span: Double = max(s.length, 0.01)
        let marks: [Double] = found.map { (b: Double) -> Double in (b - s.from) / span }
        if found.count > 2 {
            SoundWaveLoader(sound: s) { (wave: [Float]) in
                BeatStrip(levels: wave, beats: marks, every: beatEvery)
            }
            HStack(spacing: 8) {
                ProPick(title: "", options: Self.beatOptions, value: String(beatEvery), pick: { (v: String) in beatEvery = Int(v) ?? 2 })
                cutButton
            }
        } else {
            ProHint(words: "No steady beat found in this song to cut to.")
        }
    }

    private static let beatOptions: [ProOption] = [ProOption(id: "1", name: "Every beat"), ProOption(id: "2", name: "2 beats"),
                                                   ProOption(id: "4", name: "4 beats")]

    private var cutButton: some View {
        Button { cutToBeats(every: beatEvery) } label: {
            HStack(spacing: 6) {
                Image(systemName: "scissors")
                Text("Cut clips")
            }
            .font(.system(size: 13)).foregroundStyle(Color.white)
            .padding(.horizontal, 9).frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(white: 0.4), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
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

    private var templatesScreen: TemplateMaker {
        let carry = EditCarry(clips: clips, texts: texts, sounds: sounds, pips: pips, cut: cutWords, recipe: recipe, plan: plan)
        return TemplateMaker(clips: clips, editLook: look, proxies: proxies, carry: carry,
                             make: { (t: EditTemplate, cut: TemplateCut, meal: JSON?) in makeTemplate(t, cut, meal) },
                             close: { templating = false })
    }

    /// Make it: the very cut that played, with what it kept of the edit.
    private func makeTemplate(_ t: EditTemplate, _ cut: TemplateCut, _ meal: JSON?) {
        templating = false
        guard !cut.clips.isEmpty else { return }
        player.pause(); playing = false
        remember()
        var over: [EditText] = cut.words
        // (the preview's labels have ids of the preview's)
        for i in over.indices where over[i].part == "template" { over[i].id = UUID() }
        let made: [EditText] = over
        // (already with its clips: follow() leaves them be, as it does for an Undo)
        restoring = cut.clips
        restores += 1
        let turn: Int = restores
        edits.touched()
        selected = nil; selectedText = nil; selectedSound = nil; selectedPip = nil
        withAnimation(.snappy) {
            clips = cut.clips
            // (left on, a clip that wasn't picked silenced every clip in the finished video)
            soundOf = nil
            texts = made; sounds = cut.sounds; pips = cut.pips; cutWords = cut.cutWords
            panel = nil
        }
        DispatchQueue.main.async {
            guard turn == restores else { return }
            texts = made; sounds = cut.sounds; pips = cut.pips; cutWords = cut.cutWords
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard turn == restores else { return }
            restoring = nil
        }
        if let meal { attached = meal; attach(meal) }
        let music: Bool = cut.sounds.contains { (s: EditSound) -> Bool in s.kind == "song" }
        if music { flash("\(t.name): made. Change anything you like.") }
        else { flash("\(t.name): made, cut half a second a beat (the song couldn't be fetched). Change anything you like.") }
        seek(0); player.play(); playing = true
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
        remember()
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

    /// An overlay picked: its size and opacity, a keyframe at the line, or taken off.
    private func pipPanel(_ k: Int) -> some View {
        let p: EditPip = pips[k]
        let m: MoveKey = p.place(at: now)
        let at: Double = now - p.from
        let here: Bool = p.keys.contains { (key: MoveKey) -> Bool in abs(key.at - at) < 0.12 }
        let inside: Bool = now >= p.from && now < p.to
        let sub: String = p.keys.isEmpty ? "" : "\(p.keys.count) keyframe\(p.keys.count == 1 ? "" : "s")"
        return VStack(spacing: 0) {
            ProLead(title: "Overlay", sub: sub) {
                ProAction(icon: here ? "diamond.fill" : "diamond", name: here ? "Remove" : "Keyframe", on: here,
                          enabled: inside, lit: ProInk.key, run: { togglePipKey(p.id) })
                ProDelete(name: "Take it off", run: { removePip(p.id) })
            }
            ProBody(height: 144, spacing: 14) {
                ProSlide(name: "Size", value: m.size, range: 0.12...1, shown: ProSlide.percent(m.size),
                         held: { (on: Bool) in editHeld(on) },
                         set: { (v: Double) in setPip(p.id) { (key: inout MoveKey) in key.size = v } })
                ProSlide(name: "Opacity", value: m.opacity, range: 0.1...1, shown: ProSlide.percent(m.opacity),
                         held: { (on: Bool) in editHeld(on) },
                         set: { (v: Double) in setPip(p.id) { (key: inout MoveKey) in key.opacity = v } })
                ProHint(words: "Drag it on the video to move it, or pinch it to size it.")
            }
        }
    }

    private func togglePipKey(_ id: UUID) {
        guard let k = pips.firstIndex(where: { (p: EditPip) -> Bool in p.id == id }) else { return }
        let p: EditPip = pips[k]
        guard now >= p.from, now < p.to else { return }
        let at: Double = now - p.from
        remember()
        if let near = p.keys.firstIndex(where: { (key: MoveKey) -> Bool in abs(key.at - at) < 0.12 }) {
            pips[k].keys.remove(at: near)
        } else {
            var key: MoveKey = p.place(at: now)
            key.at = at
            pips[k].keys.append(key)
        }
    }

    private func removePip(_ id: UUID) {
        remember()
        withAnimation(.snappy) { panel = nil; selectedPip = nil }
        pips.removeAll { (p: EditPip) -> Bool in p.id == id }
    }

    /// A clip's movement: a slow zoom or drift from start to end, or its own zoom keyframed at the line.
    private func motionPanel(_ i: Int) -> some View {
        let c: Clip = clips[i]
        let at: Double = now - startOf(i)
        let inside: Bool = at >= -0.01 && at <= c.span + 0.01
        let here: Bool = c.moves.contains { (k: MoveKey) -> Bool in abs(k.at - at) < 0.12 }
        let zoom: Double = MoveKey.value(c.moves, at: at, base: MoveKey(at: 0)).size
        let sub: String = c.moves.isEmpty ? "" : "\(c.moves.count) keyframe\(c.moves.count == 1 ? "" : "s")"
        return VStack(spacing: 0) {
            ProLead(title: "Clip \(i + 1)", sub: sub) {
                ProAction(icon: here ? "diamond.fill" : "diamond", name: here ? "Remove" : "Keyframe", on: here,
                          enabled: inside, lit: ProInk.key, run: { toggleMoveKey(i) })
            }
            ProBody(height: 144) {
                motionTiles(i, c)
                ProSlide(name: "Zoom", value: zoom, range: 1...2, shown: ProSlide.percent(zoom),
                         held: { (on: Bool) in editHeld(on) },
                         set: { (v: Double) in setClipMove(i) { (m: inout MoveKey) in m.size = v } })
            }
        }
    }

    private static func motions(span: Double) -> [MoveChoice] {
        let still = MoveChoice(id: "Still", icon: "rectangle.portrait", keys: [])
        let zoomIn = MoveChoice(id: "Zoom in", icon: "plus.magnifyingglass",
                                  keys: [MoveKey(at: 0), MoveKey(at: span, size: 1.18)])
        let zoomOut = MoveChoice(id: "Zoom out", icon: "minus.magnifyingglass",
                                   keys: [MoveKey(at: 0, size: 1.18), MoveKey(at: span)])
        let left = MoveChoice(id: "Drift left", icon: "arrow.left",
                                keys: [MoveKey(at: 0, x: 0.54, size: 1.12), MoveKey(at: span, x: 0.46, size: 1.12)])
        let right = MoveChoice(id: "Drift right", icon: "arrow.right",
                                 keys: [MoveKey(at: 0, x: 0.46, size: 1.12), MoveKey(at: span, x: 0.54, size: 1.12)])
        return [still, zoomIn, zoomOut, left, right]
    }

    private func motionTiles(_ i: Int, _ c: Clip) -> some View {
        MotionStrip(clip: c, choices: Self.motions(span: c.span), paused: joining, pick: { (m: MoveChoice) in pickMotion(i, m.keys) })
    }


    private func pickMotion(_ i: Int, _ keys: [MoveKey]) {
        guard clips.indices.contains(i) else { return }
        if keys.isEmpty {
            remember()
            clips[i].moves = []
        } else {
            setMoves(i, keys)
        }
    }

    private func toggleMoveKey(_ i: Int) {
        guard clips.indices.contains(i) else { return }
        let c: Clip = clips[i]
        let at: Double = now - startOf(i)
        guard at >= -0.01, at <= c.span + 0.01 else { return }
        remember()
        if let near = c.moves.firstIndex(where: { (k: MoveKey) -> Bool in abs(k.at - at) < 0.12 }) {
            clips[i].moves.remove(at: near)
        } else {
            var key: MoveKey = MoveKey.value(c.moves, at: at, base: MoveKey(at: 0))
            key.at = at
            clips[i].moves.append(key)
        }
    }


    private func setMoves(_ i: Int, _ keys: [MoveKey]) {
        guard clips.indices.contains(i) else { return }
        remember(); clips[i].moves = keys
        seek(startOf(i) + 0.01); player.play()
    }

    /// The clip's zoom at the line: all of it with no keyframes (as one keyframe), the one at the line with some.
    private func setClipMove(_ i: Int, _ change: (inout MoveKey) -> Void) {
        guard clips.indices.contains(i) else { return }
        let at = min(max(0, now - startOf(i)), clips[i].span)
        var m = MoveKey.value(clips[i].moves, at: at, base: MoveKey(at: 0))
        change(&m); m.at = at
        if clips[i].moves.isEmpty { clips[i].moves = [m]; return }
        if let k = clips[i].moves.firstIndex(where: { abs($0.at - at) < 0.12 }) { clips[i].moves[k] = m } else { clips[i].moves.append(m) }
    }

    /// The colours saved for captions, for text too.
    private func savedTextColours(_ item: EditText) -> some View {
        let id: UUID = item.id
        return ForEach(SavedColours.shared.list, id: \.self) { (s: SavedColours.Saved) in
            Button { useForText(id, s) } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(StoryArt.color(s.hex).opacity(max(0.12, s.alpha)))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Saved colour \(s.hex)")
        }
    }

    private func useForText(_ id: UUID, _ s: SavedColours.Saved) {
        changeText(id) { (t: inout EditText) in
            t.colour = s.hex
            t.colourAlpha = s.alpha < 1 ? s.alpha : nil
        }
    }

    private func textOpacity(_ item: EditText) -> some View {
        let id: UUID = item.id
        let alpha: Double = item.colourAlpha ?? 1
        return HStack(spacing: 12) {
            Text("Opacity").font(.system(size: 12))
            ThinSlider(name: "Opacity", value: alpha, range: 0...1, held: { (_: Bool) in },
                       set: { (v: Double) in changeText(id) { (t: inout EditText) in t.colourAlpha = v } })
            Text("\(Int((alpha * 100).rounded()))%").font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
        }
        .foregroundStyle(Color.white)
    }

    private func addText() {
        player.pause(); playing = false
        remember()
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
        let ink = EditText.colour(item.colour).opacity(item.colourAlpha ?? 1)
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
                            savedTextColours(item)
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
                    textOpacity(item)
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
        remember()
        var t = EditText(kind: "card", text: names[str(o["type"])] ?? "Sticker", x: 0.5, y: 0.4, from: now, to: min(max(total, now + 0.5), now + 3))
        t.card = json
        texts.append(t)
        selectText(t.id)
        if str(o["type"]) == "gif" { Task { await EditOverlays.prepare([t]) } }
    }

    private func addSticker(_ emoji: String) {
        remember()
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
        let kept = clips, sound = soundOf, talking = sounds.filter { ($0.kind == "voice" || $0.kind == "clip") && $0.file != nil }
        Task {
            defer { joining = false }
            do {
                // the video's own talking (the clips', and any sound separated from one), and each voiceover's
                var heard: [EditText] = [], spoken: [UUID: [EditText]] = [:]
                var over: ClosedRange<Double>?, lastError: Error?
                func edit() async { do { heard += try await EditOverlays.captions(kept, soundOf: sound) } catch { lastError = error } }
                func listen(_ s: EditSound) async {
                    do {
                        let said = try await EditOverlays.captions(of: s)
                        if s.kind == "voice" {
                            spoken[s.id] = said
                        } else {
                            // a separated sound's words stand in for the clips' under it
                            heard = heard.filter { $0.to <= s.from + 0.05 || $0.from >= s.to - 0.05 } + said
                        }
                    } catch { lastError = error }
                }
                switch job {
                case .sound(let id):
                    guard let s = talking.first(where: { $0.id == id }) else { return }
                    await listen(s); over = s.from...max(s.from + 0.1, s.to)
                case .clip(let id):
                    guard let i = kept.firstIndex(where: { $0.id == id }) else { return }
                    let at = ClipJoin.starts(kept)[i]
                    await edit(); over = at...(at + kept[i].span)
                case .all, .gaps:
                    await edit()
                    for s in talking { await listen(s) }
                }
                if heard.isEmpty, spoken.isEmpty, let lastError { throw lastError }
                // (Redo all: all of them made again, in the look they had; a layer with nothing heard stays)
                if job == .all { over = -3600...3600 }
                let done = layerCaptions(heard, spoken: spoken, over: over, redo: job == .all)
                remember()
                setLayered(done.texts, sounds: sounds)
                let added: Int = done.added, plural: String = added == 1 ? "" : "s"
                if let under = done.coveredBy {
                    flash("The video's own captions under \(under) are kept, switched off. Tap the eye to show them.")
                } else {
                    switch job {
                    case .gaps: flash(added == 0 ? "No gaps with words in them: every bit that's said has a caption." : "\(added) caption\(plural) added where there were none.")
                    case .all: flash("\(added) caption\(plural) made. Edit captions to fix a word or split a line.")
                    default: flash("Captioned. The other captions are as they were.")
                    }
                }
                withAnimation(.snappy) { panel = .captions }
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    /// What was heard put in its layers: the video's own with the video's own, each voiceover's with its own, and the
    /// video's own under a voiceover that's just been captioned switched off (design/voiceover-caption-layers-mockup.html).
    /// coveredBy: the voiceover to name when some were.
    private func layerCaptions(_ heard: [EditText], spoken: [UUID: [EditText]], over: ClosedRange<Double>?, redo: Bool)
        -> (texts: [EditText], added: Int, coveredBy: String?) {
        let voices: Set<UUID> = CaptionLayers.voiceIDs(sounds)
        let wasOwn: [EditText] = CaptionLayers.own(texts, voices: voices)
        let wasOff: Int = wasOwn.filter { (t: EditText) -> Bool in t.hidden == true }.count
        var out: [EditText] = texts
        var fresh: Set<UUID> = []     // the video's own just made
        var added: Int = 0

        if !heard.isEmpty {
            let inOrder: [EditText] = heard.sorted { (a: EditText, b: EditText) -> Bool in a.from < b.from }
            let made: [EditText] = EditOverlays.regroup(inOrder, by: captionGroup, lines: captionLines)
            let merged: [EditText] = EditOverlays.merge(wasOwn, made, over: over)
            let had: Set<UUID> = Set(wasOwn.map(\.id))
            for c in merged where !had.contains(c.id) { fresh.insert(c.id) }
            added += fresh.count
            out.removeAll { (t: EditText) -> Bool in had.contains(t.id) }
            out += merged
        }

        var captioned: [EditSound] = []   // the voiceovers given captions just now
        for v in sounds where v.kind == "voice" {
            guard let said = spoken[v.id] else { continue }
            let was: [EditText] = CaptionLayers.spoken(out, by: v.id, voices: voices)
            let grouped: [EditText] = EditOverlays.regroup(said, by: captionGroup, lines: captionLines)
            // Caption this and Redo all make all of its again; Fill gaps only where it has none
            let again: ClosedRange<Double>? = over == nil ? nil : -3600...3600
            let made: [EditText] = CaptionLayers.stamped(grouped, voice: v, like: was.first ?? wasOwn.first)
            let merged: [EditText] = EditOverlays.merge(was, made, over: again)
            let had: Set<UUID> = Set(was.map(\.id))
            var count: Int = 0
            for c in merged where !had.contains(c.id) { count += 1 }
            guard count > 0 || redo else { continue }
            added += count
            captioned.append(v)
            out.removeAll { (t: EditText) -> Bool in had.contains(t.id) }
            out += merged
        }

        for v in sounds where v.kind == "voice" {
            if captioned.contains(v) {
                out = CaptionLayers.cover(out, by: v, voices: voices)
            } else if !fresh.isEmpty, !CaptionLayers.spoken(out, by: v.id, voices: voices).isEmpty {
                // the video's own made just now under one captioned before
                out = CaptionLayers.cover(out, by: v, voices: voices, only: fresh)
            }
        }
        let isOff: Int = CaptionLayers.own(out, voices: voices).filter { (t: EditText) -> Bool in t.hidden == true }.count
        var coveredBy: String?
        if !captioned.isEmpty, isOff > 0, redo || isOff != wasOff || over != nil {
            coveredBy = captioned.count == 1 ? captioned[0].name : "your voiceovers"
        }
        return (texts: out, added: added, coveredBy: coveredBy)
    }

    /// A meal, recipe or workout picked for a mode: its overlays made, and it goes with the post.
    private func picked(_ what: JSON) {
        let mode = attachMode
        attachMode = nil
        remember()
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

    /// A sticker, label, recipe step, exercise or count picked: its words where it has them, and its size.
    private func textPanel(_ k: Int) -> some View {
        let item: EditText = texts[k]
        let emoji: Bool = item.kind == "sticker"
        return VStack(spacing: 0) {
            ProLead(title: leadTitle(item), sub: "") {
                if emoji {
                    ProAction(icon: "arrow.left.arrow.right", name: "Change", on: changingSticker, run: { changingSticker.toggle() })
                }
                ProDelete(name: "Take it off", run: { deleteFromPanel(item.id) })
            }
            ProBody(height: 144, spacing: 8) {
                if emoji && changingSticker {
                    stickerGrid(picked: item.text, tap: { (e: String) in changeSticker(item.id, e) })
                } else {
                    itemFields(item)
                }
            }
        }
    }

    private func leadTitle(_ item: EditText) -> String {
        switch item.kind {
        case "sticker", "card": return item.text
        case "calories": return "\(Int(item.number)) kcal"
        case "label": return "Template label"
        default: return textTitle
        }
    }

    private func changeSticker(_ id: UUID, _ emoji: String) {
        remember()
        changeText(id) { (t: inout EditText) in t.text = emoji }
        changingSticker = false
    }

    @ViewBuilder private func itemFields(_ item: EditText) -> some View {
        let id: UUID = item.id
        if item.kind != "sticker" && item.kind != "card" && item.kind != "calories" {
            wordsField("Words", text: Binding<String>(get: { item.text }, set: { (new: String) in captionWords(id, new) }),
                       lines: item.kind == "label" ? 1 : 3)
        }
        if item.kind == "label" {
            wordsField("Under it", text: Binding<String>(get: { item.detail }, set: { (new: String) in setDetail(id, new) }))
        }
        ProSlide(name: "Size", value: item.size, range: 0.4...3, shown: ProSlide.percent(item.size),
                 held: { (on: Bool) in editHeld(on) },
                 set: { (v: Double) in changeText(id) { (t: inout EditText) in t.size = v } })
        if item.kind == "sticker" || item.kind == "card" || item.kind == "calories" {
            ProHint(words: "Drag it on the video to move it.")
        }
    }

    private func wordsField(_ name: String, text: Binding<String>, lines: Int = 1) -> some View {
        let axis: Axis = lines > 1 ? .vertical : .horizontal
        return HStack(spacing: 12) {
            Text(name).font(.system(size: 12)).foregroundStyle(ProInk.quiet).frame(width: 58, alignment: .leading)
            TextField(name, text: text, axis: axis).font(.system(size: 14)).lineLimit(1...lines)
        }
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(ProInk.rule).frame(height: 0.5) }
    }

    private func setDetail(_ id: UUID, _ words: String) {
        changeText(id) { (t: inout EditText) in t.detail = words }
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

    private func styleCaptions(_ caps: [Int], _ style: String) {
        remember()
        for i in caps { texts[i].style = style }
        changeKept { (t: inout EditText) in t.style = style }   // (those trimmed off come back the same)
    }

    private func highlightCaptions(_ caps: [Int], on: Bool) {
        remember()
        let set: (inout EditText) -> Void = { (t: inout EditText) in
            if !on { t.highlight = "none" } else if t.highlight == "none" { t.highlight = nil }
        }
        for i in caps { set(&texts[i]) }
        changeKept(set)
    }

    private func takeOffCaptions() {
        remember()
        texts.removeAll { (t: EditText) -> Bool in t.kind == "caption" }
        cutWords = []
        for i in sounds.indices where sounds[i].cut != nil { sounds[i].cut = nil }
    }



    private var captionIndices: [Int] {
        let shown: [Int] = texts.indices.filter { (i: Int) -> Bool in texts[i].kind == "caption" && texts[i].hidden != true }
        return shown.sorted { (a: Int, b: Int) -> Bool in texts[a].from < texts[b].from }
    }

    /// The captions on in the same layer as this one, in order.
    private func layerMates(_ id: UUID) -> [Int] {
        guard let mine = texts.first(where: { (t: EditText) -> Bool in t.id == id }) else { return [] }
        let voices: Set<UUID> = CaptionLayers.voiceIDs(sounds)
        let layer: UUID? = CaptionLayers.track(mine, voices: voices)
        return captionIndices.filter { (i: Int) -> Bool in CaptionLayers.track(texts[i], voices: voices) == layer }
    }

    /// Every caption made again from its words, as much in each as picked (straight away: no listening again).
    private func regroupCaptions() {
        let caps = texts.filter { $0.kind == "caption" }
        guard !caps.isEmpty else { return }
        remember()
        // each layer by itself, and what's switched off apart: run together, the two layers' words mixed
        let voices: Set<UUID> = CaptionLayers.voiceIDs(sounds)
        var groups: [String: [EditText]] = [:]
        for c in caps {
            let layer: String = CaptionLayers.track(c, voices: voices)?.uuidString ?? "own"
            let state: String = c.hidden == true ? "off" : "on"
            groups[layer + state, default: []].append(c)
        }
        var made: [EditText] = []
        for key in groups.keys.sorted() { made += EditOverlays.regroup(groups[key] ?? [], by: captionGroup, lines: captionLines) }
        texts.removeAll { $0.kind == "caption" }
        texts += made
        listPicked = nil
    }

    /// The captions as a whole (design/editor-panels-mockup.html, 3): how much is on screen at a time, how many
    /// lines, the look of every one, and the list to edit them in.
    private var captionsPanel: some View {
        let caps: [Int] = captionIndices
        let count: String = "\(caps.count) caption\(caps.count == 1 ? "" : "s")"
        return VStack(spacing: 0) {
            ProLead(title: count, sub: "") {
                ProAction(icon: "text.badge.plus", name: "Fill gaps", run: { makeCaptions(.gaps) })
                ProAction(icon: "arrow.clockwise", name: "Redo all", run: { makeCaptions(.all) })
                ProDelete(name: "Take the captions off", run: { takeCaptionsOff() })
            }
            ProTabs(names: ["On screen", "Style"], on: captionsTab, pick: { (tab: String) in captionsTab = tab })
            ProBody(spacing: 4) {
                if captionsTab == "Style" { captionTiles(caps) } else { captionChoices(caps) }
            }
        }
    }

    private func takeCaptionsOff() {
        takeOffCaptions()
        withAnimation(.snappy) { panel = nil }
    }

    private static let groupOptions: [ProOption] = [ProOption(id: "word", name: "1 word"), ProOption(id: "few", name: "A few"),
                                                    ProOption(id: "line", name: "A line"), ProOption(id: "sentence", name: "Sentence")]
    private static let lineOptions: [ProOption] = [ProOption(id: "1", name: "1"), ProOption(id: "2", name: "Up to 2")]
    private static let onOptions: [ProOption] = [ProOption(id: "on", name: "On"), ProOption(id: "off", name: "Off")]

    @ViewBuilder private func captionChoices(_ caps: [Int]) -> some View {
        let unlit: Bool = caps.allSatisfy { (i: Int) -> Bool in texts[i].highlight == "none" }
        ProPick(title: "At a time", options: Self.groupOptions, value: captionGroup, pick: { (v: String) in setGroup(v) })
        ProPick(title: "Lines", options: Self.lineOptions, value: String(captionLines), pick: { (v: String) in setLines(v) })
        ProPick(title: "Highlight", options: Self.onOptions, value: unlit ? "off" : "on",
                pick: { (v: String) in highlightCaptions(captionIndices, on: v != "off") })
    }

    private func setGroup(_ v: String) {
        captionGroup = v
        regroupCaptions()
    }

    private func setLines(_ v: String) {
        captionLines = Int(v) ?? 1
        regroupCaptions()
    }

    private func captionTiles(_ caps: [Int]) -> some View {
        let first: EditText? = caps.first.map { (i: Int) -> EditText in texts[i] }
        let same: Bool = caps.allSatisfy { (i: Int) -> Bool in texts[i].style == first?.style }
        return HStack(spacing: 8) {
            ForEach(EditText.captionStyles, id: \.self) { (style: String) in
                captionTile(style, like: first, on: same && first?.style == style)
            }
        }
    }

    private func captionTile(_ style: String, like: EditText?, on: Bool) -> some View {
        var sample = EditText(kind: "caption", text: "Say it", style: style, from: 0, to: 2,
                              words: [EditText.Word(text: "Say", at: 0), EditText.Word(text: "it", at: 1)])
        if let like { sample.takeColours(from: like) }
        sample.detail = "1"
        let shown: EditText = sample
        return ProTile(name: style, on: on, pick: { styleCaptions(captionIndices, style) }, preview: {
            EditTextView(item: shown, at: 0).fixedSize().scaleEffect(0.56)
        })
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
                        layeredRow(caps[n], saying: saying).id(texts[caps[n]].id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear { if let p = listPicked ?? saying { proxy.scrollTo(p, anchor: .center) } }
            // as it plays, the caption being said stays in view
            .onChange(of: saying) { _, id in if playing, let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }

    /// A row, knowing whether there's one before or after it in its own layer to merge with.
    private func layeredRow(_ k: Int, saying: UUID?) -> some View {
        let mates: [Int] = layerMates(texts[k].id)
        return captionRow(k, first: mates.first == k, last: mates.last == k, saying: saying)
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
                .frame(height: 48)
            if on { captionRowTools(c.id, canSplit: wordAtLine(c) > 0) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    /// The picked row's own Split and Delete.
    private func captionRowTools(_ id: UUID, canSplit: Bool) -> some View {
        HStack(spacing: 0) {
            Button { splitCaptionAtLine(id) } label: {
                Image(systemName: "scissors").font(.system(size: 13)).frame(width: 34, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!canSplit).opacity(canSplit ? 1 : 0.35)
            .accessibilityLabel("Split at the line").accessibilityHint("Once the line's past its first word")
            Button { deleteCaption(id) } label: {
                Image(systemName: "trash").font(.system(size: 13)).frame(width: 30, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Delete this caption")
        }
        .foregroundStyle(ProInk.soft)
    }

    /// Split before the word being said at the line. (At the cursor, from the bar over the keyboard.)
    private func splitCaptionAtLine(_ id: UUID) {
        guard let k = texts.firstIndex(where: { (t: EditText) -> Bool in t.id == id }) else { return }
        let c: EditText = texts[k]
        let word: Int = wordAtLine(c)
        guard let halves = EditOverlays.split(c, at: word) else {
            flash("Slide the line to the word it should split before, or put the cursor there and tap Split.")
            return
        }
        remember()
        texts[k] = halves.0
        texts.append(halves.1)
        listPicked = halves.1.id
    }

    /// Which of a caption's words the line's on; the first when it's not on it.
    private func wordAtLine(_ c: EditText) -> Int {
        guard now >= c.from, now < c.to else { return 0 }
        return c.lit(at: now) ?? 0
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
        let caps = layerMates(id)
        guard let n = caps.firstIndex(where: { texts[$0].id == id }) else { return }
        if up { if n > 0 { joinNext(caps[n - 1]) } } else { joinNext(caps[n]) }
    }

    private func deleteCaption(_ id: UUID) {
        removeText(id)
        if listPicked == id { listPicked = nil }
        if selectedText == id { selectedText = nil }
    }

    /// A caption and the one after it as one.
    private func joinNext(_ k: Int) {
        let caps = layerMates(texts[k].id)
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


    private func planBinding(_ key: WritableKeyPath<EditOverlays.RecipePlan, Bool>) -> Binding<Bool> {
        Binding(get: { plan[keyPath: key] }, set: { plan[keyPath: key] = $0; remakeRecipe() })
    }

    private var recipePanel: some View {
        let meal: JSON = recipe ?? [:]
        let name: String = str(meal["name"])
        return VStack(spacing: 0) {
            ProLead(title: name.isEmpty ? "Recipe" : name, sub: "") {
                ProAction(icon: "arrow.left.arrow.right", name: "Change", run: { attachMode = "recipe" })
                ProDelete(name: "Take the recipe off", run: { takeRecipeOff() })
            }
            ProTabs(names: ["Show", "Macros", "Look"], on: recipeTab, pick: { (tab: String) in recipeTab = tab })
            ProBody {
                switch recipeTab {
                case "Macros": recipeMacros
                case "Look": recipeLooks
                default: recipeParts(EditOverlays.steps(of: meal))
                }
            }
        }
    }

    private func recipeParts(_ steps: [String]) -> some View {
        let count: Int = steps.count
        let method: String = count == 0 ? "No steps saved" : "\(count) step\(count == 1 ? "" : "s") ›"
        var open: (() -> Void)?
        if plan.method && count > 0 { open = { openSteps() } }
        return VStack(spacing: 4) {
            HStack(spacing: 18) {
                ProSwitch(title: "Title card", sub: "At the start", on: planBinding(\.title))
                ProSwitch(title: "Ingredients", sub: "After the title", on: planBinding(\.ingredients))
            }
            HStack(spacing: 18) {
                ProSwitch(title: "Method", sub: method, on: planBinding(\.method), open: open)
                ProSwitch(title: "Macros", sub: "On the last clip", on: planBinding(\.macros))
            }
        }
    }

    private func openSteps() {
        withAnimation(.snappy) { panel = .recipeSteps }
    }

    @ViewBuilder private var recipeMacros: some View {
        if plan.macros {
            ProPick(title: "Number", options: [ProOption(id: "count", name: "Counts up"), ProOption(id: "still", name: "Shown still")],
                    value: plan.countUp ? "count" : "still", pick: { (v: String) in setCountUp(v == "count") })
            HStack(spacing: 16) {
                Text("Show").font(.system(size: 12)).foregroundStyle(ProInk.quiet).frame(width: 58, alignment: .leading)
                macroToggle("p", "Protein")
                macroToggle("c", "Carbs")
                macroToggle("f", "Fat")
                Spacer(minLength: 0)
            }
            .frame(height: 30)
        } else {
            ProHint(words: "Macros are off. Switch them on under Show.")
        }
    }

    private func setCountUp(_ on: Bool) {
        // (made again for nothing, the recipe's words lost where they'd been moved to)
        guard plan.countUp != on else { return }
        plan.countUp = on
        remakeRecipe()
    }

    private func macroToggle(_ key: String, _ name: String) -> some View {
        let on: Bool = plan.show.contains(key)
        return Button { toggleMacro(key) } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(on ? 1 : 0)
                Text(name).font(.system(size: 13, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Color.white : ProInk.quiet)
            .frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleMacro(_ key: String) {
        if plan.show.contains(key) { plan.show.remove(key) } else { plan.show.insert(key) }
        remakeRecipe()
    }

    private var recipeLooks: some View {
        HStack(spacing: 8) {
            ForEach(EditOverlays.RecipePlan.looks, id: \.self) { (l: String) in recipeLook(l) }
        }
    }

    private func recipeLook(_ l: String) -> some View {
        let sample = EditText(kind: "step", text: "Marinate", detail: "1/5", style: l, from: 0, to: 2)
        return ProTile(name: l, on: plan.look == l, pick: { setRecipeLook(l) }, preview: {
            EditTextView(item: sample, at: 0).fixedSize().scaleEffect(0.5)
        })
    }

    private func setRecipeLook(_ l: String) {
        plan.look = l
        remakeRecipe()
    }

    private func takeRecipeOff() {
        remember()
        recipe = nil
        remakeRecipe()
        withAnimation(.snappy) { panel = nil }
    }

    private var recipeSteps: some View {
        let steps: [String] = EditOverlays.steps(of: recipe ?? [:])
        let room: Int = max(1, plan.macros && clips.count > 1 ? clips.count - 1 : clips.count)
        let even: Bool = plan.spread || steps.count > room
        let crowded: Bool = !plan.spread && steps.count > room
        return VStack(spacing: 0) {
            ProPick(title: "Steps", options: [ProOption(id: "clip", name: "A clip each"), ProOption(id: "even", name: "Spread evenly")],
                    value: even ? "even" : "clip", pick: { (v: String) in setSpread(v == "even") })
                .frame(height: 48)
                .overlay(alignment: .bottom) { Rectangle().fill(ProInk.rule).frame(height: 0.5) }
                .padding(.horizontal, 16)
            ScrollView {
                VStack(spacing: 0) {
                    if crowded {
                        ProHint(words: "More steps than clips, so they're spread evenly. Add clips to give each its own.", warn: true)
                            .frame(height: 40)
                    }
                    ForEach(steps.indices, id: \.self) { (n: Int) in stepRow(n, saved: steps[n], even: even) }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func setSpread(_ on: Bool) {
        guard plan.spread != on else { return }
        plan.spread = on
        remakeRecipe()
    }

    private func stepRow(_ n: Int, saved: String, even: Bool) -> some View {
        let on: Bool = stepPicked == n
        let words = Binding<String>(get: { plan.words[n] ?? saved }, set: { (new: String) in setStep(n, new) })
        return HStack(spacing: 12) {
            Text("\(n + 1)").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 16, alignment: .leading)
            if on {
                TextField("Step", text: words, axis: .vertical).font(.system(size: 14)).lineLimit(1...3).padding(.vertical, 6)
            } else {
                Text(plan.words[n] ?? saved).font(.system(size: 14)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !even { stepClip(n) }
        }
        .foregroundStyle(on ? Color.white : ProInk.quiet)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(ProInk.rule).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture { pickStep(n) }
    }

    private func setStep(_ n: Int, _ words: String) {
        plan.words[n] = words
        remakeRecipe()
    }

    private func stepClip(_ n: Int) -> some View {
        let clip: Int = min(plan.clipOf[n] ?? n, clips.count - 1) + 1
        return Menu {
            ForEach(clips.indices, id: \.self) { (k: Int) in
                Button("Clip \(k + 1)") { moveStep(n, to: k) }
            }
        } label: {
            Text("Clip \(clip) ▾").font(.system(size: 11)).foregroundStyle(ProInk.soft).frame(height: 44)
        }
    }

    private func moveStep(_ n: Int, to k: Int) {
        plan.clipOf[n] = k
        remakeRecipe()
        seek(startOf(k) + 0.01)
    }

    private func pickStep(_ n: Int) {
        stepPicked = n
        let mark = "\(n + 1)/"
        guard let t = texts.first(where: { (x: EditText) -> Bool in x.part == "recipe" && x.kind == "step" && x.detail.hasPrefix(mark) }) else { return }
        player.pause(); playing = false
        seek(t.from + 0.01)
    }

    private var stickerPanel: some View {
        VStack(spacing: 0) {
            Live { ProLead(title: "Goes on at \(Self.code(now))", sub: "") { EmptyView() } }
            ProBody(height: 144) { stickerGrid(picked: "", tap: { (e: String) in addSticker(e) }) }
        }
    }

    /// The sixteen emoji, all at once.
    private func stickerGrid(picked: String, tap: @escaping (String) -> Void) -> some View {
        let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(EditText.stickers, id: \.self) { (e: String) in emojiButton(e, on: e == picked, tap: tap) }
        }
    }

    private func emojiButton(_ e: String, on: Bool, tap: @escaping (String) -> Void) -> some View {
        Button { tap(e) } label: {
            Text(e).font(.system(size: 25)).frame(maxWidth: .infinity).frame(height: 48)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? Color.white : Color.clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func data(_ j: JSON?) -> Data? { j.flatMap { try? JSONSerialization.data(withJSONObject: $0) } }

    // MARK: Stage A2

    /// The square between two clips (design/editor-all-tools-mockup.html, 3): what's set, or + for a straight cut.
    private func joinSquare(_ i: Int) -> some View {
        let set = clips[i].transition != nil
        return Button {
            guard !motion.justStopped else { return }
            joinAt = i
            withAnimation(.snappy) { panel = .join }
            seek(max(0, startOf(i + 1) - 0.6))
            player.play()
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
        let tr: ClipTransition? = clips[i].transition
        let most: Double = max(0.2, min(1.5, clips[i].span / 2, clips[i + 1].span / 2))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Between clips \(i + 1) and \(i + 2)").font(.system(size: 12)).foregroundStyle(ProInk.quiet)
                .frame(height: 22).padding(.horizontal, 16)
            joinTiles(i, tr, most: most)
            if let tr {
                if ClipTransition.moving.contains(tr.name) { joinWays(i, tr) }
                joinSlide(i, tr, most: most).padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func joinTiles(_ i: Int, _ tr: ClipTransition?, most: Double) -> some View {
        JoinStrip(from: clips[i], into: clips[i + 1], picked: tr?.name ?? "None", direction: tr?.direction ?? "left",
                  paused: joining, pick: { (name: String) in pickJoin(i, name, tr, most: most) })
    }



    private func pickJoin(_ i: Int, _ name: String, _ tr: ClipTransition?, most: Double) {
        if name == "None" {
            setJoin(i, nil)
        } else {
            let length: Double = min(tr?.length ?? 0.5, most)
            setJoin(i, ClipTransition(kind: name, length: length, direction: tr?.direction))
        }
    }

    /// Which way it goes, for the ones that move (design/transitions-mockup.html).
    private func joinWays(_ i: Int, _ tr: ClipTransition) -> some View {
        HStack(spacing: 12) {
            Text("Direction").font(.system(size: 12)).foregroundStyle(ProInk.quiet).frame(width: 58, alignment: .leading)
            ForEach(ClipTransition.directions, id: \.self) { (way: String) in joinWay(i, tr, way) }
        }
        .frame(height: 30)
        .padding(.horizontal, 16)
    }

    private func joinWay(_ i: Int, _ tr: ClipTransition, _ way: String) -> some View {
        let on: Bool = (tr.direction ?? "left") == way
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            var next: ClipTransition = tr
            next.direction = way
            setJoin(i, next)
        } label: {
            Image(systemName: "arrow." + way).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.white : ProInk.quiet)
                .frame(width: 34, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Goes \(way)")
    }

    private func joinSlide(_ i: Int, _ tr: ClipTransition, most: Double) -> some View {
        let value: Double = min(tr.length, most)
        let length: Binding<Double> = joinLength(i, most: most)
        return ProSlide(name: "Length", value: value, range: 0.2...max(0.21, most), shown: String(format: "%.1f s", value),
                        held: { (on: Bool) in editHeld(on) }, set: { (v: Double) in length.wrappedValue = v })
    }

    private func joinLength(_ i: Int, most: Double) -> Binding<Double> {
        Binding<Double>(get: { () -> Double in
            guard clips.indices.contains(i) else { return min(0.5, most) }
            return min(clips[i].transition?.length ?? 0.5, most)
        }, set: { (v: Double) in
            if clips.indices.contains(i) { clips[i].transition?.length = v }
        })
    }

    private func setJoin(_ i: Int, _ tr: ClipTransition?) {
        guard clips.indices.contains(i) else { return }
        change { all in var all = all; all[i].transition = tr; return all }
        // shown straight away: from just before it
        if tr != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showJoin(i) } }
    }

    private func showJoin(_ i: Int) {
        guard clips.indices.contains(i + 1), clips[i].transition != nil else { return }
        seek(max(0, startOf(i + 1) - 0.6))
        player.play()
    }


    /// Filters and Adjust for a clip, as the single editor has them (StoryArt's looks), and the same for every clip.
    private func lookPanel(_ i: Int) -> some View {
        let parts: (name: String, tunes: [String: Double]) = Self.lookParts(clips[i].look)
        let adjusting: Bool = lookTool == "Adjust"
        return VStack(spacing: 0) {
            ProLead(title: "Clip \(i + 1)", sub: "") {
                if adjusting {
                    ProAction(icon: "arrow.counterclockwise", name: "Reset", enabled: !parts.tunes.isEmpty, run: { resetTunes(i) })
                }
            }
            ProTabs(names: ["Filters", "Adjust"], on: lookTool, pick: { (name: String) in lookTool = name })
            ProBody {
                if adjusting { adjustBody(i, name: parts.name, known: parts.tunes) } else { filterBody(i, name: parts.name, known: parts.tunes) }
            }
        }
    }

    static func lookParts(_ look: String) -> (name: String, tunes: [String: Double]) {
        let parts: [String] = look.split(separator: ";").map { (s: Substring) -> String in String(s) }
        var tunes: [String: Double] = [:]
        for p in parts.dropFirst() {
            let pair: [Substring] = p.split(separator: "=")
            if pair.count == 2, let v = Double(String(pair[1])) { tunes[String(pair[0])] = v }
        }
        return (parts.first ?? "Normal", tunes)
    }

    private func filterBody(_ i: Int, name: String, known: [String: Double]) -> some View {
        FilterStrip(clip: clips[i], picked: name, pick: { (f: String) in setFilter(i, f, known) })
    }

    private func setFilter(_ i: Int, _ name: String, _ known: [String: Double]) {
        guard clips.indices.contains(i) else { return }
        remember()
        clips[i].look = StoryArt.look(name, known)
    }

    private func adjustBody(_ i: Int, name: String, known: [String: Double]) -> some View {
        // (straightening is for a single picture)
        let rows: [(String, String, String, Double, Double)] = StoryArt.tunes.filter { $0.0 != "t" }
        let tools: [(id: String, name: String, icon: String)] = rows.map { (id: $0.0, name: $0.1, icon: $0.2) }
        let row: (String, String, String, Double, Double) = rows.first { $0.0 == tune } ?? rows[0]
        let value: Double = known[row.0] ?? 0
        let whole: Int = Int(value.rounded())
        let shown: String = whole > 0 ? "+\(whole)" : "\(whole)"
        return VStack(spacing: 10) {
            TuneTools(tools: tools, on: row.0, pick: { (id: String) in tune = id })
            ProSlide(name: row.1, value: value, range: row.3...row.4, shown: shown,
                     held: { (on: Bool) in editHeld(on) },
                     set: { (v: Double) in setTune(i, row.0, v, name: name, known: known) })
        }
    }

    private func setTune(_ i: Int, _ id: String, _ v: Double, name: String, known: [String: Double]) {
        guard clips.indices.contains(i) else { return }
        var next: [String: Double] = known
        next[id] = abs(v) < 2 ? 0 : v.rounded()
        clips[i].look = StoryArt.look(name, next)
    }

    private func resetTunes(_ i: Int) {
        guard clips.indices.contains(i) else { return }
        remember()
        clips[i].look = Self.lookParts(clips[i].look).name
    }

    /// The frame's shape, and what's behind a clip of another shape.
    private var shapePanel: some View {
        let background: Bool = shapeTab == "Background"
        return VStack(spacing: 0) {
            ProLead(title: background ? "A clip of another shape" : "Every clip", sub: "") { EmptyView() }
            ProTabs(names: ["Shape", "Background"], on: shapeTab, pick: { (name: String) in shapeTab = name })
            ProBody {
                if background { fillTiles } else { shapeTiles }
            }
        }
    }

    private var shapeTiles: some View {
        ShapeStrip(clip: clips.first, background: false, picked: look.shape, pick: { (s: String) in setShape(s) })
    }


    private func setShape(_ s: String) {
        guard look.shape != s else { return }
        remember()
        look.shape = s
    }

    private var fillTiles: some View {
        let shown: Clip? = index.map { (i: Int) -> Clip in clips[i] } ?? clips.first
        return ShapeStrip(clip: shown, background: true, picked: look.fill, pick: { (f: String) in setFill(f) })
    }


    private func setFill(_ f: String) {
        guard look.fill != f else { return }
        remember()
        look.fill = f
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
            guard let url = await ClipJoin.reversed(c), let made = await ClipJoin.clip(url) else { flash("Couldn't reverse that clip. Check your storage and try again."); return }
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
    static func load(_ items: [PhotosPickerItem]) async -> (clips: [Clip], failed: [Int]) {
        var out: [Clip] = [], failed: [Int] = []
        for (n, it) in items.enumerated() {
            var made: Clip?
            if it.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let m = try? await it.loadTransferable(type: PickedMovie.self) { made = await ClipJoin.clip(m.url) }
            } else if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d), let url = await ClipJoin.still(img) {
                made = await ClipJoin.clip(url, still: true)
            }
            if let made { out.append(made) } else { failed.append(n) }
        }
        return (out, failed)
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
            .task(id: "\(clip.source)|\(whole ? 0 : clip.start)|\(whole ? clip.length : clip.end)|\(Self.count(g.size.width))") {
                let made: [UIImage] = await Self.frames(clip, whole: whole, count: Self.count(g.size.width))
                // (what's there stays up till all the new ones are in)
                if !Task.isCancelled, !made.isEmpty { frames = made }
            }
        }
    }
    /// How many frames for a width: doubling, so a pinch doesn't make them again at each step.
    static func count(_ width: CGFloat) -> Int {
        if width < 80 { return 1 }
        if width < 160 { return 2 }
        return width < 320 ? 4 : 8
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
    var ended: () -> Void = {}
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
        .onDisappear { letGo() }
    }

    private func letGo() {
        guard dragging else { return }
        dragging = false
        ended()
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
                .onEnded { _ in letGo() })
            .accessibilityLabel(left ? "Start" : "End")
    }
}

/// A bar under the finger: it starts to lift almost as the finger lands, then springs the rest of the way as the hold's
/// taken, and back as it's let go or the finger scrolls off (22 Nov: "should start almost instant but not once it's
/// recognised you're holding it"). A moment's wait first, so a flick across the bars doesn't move each one it touches.
/// One animation for the three: with one for the press and one for the lift, the press's won and the spring never
/// played. With Reduce Motion, the shadow alone.
private struct BarLift: ViewModifier {
    var up: Bool
    var pressing: Bool
    var anchor: UnitPoint = .center
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        let stage: Int = up ? 2 : (pressing ? 1 : 0)
        let sizes: [CGFloat] = [1, 1.05, 1.1], rises: [CGFloat] = [0, -2.5, -4]
        let shade: [Double] = [0, 0.35, 0.5], blur: [CGFloat] = [0, 7, 12], drop: [CGFloat] = [0, 4, 8]
        let moving: Animation
        if stage == 1 {
            moving = .easeOut(duration: 0.11).delay(0.02)   // under way well before the 170 ms are up
        } else if stage == 2 && !still {
            moving = .spring(response: 0.18, dampingFraction: 0.65)
        } else {
            moving = .easeOut(duration: 0.08)
        }
        let size: CGFloat = still ? 1 : sizes[stage], rise: CGFloat = still ? 0 : rises[stage]
        let dark: Color = .black.opacity(shade[stage]), soft: CGFloat = blur[stage], below: CGFloat = drop[stage]
        // only these three move. Animating by value took the bar's place along with them: picked, it slid after the
        // timeline into its frame, which was already there (22 Nov recording, "select animation could be quicker still")
        return content.animation(moving) { view in
            view.scaleEffect(size, anchor: anchor)
                .shadow(color: dark, radius: soft, y: below)
                .offset(y: rise)
        }
    }
}

/// The timeline's edge: its own, and as far below it as the rail for a lifted bar shows.
private struct TimelineEdge: Shape {
    var below: CGFloat
    func path(in rect: CGRect) -> Path { Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + below)) }
}
