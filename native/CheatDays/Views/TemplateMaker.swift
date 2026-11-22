import AVFoundation
import CoreMedia
import PhotosUI
import SwiftUI

/// Templates, from the editor (design/templates-pro-mockup.html; first 21 Nov, design/templates-mockup.html): pick
/// one that's playing, then fill its slots with clips as it plays, change the words, and choose each one's moment.
/// Make it hands the template, the clips in slot order and their slots back to the editor, which cuts them on the
/// beat as the preview did; all of it stays editable after.
struct TemplateMaker: View {
    var clips: [Clip]
    /// The edit's shape, and the smaller copies of its 4K clips, for what plays here.
    var editLook: EditLook = EditLook()
    var proxies: [URL: URL] = [:]
    /// What's on the edit already, which Make it keeps.
    var carry = EditCarry()
    var make: (EditTemplate, TemplateCut, JSON?) -> Void
    var close: () -> Void

    @State private var picked: EditTemplate?
    @State private var log: EditTemplate.Log?
    @State private var library: [Clip] = []
    @State private var filled: [UUID?] = []          // each slot's clip, from the library
    @State private var edited: [Int: EditTemplate.Slot] = [:]   // the words changed, by slot
    @State private var moments: [Int: Double] = [:]  // where each slot's clip starts, where that's been chosen
    @State private var slotOn = 0
    @State private var tab = "Clips"
    @State private var recipe: JSON?
    @State private var choosingRecipe = false
    @State private var adding = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var importFailure: ImportFailure?

    @State private var music: TemplateMusic?
    @State private var musicFor: String?             // the template whose song has come, or couldn't
    @State private var lastOpened: String?
    @State private var frozen: TemplateCut?          // the tiles' pictures while a moment's dragged
    @State private var untouched = true              // the slots as they were first filled
    @State private var typing = false
    @State private var cut = TemplateCut()
    @State private var player = PreviewEngine()
    @State private var clock = EditPlayhead()
    @State private var playing = false
    @State private var resume = false                // it was playing as a moment began to be dragged
    @State private var choosing = false              // a moment's being dragged
    @State private var frameSize = CGSize(width: 1080, height: 1920)

    private var store: Store { Store.shared }

    /// What the words come from: today's food and workouts, the week before, the weigh-ins.
    private func readLog() -> EditTemplate.Log {
        let since = DayKey.shift(store.today, days: -8)
        let past = list(store.doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < store.today }
            .map { (date: str($0["date"]), items: list($0["items"])) }
        let older = list(store.doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < store.today }
            .sorted { str($0["date"]) < str($1["date"]) }.flatMap { list($0["workouts"]) }
        let weights = store.bodyRows.compactMap { r in pos(r["weight"]).map { (day: str(r["day"]), kg: $0) } }.filter { $0.day <= store.today }
        return EditTemplate.Log(today: store.today, items: store.todayItems, history: past, workouts: older + store.todayWorkouts, weights: weights)
    }

    /// The slots as the log has them.
    private var logged: [EditTemplate.Slot] {
        guard let picked, let log else { return [] }
        return picked.slots(log, recipe: recipe)
    }

    /// The slots with the words that have been changed.
    private var slots: [EditTemplate.Slot] {
        var out: [EditTemplate.Slot] = logged
        for (i, words) in edited where out.indices.contains(i) {
            out[i].name = words.name
            out[i].detail = words.detail
        }
        return out
    }

    /// What the video's made of: any of it changed, it's cut again.
    private struct Making: Equatable {
        var template: String
        var library: [Clip]
        var filled: [UUID?]
        var moments: [Int: Double]
        var slots: [EditTemplate.Slot]
        var song: UUID?
    }

    private var making: Making {
        Making(template: picked?.id ?? "", library: library, filled: filled, moments: moments, slots: slots, song: music?.song.id)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().importFailed($importFailure)
            screen
            if loading {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .modifier(TemplateLife(appeared: { appeared() }, away: { pause() }, back: { woken() }, gone: { gone() }))
        .task(id: picked?.id) { await loadMusic() }
        .onChange(of: making) { (_: Making, _: Making) in recut() }
        .photosPicker(isPresented: $adding, selection: $picks, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: picks) { (_: [PhotosPickerItem], new: [PhotosPickerItem]) in
            guard !new.isEmpty else { return }
            picks = []
            load(new)
        }
        .sheet(isPresented: $choosingRecipe) {
            AttachPicker(start: 1) { what in
                if str(what["kind"]) == "meal" { useRecipe(what) }
            }
        }
    }

    @ViewBuilder private var screen: some View {
        if let t = picked {
            filling(t)
        } else if let log {
            TemplateGallery(log: log, pick: { (t: EditTemplate) in open(t) }, close: close)
        }
    }

    // MARK: coming and going

    private func appeared() {
        if log == nil { log = readLog() }
        if library.isEmpty { library = clips }
        guard player.onTime == nil else { return }
        player.onTime = { (t: Double) in
            clock.time = t
        }
        player.onSize = { (size: CGSize) in frameSize = size }
    }

    private func pause() {
        player.pause()
        playing = false
    }

    private func woken() {
        Sound.on(.moviePlayback)
        player.wake()
    }

    private func gone() {
        player.shutdown()
        Sound.on(.moviePlayback)   // (back to the editor, which still wants it)
    }

    private func loadMusic() async {
        guard let t = picked, musicFor != t.id else { return }
        music = nil
        musicFor = nil
        let made: TemplateMusic? = await TemplateMusic.load(t)
        guard !Task.isCancelled else { return }
        music = made
        musicFor = t.id
    }

    /// Its song's still coming: made now, it would be cut differently.
    private var gettingMusic: Bool {
        guard let picked else { return false }
        return musicFor != picked.id
    }

    private func load(_ items: [PhotosPickerItem]) {
        loading = true
        Task {
            let loaded: (clips: [Clip], failed: [Int]) = await MultiClipEditor.load(items)
            loading = false
            let got: [Clip] = loaded.clips
            let go: () -> Void = {
                library += got
                putAll(got)
            }
            if loaded.failed.isEmpty { go(); return }
            try? await Task.sleep(for: .milliseconds(450))
            importFailure = ImportFailure(total: items.count, failed: loaded.failed, retry: { load(items) }, carryOn: got.isEmpty ? nil : go)
        }
    }

    /// Several added: a slot each. Every slot full, they take the places of those from the picked one on.
    private func putAll(_ got: [Clip]) {
        for c in got {
            let here: Int = slotOn
            put(c.id)
            let full: Bool = !filled.contains { (id: UUID?) -> Bool in id == nil }
            if full && got.count > 1 && !filled.isEmpty { slotOn = (here + 1) % filled.count }
        }
    }

    private func open(_ t: EditTemplate) {
        guard let log else { return }
        if t.id == lastOpened, !filled.isEmpty {
            // (back to the one being filled: as it was left)
            picked = t
            Sound.on(.moviePlayback)
            show(0)
            play()
            return
        }
        lastOpened = t.id
        music = nil
        musicFor = nil
        let count: Int = t.slots(log, recipe: nil).count
        let start: (filled: [UUID?], moments: [Int: Double]) = TemplateCut.spread(library: library, slots: count)
        let first: [UUID?] = start.filled
        recipe = nil
        edited = [:]
        moments = start.moments
        untouched = true
        tab = "Clips"
        cut = TemplateCut()
        clock.time = 0
        filled = first
        slotOn = first.firstIndex(where: { (id: UUID?) -> Bool in id == nil }) ?? 0
        picked = t
        Sound.on(.moviePlayback)
        if t.id == "recipe" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { choosingRecipe = true } }
    }

    private func leave() {
        pause()
        picked = nil
    }

    /// A recipe picked changes how many slots there are: clips kept in order, as far as they go.
    private func useRecipe(_ what: JSON) {
        recipe = what
        edited = [:]
        let count: Int = logged.count
        if untouched {
            let start: (filled: [UUID?], moments: [Int: Double]) = TemplateCut.spread(library: library, slots: count)
            filled = start.filled
            moments = start.moments
            slotOn = min(slotOn, max(0, count - 1))
            return
        }
        if filled.count > count {
            filled = Array(filled.prefix(count))
        } else {
            filled += Array(repeating: nil, count: count - filled.count)
        }
        moments = moments.filter { (i: Int, _: Double) -> Bool in i < count }
        slotOn = min(slotOn, max(0, count - 1))
    }

    private func recut() {
        guard picked != nil else { return }
        let began: Bool = cut.clips.isEmpty
        let made: TemplateCut = cutNow()
        cut = made
        player.update(clips: made.clips, soundOf: nil, look: editLook, sounds: made.sounds, pips: made.pips, swap: proxies)
        frameSize = player.frameSize
        guard !made.clips.isEmpty else {
            pause()
            return
        }
        if choosing {
            showSlot(slotOn)
        } else if began {
            show(0)
            play()
        }
    }

    private func cutNow() -> TemplateCut {
        guard let t = picked else { return TemplateCut() }
        return TemplateCut.make(t, library: library, filled: filled, moments: moments, slots: slots, music: music, carry: carry)
    }

    /// Just past the join into a slot, where it's that slot's clip that's seen.
    private func showSlot(_ slot: Int) {
        guard let at = cut.start(of: slot) else { return }
        show(at + midJoin(slot))
    }

    private func show(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        clock.time = t
    }

    private func play() {
        player.play()
        playing = true
    }

    private func togglePlay() {
        if player.rate == 0 { play() } else { pause() }
    }

    // MARK: filling it

    private func filling(_ t: EditTemplate) -> some View {
        VStack(spacing: 0) {
            // (typing: the room to the video, to see the words on it)
            if !typing { topBar(t) }
            video
            sheet(t)
        }
        .foregroundStyle(Color.white)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
        .onDisappear { typing = false }
    }

    private func topBar(_ t: EditTemplate) -> some View {
        let ready: Bool = !gettingMusic && filled.contains { (id: UUID?) -> Bool in id != nil }
        return HStack(spacing: 12) {
            Button { leave() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Back to the templates")
            Text(t.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
            Spacer(minLength: 0)
            Button { finish(t) } label: {
                Text("Make it").font(.subheadline.weight(.bold)).foregroundStyle(Color.black)
                    .padding(.horizontal, 15).frame(height: 32)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain).disabled(!ready).opacity(ready ? 1 : 0.4)
        }
        .padding(.leading, 6).padding(.trailing, 12)
        .frame(height: 52)
    }

    private var video: some View {
        EditPreviewView(engine: player)
            .opacity(cut.clips.isEmpty ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { TemplateWords(clock: clock, words: cut.words, sounds: cut.sounds, frameSize: frameSize, outlined: tab == "Words") }
            .overlay {
                if cut.clips.isEmpty { Text("Pick a clip to see it play.").font(.system(size: 13)).foregroundStyle(ProInk.quiet) }
            }
            .contentShape(Rectangle())
            .onTapGesture { togglePlay() }
            .padding(.bottom, 8)
    }

    private func sheet(_ t: EditTemplate) -> some View {
        let count: Int = slots.count
        let name: String = slots.indices.contains(slotOn) ? slots[slotOn].name : ""
        var title = "Slot \(min(slotOn + 1, count)) of \(count)"
        if tab == "Words" && !name.isEmpty { title = name }
        return ProSheet(title: title, left: nil, done: { slotDone(t) }, whileTyping: 192,
                        head: { sheetHead(t) },
                        main: { sheetMain })
    }

    private func sheetHead(_ t: EditTemplate) -> some View {
        VStack(spacing: 0) {
            Live { transport(t) }
            slotRow
        }
    }

    private func transport(_ t: EditTemplate) -> some View {
        let at: String = MultiClipEditor.code(clock.time)
        let whole: String = MultiClipEditor.code(cut.total)
        return ZStack {
            (Text(at).foregroundColor(.white) + Text(" / " + whole).foregroundColor(ProInk.quiet))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            HStack(spacing: 0) {
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 15))
                        .frame(width: 40, height: 38, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(playing ? "Pause" : "Play")
                Spacer(minLength: 0)
                fromWhat(t)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    @ViewBuilder private func fromWhat(_ t: EditTemplate) -> some View {
        let song: String = gettingMusic ? "Getting the song…" : (music?.song.name ?? "No song")
        let recipes: Bool = t.id == "recipe"
        HStack(spacing: 10) {
            if recipes {
                Button { choosingRecipe = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "fork.knife").font(.system(size: 12))
                        Text(recipe == nil ? "Pick" : "Change").font(.system(size: 11))
                    }
                    .frame(height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(recipe == nil ? "Pick a recipe" : "Change the recipe")
            }
            HStack(spacing: 5) {
                Image(systemName: "music.note").font(.system(size: 12))
                Text(song).font(.system(size: 11)).lineLimit(1)
            }
        }
        .foregroundStyle(ProInk.soft)
        .frame(maxWidth: 118, alignment: .trailing)
    }

    private var slotRow: some View {
        let all: [EditTemplate.Slot] = slots
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(all.indices, id: \.self) { (i: Int) in slotTile(i, all[i]).id(i) }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: slotOn) { (_: Int, new: Int) in
                withAnimation(.snappy) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: 76)
    }

    private func slotTile(_ i: Int, _ s: EditTemplate.Slot) -> some View {
        let clip: Clip? = (frozen ?? cut).clip(of: i)
        let seconds: Double = cut.shows(i) ?? Double(max(1, s.beats)) * 0.5
        return TemplateSlotTile(name: s.name.isEmpty ? "Slot \(i + 1)" : s.name, seconds: seconds, clip: clip, on: i == slotOn,
                                pick: { pickSlot(i) }, empty: { emptySlot(i) })
    }

    @ViewBuilder private var sheetMain: some View {
        ProTabs(names: ["Clips", "Words", "Which part"], on: tab, pick: { (name: String) in pickTab(name) })
        ProBody(spacing: 8) {
            switch tab {
            case "Words": wordsBody
            case "Which part": momentBody
            default: clipsBody
            }
        }
    }

    private func pickTab(_ name: String) {
        tab = name
        // (what's being changed, held up to be seen)
        guard name != "Clips", let at = cut.start(of: slotOn) else { return }
        pause()
        show(at + midJoin(slotOn))
    }

    /// Just past the join into a slot, where its own clip and words are up.
    private func midJoin(_ slot: Int) -> Double {
        guard let n = cut.slots.firstIndex(of: slot), n > 0 else { return 0.01 }
        return ClipJoin.overlap(cut.clips, after: n - 1) + 0.01
    }

    private func pickSlot(_ i: Int) {
        slotOn = i
        guard cut.start(of: i) != nil else { return }
        if tab != "Clips" { pause() }
        showSlot(i)
    }

    private func emptySlot(_ i: Int) {
        guard filled.indices.contains(i) else { return }
        untouched = false
        filled[i] = nil
        moments[i] = nil
        slotOn = i
        tab = "Clips"
    }

    /// The tick: on to the next slot; at the last, it's made.
    private func slotDone(_ t: EditTemplate) {
        if slotOn + 1 < filled.count { pickSlot(slotOn + 1) } else { finish(t) }
    }

    // MARK: its three tabs

    private var clipsBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(library) { (c: Clip) in clipTile(c) }
                addClips
            }
        }
    }

    private func clipTile(_ c: Clip) -> some View {
        let at: Int? = filled.firstIndex { (id: UUID?) -> Bool in id == c.id }
        let here: Bool = filled.indices.contains(slotOn) && filled[slotOn] == c.id
        let number: Int? = here ? slotOn + 1 : at.map { (i: Int) -> Int in i + 1 }
        return TemplateClipTile(clip: c, number: number, on: here, pick: { put(c.id) })
    }

    private var addClips: some View {
        Button { adding = true } label: {
            Image(systemName: "plus").font(.system(size: 17)).frame(width: 62, height: 84)
                .background(ProInk.tile, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityLabel("Add clips from Photos")
    }

    /// The clip into the slot that's picked, then on to the next empty one.
    private func put(_ id: UUID) {
        guard filled.indices.contains(slotOn) else { return }
        let here: Int = slotOn
        untouched = false
        if filled[here] != id { moments[here] = nil }
        var next: [UUID?] = filled
        next[here] = id
        filled = next
        UISelectionFeedbackGenerator().selectionChanged()
        let empty: [Int] = next.indices.filter { (i: Int) -> Bool in next[i] == nil }
        if let on = empty.first(where: { (i: Int) -> Bool in i > here }) ?? empty.first { slotOn = on }
    }

    @ViewBuilder private var wordsBody: some View {
        let all: [EditTemplate.Slot] = slots
        if all.indices.contains(slotOn) {
            HStack(spacing: 8) {
                wordsField("Title", text: wordsBinding(slotOn, title: true))
                if edited[slotOn] != nil {
                    ProAction(icon: "arrow.counterclockwise", name: "From log", run: { fromLog() }).fixedSize()
                }
            }
            .frame(height: 42)
            wordsField("Under it", text: wordsBinding(slotOn, title: false)).frame(height: 42)
        }
    }

    private func wordsField(_ name: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 12)).foregroundStyle(ProInk.quiet).frame(width: 52, alignment: .leading)
            TextField(name, text: text).font(.system(size: 14)).submitLabel(.done)
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(ProInk.rule).frame(height: 0.5) }
    }

    private func wordsBinding(_ i: Int, title: Bool) -> Binding<String> {
        Binding<String>(get: { () -> String in
            let all: [EditTemplate.Slot] = slots
            guard all.indices.contains(i) else { return "" }
            return title ? all[i].name : all[i].detail
        }, set: { (new: String) in
            changeWords(i, title: title, to: new)
        })
    }

    private func changeWords(_ i: Int, title: Bool, to new: String) {
        let original: [EditTemplate.Slot] = logged
        guard original.indices.contains(i) else { return }
        var words: EditTemplate.Slot = edited[i] ?? original[i]
        if title { words.name = new } else { words.detail = new }
        edited[i] = words == original[i] ? nil : words
    }

    private func fromLog() {
        edited[slotOn] = nil
    }

    @ViewBuilder private var momentBody: some View {
        if let laid = cut.clip(of: slotOn), let whole = libraryClip(slotOn) {
            if whole.still {
                ProHint(words: "A photo: it shows for the whole slot.")
            } else if laid.duration >= whole.length - 0.05 {
                ProHint(words: "This clip's about as long as the slot: it all plays.")
            } else {
                moment(laid, whole: whole)
            }
        } else {
            ProHint(words: "Put a clip in this slot first.")
        }
    }

    private func libraryClip(_ slot: Int) -> Clip? {
        guard filled.indices.contains(slot), let id = filled[slot] else { return nil }
        return library.first { (c: Clip) -> Bool in c.id == id }
    }

    private func moment(_ laid: Clip, whole: Clip) -> some View {
        let lasts: Double = laid.duration
        let room: Double = max(0, whole.length - lasts)
        let plays: String = String(format: "%.1f s plays, cut on the beat", cut.shows(slotOn) ?? laid.span)
        return VStack(spacing: 10) {
            MomentWindow(clip: whole, start: laid.start, lasts: lasts,
                         held: { (on: Bool) in momentHeld(on) },
                         moved: { (at: Double) in moveMoment(at, room: room) })
            HStack {
                Text(MultiClipEditor.tenths(laid.start)).font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Text(plays).font(.system(size: 11)).foregroundStyle(ProInk.quiet)
                Spacer()
                Text(MultiClipEditor.tenths(laid.end)).font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
    }

    private func momentHeld(_ on: Bool) {
        if on {
            resume = player.rate != 0
            pause()
            choosing = true
            frozen = cut
            showSlot(slotOn)
        } else {
            choosing = false
            frozen = nil
            if resume { play() }
            resume = false
        }
    }

    private func moveMoment(_ at: Double, room: Double) {
        untouched = false
        moments[slotOn] = min(room, max(0, at))
    }

    private func finish(_ t: EditTemplate) {
        guard !gettingMusic else { return }
        let made: TemplateCut = cutNow()
        guard !made.clips.isEmpty else { return }
        pause()
        make(t, made, t.id == "recipe" ? recipe : nil)
    }
}

/// The screen's coming and going (off the body's chain).
private struct TemplateLife: ViewModifier {
    let appeared: () -> Void
    let away: () -> Void
    let back: () -> Void
    let gone: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { appeared() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in away() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in back() }
            .onDisappear { gone() }
    }
}
