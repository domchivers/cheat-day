import AVFoundation
import Photos
import SwiftUI

/// The story editor, Instagram's way: text with fonts, colours, a highlight, alignment and glow; the app's own stickers
/// (your food, macros, streak, calories left, a workout, a poll, the time, your suburb, a mention) and emoji; drawing
/// with pen, marker, neon and eraser; filters you swipe through; and for videos, trimming and sound on or off.
/// Anything placed can be dragged, pinched, twisted, snapped to the middle and dragged to the bin.
struct StoryEditor: View {
    let image: UIImage?
    let video: URL?
    /// 9:16 for a story; 4:5 for a feed post, which gets everything baked into its photo.
    var aspect: CGFloat = StoryArt.aspect
    /// An Aa story (words on a colour): open on writing, with the keyboard up.
    var startWriting = false
    var close: () -> Void
    var posted: () -> Void = {}
    /// A feed post: the finished photo, with everything on it, instead of sharing to a story.
    var finish: ((UIImage) -> Void)? = nil
    /// A feed post's video: the filter, the part kept and whether its sound is off, for the post to be made with.
    /// Then the part of the picture kept (fractions from the top left; nil for all of it) and the shape that makes.
    var finishVideo: ((ClipEdit) -> Void)? = nil
    /// The shape picked the last time this clip was in the editor, to open on.
    var startShape: CGFloat? = nil
    /// One of several photos in a post, after the first: it keeps the first one's shape.
    var lockShape = false
    /// Open on one of the tools ("text", "stickers", "draw", "filters", "adjust"): New post's own row of tools
    /// leads straight into it.
    var startTool: String? = nil
    /// A clip's first frame, when whoever opens the editor already has it: shown at once, under the player.
    var startPoster: UIImage? = nil
    /// A post's video: its song, and how loud the song and the video's own sound are, chosen here with the video
    /// playing (Audio), as Instagram has it. They're the post's own, kept by whoever opened the editor.
    var postSong: Binding<Song?>? = nil
    var postSongVol: Binding<Double>? = nil
    var postClipVol: Binding<Double>? = nil
    private var forPost: Bool { finish != nil || finishVideo != nil }
    /// A post's clip: its own frame to zoom and move in, and everything on it made part of the video.
    private var clipOnly: Bool { finishVideo != nil }
    /// A post's photo: the shape picked for it (portrait 4:5 to start, as Instagram's is), else the editor's own.
    @State private var shape: CGFloat?
    /// A post's clip goes in a tall 9:16 frame, the shape videos are watched in, whatever shape it was filmed
    /// (it's placed in the frame; the frame doesn't take its shape); a photo starts at the editor's own shape.
    private var ratio: CGFloat { shape ?? (clipOnly ? 9.0 / 16.0 : aspect) }
    private static let shapes: [(name: String, ratio: CGFloat)] = [("Portrait 4:5", 4.0 / 5.0), ("Tall 3:4", 3.0 / 4.0), ("Square 1:1", 1), ("Landscape 16:9", 16.0 / 9.0)]
    /// The photo's own shape, within what the feed shows (no taller than 4:5, no wider than 1.91:1).
    private var ownShape: CGFloat? { image.map { min(1.91, max(0.75, $0.size.width / max($0.size.height, 1))) } }
    /// The clip's own shape, from its first frame.
    private var clipShape: CGFloat? { poster.map { $0.size.width / max($0.size.height, 1) } }
    /// Where the clip was dragged to, as fractions of the frame (the frame's size on screen isn't known when sharing).
    @State private var clipMove: CGSize = .zero
    private func nextShape() {
        var all = Self.shapes
        if clipOnly {
            all.insert(("Tall 9:16", 9.0 / 16.0), at: 0)
            if let o = clipShape, !all.contains(where: { abs($0.ratio - o) < 0.02 }) { all.insert(("Original", o), at: 0) }
        } else if let o = ownShape, !all.contains(where: { abs($0.ratio - o) < 0.02 }) { all.append(("Original", o)) }
        let i = all.firstIndex { abs($0.ratio - ratio) < 0.02 } ?? 0, next = all[(i + 1) % all.count]
        withAnimation(.snappy) { shape = next.ratio; bgScale = 1; bgOffset = .zero; bgSpin = 0; clipMove = .zero; clipCovers = true }
        flash(next.name)
    }

    /// The clip's size when it just fills a frame cw by ch.
    private func clipFill(_ cw: CGFloat, _ ch: CGFloat) -> CGSize {
        let v = clipShape ?? (cw / ch)
        return v > cw / ch ? CGSize(width: ch * v, height: ch) : CGSize(width: cw, height: cw / v)
    }
    /// A pinch, a turn or a drag on the clip: it's where the fingers put it (the clip itself keeps it in reach and
    /// catches it at the frame's middle and edges). Whether it still covers the whole frame is noted, for the video
    /// to be made by cutting a piece from the picture when it does, and by laying the picture on black when not.
    private func moveClip(_ sc: CGFloat, _ off: CGSize, _ deg: Double, cw: CGFloat, ch: CGFloat) {
        let f = clipFill(cw, ch), s = min(10, max(0.25, sc))
        bgSpin = deg
        bgScale = s; bgOffset = off   // no animation: the clip is already there, under the fingers
        clipMove = CGSize(width: off.width / cw, height: off.height / ch)
        let mx = (f.width * s - cw) / 2, my = (f.height * s - ch) / 2
        clipCovers = deg == 0 && mx >= -0.5 && my >= -0.5 && abs(off.width) <= mx + 0.5 && abs(off.height) <= my + 0.5
    }
    @State private var clipCovers = true
    /// The part of the clip's picture showing in the frame, as fractions from its top left; nil when that's all of it.
    private var clipCrop: CGRect? {
        let r = ratio, f = clipFill(r, 1), s = bgScale
        let w = f.width * s, h = f.height * s
        let x = ((w - r) / 2 - clipMove.width * r) / w, y = ((h - 1) / 2 - clipMove.height) / h
        let cut = CGRect(x: max(0, x), y: max(0, y), width: min(1, r / w), height: min(1, 1 / h))
        return cut.width > 0.995 && cut.height > 0.995 ? nil : cut
    }

    enum Mode { case none, text, draw, filters, trim, adjust }
    @State private var mode: Mode = .none
    @State private var items: [JSON] = []
    @State private var strokes: [JSON] = []
    @State private var current: [CGPoint] = []
    @State private var filter = "Normal"
    // Adjust: each slider that's off its rest, by its letter; the one being slid; and, for a clip, the sliders as
    // they were when a finger last lifted (the player is rebuilt for a new look, too much to do for every step)
    @State private var tune: [String: Double] = [:]
    @State private var tool: String?
    @State private var settled: [String: Double] = [:]
    @State private var turns = 0   // a post's clip, turned by quarters to the right (a photo is itself turned)
    // a smaller copy of the photo, drawn through the look while a slider is moving (the full one each step lagged
    // behind the finger); the full one is drawn when the finger lifts
    @State private var lite: UIImage?
    @State private var sliding = false
    /// The look without Straighten: on a photo that's a turn of the picture on screen, done as the slider moves,
    /// not a new picture made for every degree.
    private var flatLook: String { StoryArt.look(filter, tune.filter { $0.key != "t" }) }
    @State private var comparing = false   // a finger held on the photo in Adjust: the photo as it came
    private var look: String { StoryArt.look(filter, tune) }
    private var clipLook: String { StoryArt.look(filter, settled) }
    @State private var preview: UIImage?
    @State private var work: UIImage?   // the photo at screen size: filtering and drawing a 4000-pixel one lagged
    @State private var thumbs: [String: UIImage] = [:]
    // the photo itself, pinched and moved
    @State private var bgScale: CGFloat = 1
    @State private var bgOffset: CGSize = .zero
    @State private var bgSpin: Double = 0   // turned by two fingers, in degrees to the right
    // the look the clip's frames are drawn through: a slider writes to it directly, without this whole screen being
    // worked out again for each step (see LoopingVideo.box)
    @State private var lookBox = LoopingVideo.Look()
    // a story's song (a post's is chosen where the post is written up): it plays while the story's being made, and
    // goes with the story as one of the things on it, to be played when the story's watched
    @State private var storySong: Song?
    @State private var choosingSong = false
    @State private var mixing = false   // a post's video: the song's name and the two volumes, over the playing video
    @State private var justPicked = false
    /// The song on it: a post's video's (kept by the post), or a story's.
    private var song: Song? { postSong.map { $0.wrappedValue } ?? storySong }
    private func setSong(_ s: Song?) { if let postSong { postSong.wrappedValue = s } else { storySong = s } }
    private var songLevel: Float { Float(postSongVol?.wrappedValue ?? 1) }
    private var clipLevel: Float { song == nil ? 1 : Float(postClipVol?.wrappedValue ?? 1) }
    @State private var songSeed = Int.random(in: 0..<10_000)
    /// A song put forward for a story that has none: by what's on it (a workout sticker, something lively from Gym;
    /// food or its numbers, something easy from Chill), else by the hour (bright in the morning and through the
    /// day, easy at night). Which one of that kind changes each time the editor's opened.
    private var suggested: Song? {
        guard !forPost, storySong == nil, image != nil || video != nil else { return nil }
        let kinds = Set(items.map { str($0["type"]) }), hour = Calendar.current.component(.hour, from: Date())
        let mood = kinds.contains("workout") ? "Gym" : (kinds.contains("food") || kinds.contains("macros")) ? "Chill" : hour >= 20 || hour < 6 ? "Chill" : "Upbeat"
        let pool = Music.all.filter { $0.mood == mood }
        return pool.isEmpty ? nil : pool[songSeed % pool.count]
    }
    @State private var grab = Grab()   // what fingers have hold of on the story, and what they've done to it
    // something placed, being moved
    @State private var active: Int?
    @State private var snapX = false
    @State private var snapY = false
    @State private var overBin = false
    // text being written
    @State private var editing: Int?
    @State private var draft = ""
    @State private var font = "classic"
    @State private var color = "FFFFFF"
    @State private var highlight = false
    @State private var align = "center"
    @State private var glow = false
    @State private var size: Double = 30
    @FocusState private var typing: Bool
    // drawing
    @State private var pen = "pen"
    @State private var penColor = "FFFFFF"
    @State private var penWidth: Double = 0.014
    // video
    @State private var muted = false
    @State private var length: Double = 0
    @State private var range: ClosedRange<Double> = 0...30
    @State private var scrub: Double?   // the moment under a finger on the trim strip
    @State private var grabbed: Double?   // where an end of the trim was when a finger caught it
    @State private var frames: [UIImage] = []
    @State private var poster: UIImage?   // the video's first frame, shown while the player gets going
    // sheets
    @State private var stickers = false
    @State private var picked: String?   // a tile from the tray, added once the tray has closed
    @State private var food = false
    @State private var polling = false
    @State private var mentioning = false
    @State private var typingSticker: String?   // a question or a hashtag being typed in
    @State private var stickerText = ""
    @State private var note: String?
    @State private var canvasWidth: CGFloat = 360
    @State private var history: [(items: [JSON], strokes: [JSON])] = []   // for Undo, newest last
    @State private var leaving = false   // ✕ with changes: ask first
    private var stories: Stories { Stories.shared }

    var body: some View {
        GeometryReader { screen in
            // as big as the screen allows: the button under it takes 58, and the two of them go down into the strip
            // kept clear for the home bar, stopping 12 short of the bottom (96 was held back before, and none of
            // that strip used, which left a tall clip small with black all round it)
            let low = max(0, screen.safeAreaInsets.bottom - 22)   // 22 clear of the bottom: at 12 the home bar lay across the button
            // The picture has a space of its own that never changes size, and sits in the middle of it whatever its
            // shape. The tools and the button are under that space, the X at its top: before, all of them were hung
            // on the picture, so a wide clip pulled them up the screen and a narrow one squeezed the button.
            // Only the button is under the picture's space now: the row of tools lies over the bottom of it, as
            // Instagram's tools lie over its picture. That gives a tall 9:16 picture the screen's whole width, which
            // is the size Instagram shows it at; with the tools taking a row of their own it came out narrower.
            let stageH = max(120, screen.size.height + low - 70)
            let cw = min(screen.size.width, stageH * ratio)   // 66 more for the row of tools
            let ch = cw / ratio
            VStack(spacing: 10) {
                canvas(cw, ch)
                    .frame(width: cw, height: ch)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: mode == .text ? .top : .bottom) { tray(cw).padding(mode == .text ? .top : .bottom, mode == .text ? 64 : 12) }
                    .overlay(alignment: .leading) { if mode == .text || mode == .draw { sizeSlider.padding(.leading, 8) } }
                    .overlay {
                        if stories.posting {
                            ZStack {
                                Color.black.opacity(0.55)
                                VStack(spacing: 12) {
                                    ProgressView().controlSize(.large).tint(.white)
                                    Text(video != nil ? "Sharing your video…" : "Sharing your story…").font(.headline).foregroundStyle(.white)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: stories.posting)
                    .frame(width: screen.size.width, height: stageH)
                    // X and Done sit inside the picture when it reaches the top of its space (they straddled its
                    // rounded corner), and across the screen when it's a short one with black above it
                    .overlay(alignment: .top) { topBar.padding(.horizontal, 14).padding(.top, 12).frame(width: ch >= stageH - 1 && cw >= 250 ? cw : screen.size.width) }
                    // the tools over the bottom of that space; out of the way while one is in use or something's being dragged to the bin
                    .overlay { if mixing { Color.black.opacity(0.001).onTapGesture { withAnimation(.snappy(duration: 0.22)) { mixing = false } } } }
                    .overlay(alignment: .bottom) {
                        if mixing {
                            mixPanel.frame(width: min(screen.size.width - 20, 430)).padding(.bottom, 10)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            toolbar.frame(width: screen.size.width).padding(.bottom, 10)
                                .opacity(mode == .none && active == nil ? 1 : 0).allowsHitTesting(mode == .none && active == nil)
                        }
                    }
                bottomBar.frame(width: screen.size.width - 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: low / 2)   // what's taller than the safe part hangs below it, not half above
            .task(id: cw) { canvasWidth = cw }
        }
        // the keyboard slides over the story rather than squashing it
        .ignoresSafeArea(.keyboard)
        .background(Color.black.ignoresSafeArea())
        .onAppear { KeyboardDone.quiet = true }
        .onDisappear { KeyboardDone.quiet = false }
        .confirmationDialog("Discard your edits?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { close() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("Your text, stickers and drawing will be lost.") }
        .statusBarHidden()
        // Before it's first drawn: the shape it was left in, the clip's first picture and how it sits in the frame,
        // and the tool it was opened for. Each of these used to arrive a moment after the editor had come up (the
        // frame changing shape, the picture popping in and resizing, the tool's tray opening late), which is what
        // flickered.
        .onAppear {
            if shape == nil, let startShape { shape = startShape }
            if poster == nil, let startPoster { poster = startPoster; seat(startPoster.size) }
            switch startTool {
            case "draw": mode = .draw
            case "filters": mode = .filters
            case "adjust": mode = .adjust
            default: break
            }
        }
        .task { await prepare() }
        // The song starts once the list of songs has really gone. Started half a second after the pick, as it was,
        // the list could still be on its way out, and its going stops whatever is playing: the new song with it.
        .sheet(isPresented: $choosingSong, onDismiss: {
            let fresh = justPicked; justPicked = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let s = song else { return }
                SongPlayer.shared.play(s, key: "story-edit", loop: true, volume: songLevel)
                if fresh, postSong != nil { withAnimation(.snappy(duration: 0.22)) { mixing = true } }   // a post's video: straight on to how loud each is
            }
        }) {
            SongPicker { picked in setSong(picked); justPicked = true }
        }
        .onAppear { if video != nil { SongPlayer.shared.heard(true) } }
        .task {
            // back in the editor with a song already on the post: heard again with the video
            if let s = postSong?.wrappedValue { SongPlayer.shared.play(s, key: "story-edit", loop: true, volume: songLevel) }
        }
        .onDisappear { SongPlayer.shared.heard(false); SongPlayer.shared.stop() }
        .onChange(of: look, initial: true) { _, l in lookBox.name = l }
        .task { if startWriting { try? await Task.sleep(for: .milliseconds(350)); newText(); size = 40 } }
        .task {
            guard let startTool else { return }
            try? await Task.sleep(for: .milliseconds(450))
            switch startTool {
            case "text": newText()
            case "stickers": stickers = true
            default: break   // the others are set as it appears
            }
        }
        .task(id: flatLook + (sliding ? " " : "")) { await refilter(flatLook) }
        .sheet(isPresented: $stickers, onDismiss: { if let p = picked { picked = nil; add(p) } }) {
            StickerSheet(forPost: forPost, pick: { id in picked = id; stickers = false }, place: { o in stickers = false; place(o) })
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $food) { FoodStickerPicker { it in addFood(it) }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $polling) { PollMaker { q, a, b in place(["type": "poll", "q": q, "a": a, "b": b]) }.presentationDetents([.medium]) }
        .alert(typingSticker == "question" ? "Ask a question" : "Hashtag", isPresented: Binding(get: { typingSticker != nil }, set: { if !$0 { typingSticker = nil } })) {
            TextField(typingSticker == "question" ? "Ask me anything" : "mealprep", text: $stickerText)
            Button("Add") {
                let t = stickerText.trimmingCharacters(in: .whitespacesAndNewlines)
                if typingSticker == "question" { place(["type": "question", "q": String(t.isEmpty ? "Ask me anything" : t).prefix(80).description]) }
                else if !t.isEmpty { place(["type": "hashtag", "text": String(t.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "").prefix(30))]) }
                typingSticker = nil
            }
            Button("Cancel", role: .cancel) { typingSticker = nil }
        }
        .sheet(isPresented: $mentioning) { MentionPicker { id, name in place(["type": "mention", "user": id, "name": name]) }.presentationDetents([.medium, .large]) }
        .overlay(alignment: .top) {
            if let note { Text(note).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule()).padding(.top, 60) }
        }
    }

    // MARK: the story itself

    @ViewBuilder private func canvas(_ cw: CGFloat, _ ch: CGFloat) -> some View {
        ZStack {
            Color(white: 0.08)
            if let video {
                if clipOnly {
                    // a post's clip: its whole picture behind the frame, to pinch and drag like a photo
                    let f = clipFill(cw, ch)
                    MovableClip(cw: cw, ch: ch, fill: f, scale: bgScale, offset: bgOffset, spin: bgSpin, movable: mode == .none, free: true, grab: grab) {
                        ZStack {
                            if let poster { Image(uiImage: poster).resizable().scaledToFill().frame(width: f.width, height: f.height).clipped() }
                            // turned on its side, the player is laid out sideways and then turned to stand in the frame
                            LoopingVideo(url: video, paused: false, muted: muted, filter: look, range: length > 0 && mode != .trim ? range : nil, scrub: mode == .trim ? scrub : nil, always: true, box: lookBox, volume: clipLevel)
                                .frame(width: turns % 2 == 1 ? f.height : f.width, height: turns % 2 == 1 ? f.width : f.height)
                                .rotationEffect(.degrees(Double(turns) * 90))
                        }
                        .frame(width: f.width, height: f.height)
                    }
                } else {
                if let poster { Image(uiImage: poster).resizable().scaledToFill().frame(width: cw, height: ch).clipped() }
                LoopingVideo(url: video, paused: mode == .text, muted: muted, filter: look, range: length > 0 && mode != .trim ? range : nil, scrub: mode == .trim ? scrub : nil, always: true, box: lookBox, volume: clipLevel)
                }
            } else if let shown = (comparing ? nil : preview) ?? work ?? image {
                // the photo moves on its own too, and tells the editor only when the finger lifts
                let k = max(cw / max(1, shown.size.width), ch / max(1, shown.size.height))
                let full = CGSize(width: shown.size.width * k, height: shown.size.height * k)
                // Straighten: turned about its middle and grown just enough that no corner comes up empty, as the
                // finished picture is
                let tilt = comparing ? 0 : (tune["t"] ?? 0), lean = abs(tilt) * Double.pi / 180
                let grow = CGFloat(cos(lean) + Double(max(full.width / max(full.height, 1), full.height / max(full.width, 1))) * sin(lean))
                MovableClip(cw: cw, ch: ch, fill: full, scale: bgScale, offset: bgOffset, spin: bgSpin,
                            movable: mode == .none || mode == .filters, photo: true, grab: grab) {
                    Image(uiImage: shown).resizable().frame(width: full.width, height: full.height)
                        .rotationEffect(.degrees(tilt)).scaleEffect(grow)
                        .frame(width: full.width, height: full.height).clipped()
                }
            }
            if mode == .adjust && video == nil {
                // a finger held on the photo shows it as it came, to compare
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in comparing = true }.onEnded { _ in comparing = false })
            }
            StoryDrawing(strokes: strokes + (current.isEmpty ? [] : [stroke(current, cw, ch)]))
            ForEach(items.indices, id: \.self) { i in placed(i, cw, ch) }
            if snapX { Rectangle().fill(Color.yellow.opacity(0.9)).frame(width: 1.5).allowsHitTesting(false) }
            if snapY { Rectangle().fill(Color.yellow.opacity(0.9)).frame(height: 1.5).allowsHitTesting(false) }
            if active != nil {
                // the bin: dark glass with a fine edge while something's being carried; as the thing comes over it, it
                // swells and turns red, its lid shuts, and the thing itself draws in
                ZStack {
                    Circle().fill(overBin
                        ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.32), Color(red: 0.82, green: 0.1, blue: 0.16)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(.ultraThinMaterial))
                    Circle().strokeBorder(.white.opacity(overBin ? 0.9 : 0.35), lineWidth: 1.5)
                    Image(systemName: overBin ? "trash.fill" : "trash").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 58, height: 58)
                .scaleEffect(overBin ? 1.3 : 1)
                .shadow(color: overBin ? Color.red.opacity(0.55) : Color.black.opacity(0.35), radius: overBin ? 18 : 8, y: 3)
                .environment(\.colorScheme, .dark)
                .position(x: cw / 2, y: ch - 70).allowsHitTesting(false)
                .animation(.spring(response: 0.28, dampingFraction: 0.62), value: overBin)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            // every touch on the story while nothing else is open: which thing it's on is worked out from where it
            // landed, and the fingers are followed from there (a swipe across a picture that can't move changes the filter)
            if mode == .none || mode == .filters {
                EditorTouch(began: { grabBegan($0, cw, ch) },
                            changed: { move, size, turn, fingers in grabChanged(move, size, turn, fingers, cw, ch) },
                            ended: { moved, _ in grabEnded(moved, cw, ch) })
            }
            if mode == .draw { drawCatcher(cw, ch) }
            if mode == .text { textEditor(cw) }
        }
    }

    /// Something placed: drawn where it is, or where the fingers holding it have taken it.
    private func placed(_ i: Int, _ cw: CGFloat, _ ch: CGFloat) -> some View {
        PlacedItem(o: items[i], index: i, cw: cw, ch: ch, hidden: editing == i, dim: active == i && overBin, grab: grab, lookKey: PlacedItem.lookKey(items[i], cw), tap: { tapped(i) })
    }

    // MARK: fingers on the story

    /// The thing placed that a finger at this point is on (the topmost, if they overlap): the point is turned and
    /// sized back into the item's own space, where it's a plain rectangle, with 30 points to spare all round so
    /// small text is easy to catch.
    private func itemAt(_ p: CGPoint, _ cw: CGFloat, _ ch: CGFloat) -> Int? {
        let k = Double(cw / StoryArt.design)
        for i in items.indices.reversed() where i != editing {
            guard let size = grab.sizes[i] else { continue }
            let o = items[i]
            let dx = Double(p.x) - (num(o["x"]) ?? 0.5) * Double(cw), dy = Double(p.y) - (num(o["y"]) ?? 0.5) * Double(ch)
            let a = -(num(o["rotation"]) ?? 0) * Double.pi / 180, eff = (num(o["scale"]) ?? 1) * k
            let lx = dx * cos(a) - dy * sin(a), ly = dx * sin(a) + dy * cos(a)
            if abs(lx) <= Double(size.width) * eff / 2 + 30, abs(ly) <= Double(size.height) * eff / 2 + 30 { return i }
        }
        return nil
    }

    /// The size the picture behind is when it just fills the frame; nil when it can't be moved (a story's video, or no picture).
    private func bgFill(_ cw: CGFloat, _ ch: CGFloat) -> CGSize? {
        if video != nil { return clipOnly && mode == .none ? clipFill(cw, ch) : nil }
        guard let shown = work ?? image else { return nil }
        let k = max(cw / max(1, shown.size.width), ch / max(1, shown.size.height))
        return CGSize(width: shown.size.width * k, height: shown.size.height * k)
    }

    /// What a finger has landed on, and (the answer) where its middle is, for it to be sized and turned about the
    /// fingers: a thing placed, or the picture behind when that can be moved.
    private func grabBegan(_ p: CGPoint, _ cw: CGFloat, _ ch: CGFloat) -> CGPoint? {
        grab.letGo()
        let t = mode == .none ? (itemAt(p, cw, ch) ?? -1) : -1
        grab.target = t
        if t >= 0, items.indices.contains(t) {
            // a text reading "touchlog": the fingers' readings are written down for measuring (see TouchLog)
            if str(items[t]["text"]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == "touchlog" {
                TouchLog.on = true
                TouchLog.head = "touchlog v1 cw=\(cw) ch=\(ch) x=\(num(items[t]["x"]) ?? 0.5) y=\(num(items[t]["y"]) ?? 0.5) scale=\(num(items[t]["scale"]) ?? 1) rot=\(num(items[t]["rotation"]) ?? 0) size=\(grab.sizes[t] ?? .zero)"
            }
            return CGPoint(x: (num(items[t]["x"]) ?? 0.5) * Double(cw), y: (num(items[t]["y"]) ?? 0.5) * Double(ch))
        }
        guard bgFill(cw, ch) != nil else { return nil }
        return CGPoint(x: cw / 2 + bgOffset.width, y: ch / 2 + bgOffset.height)
    }

    private func grabChanged(_ move: CGSize, _ size: CGFloat, _ turn: CGFloat, _ fingers: Int, _ cw: CGFloat, _ ch: CGFloat) {
        guard let t = grab.target else { return }
        if t >= 0, items.indices.contains(t) {
            if active != t { remember(); active = t }
            grab.move = move; grab.size = size; grab.turn = Double(turn) * 180 / Double.pi; grab.fingers = fingers
            // the lines down and across the middle, and the bin, as it comes to them
            let r = PlacedItem.resting(items[t], move: move, size: size, turn: grab.turn, fingers: fingers, cw: cw, ch: ch)
            let bin = hypot(r.x * Double(cw) - Double(cw) / 2, r.y * Double(ch) - Double(ch - 70)) < 70
            if r.sx != snapX || r.sy != snapY { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            if bin != overBin { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            if r.straight != straight { straight = r.straight; if r.straight, turn != 0 { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
            if r.sx != snapX { snapX = r.sx }
            if r.sy != snapY { snapY = r.sy }
            if bin != overBin { overBin = bin }
        } else {
            grab.move = move; grab.size = size; grab.turn = Double(turn) * 180 / Double.pi; grab.fingers = fingers
        }
    }

    private func grabEnded(_ moved: Bool, _ cw: CGFloat, _ ch: CGFloat) {
        defer { grab.letGo(); straight = false }
        guard let t = grab.target else { return }
        if t >= 0 {
            guard items.indices.contains(t) else { return }
            guard moved else { grab.letGo(); tapped(t); return }
            // written down from the same sum that was showing it, in the same breath as the fingers' hold is let go
            let r = PlacedItem.resting(items[t], move: grab.move, size: grab.size, turn: grab.turn, fingers: grab.fingers, cw: cw, ch: ch)
            items[t]["x"] = r.x; items[t]["y"] = r.y; items[t]["scale"] = r.scale; items[t]["rotation"] = r.rotation
            grab.letGo()
            dropped(t)
            return
        }
        guard moved else { return }
        let across = abs(grab.move.width) > 50 && abs(grab.move.width) > abs(grab.move.height) && grab.size == 1
        guard let fill = bgFill(cw, ch) else {
            if across { nextFilter(grab.move.width < 0 ? 1 : -1) }   // a picture that can't move: a swipe changes the filter
            return
        }
        let photo = video == nil
        let deg = clipSettled(bgSpin + grab.turn), sc = bgScale * grab.size
        guard MovableClip<EmptyView>.pans(photo: photo, scale: sc, deg: deg, fingers: grab.fingers) else {
            if across { nextFilter(grab.move.width < 0 ? 1 : -1) }
            return
        }
        let end = clipClamped(sc, CGSize(width: bgOffset.width + grab.move.width, height: bgOffset.height + grab.move.height), deg, fill: fill, cw: cw, ch: ch, free: !photo)
        if !photo { moveClip(end.scale, end.offset, deg, cw: cw, ch: ch) }
        else if end.scale <= 1.01 && deg == 0 { withAnimation(.snappy) { bgScale = 1; bgOffset = .zero; bgSpin = 0 } }
        else { bgScale = end.scale; bgOffset = end.offset; bgSpin = deg }
    }
    @State private var straight = false   // the thing held is caught at straight: for the tick felt as it gets there

    private func dropped(_ i: Int) {
        if overBin, items.indices.contains(i) { UINotificationFeedbackGenerator().notificationOccurred(.warning); withAnimation(.snappy(duration: 0.25)) { _ = items.remove(at: i) } }
        active = nil; overBin = false; snapX = false; snapY = false
    }

    private func tapped(_ i: Int) {
        let o = items[i]
        switch str(o["type"]) {
        case "text":
            editing = i; draft = str(o["text"]); font = str(o["font"]).isEmpty ? "classic" : str(o["font"])
            color = str(o["color"]).isEmpty ? "FFFFFF" : str(o["color"]); highlight = o["bg"] as? Bool ?? false
            align = str(o["align"]).isEmpty ? "center" : str(o["align"]); glow = o["glow"] as? Bool ?? false; size = num(o["size"]) ?? 30
            mode = .text; typing = true
        case "food":
            remember(); UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.2)) { items[i]["style"] = (Int(num(o["style"]) ?? 0) + 1) % 3 }
        default: break
        }
    }

    private func nextFilter(_ step: Int) {
        let i = StoryArt.filters.firstIndex(of: filter) ?? 0
        let next = StoryArt.filters[(i + step + StoryArt.filters.count) % StoryArt.filters.count]
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeOut(duration: 0.2)) { filter = next }
        flash(next)
    }

    // MARK: tools along the top

    /// Over the picture, only what leaves or undoes: the tools are in a row of their own under it.
    private var topBar: some View { topRow }

    /// A post's video's sound: which song, and the song and the video's own sound each as loud as wanted, set by ear
    /// with the video playing behind.
    private var mixPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: "music.note").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .frame(width: 38, height: 38).background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(song?.title ?? "No song").font(.subheadline.weight(.bold)).lineLimit(1)
                    Text("Song on this video").font(.caption2.weight(.semibold)).opacity(0.6)
                }
                Spacer(minLength: 8)
                Button { withAnimation(.snappy(duration: 0.22)) { mixing = false } } label: {
                    Text("Done").font(.subheadline.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 16).frame(height: 34).background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let postSongVol, let postClipVol {
                LevelBar(symbol: "music.note", name: "Song", value: postSongVol)
                if !muted { LevelBar(symbol: "video.fill", name: "Video", value: postClipVol) }
                else { Text("The video's own sound is off (Sound, in the tools).").font(.caption).opacity(0.6) }
            }
            HStack(spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.22)) { mixing = false }; choosingSong = true } label: {
                    Label("Change song", systemImage: "arrow.triangle.2.circlepath").font(.footnote.weight(.bold))
                        .padding(.horizontal, 13).frame(height: 34).background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                Button { SongPlayer.shared.stop(); setSong(nil); withAnimation(.snappy(duration: 0.22)) { mixing = false } } label: {
                    Label("Remove", systemImage: "trash").font(.footnote.weight(.bold))
                        .padding(.horizontal, 13).frame(height: 34).background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onChange(of: postSongVol?.wrappedValue ?? 1) { _, v in SongPlayer.shared.volume(Float(v)) }
        .accessibilityIdentifier("mix-panel")
    }

    /// The tools, each with its name, in a row under the picture that slides sideways: as bare round icons over the
    /// picture they covered it, and nobody could tell the frame button from the filters one.
    private var toolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if !forPost || postSong != nil { tool("music.note", "Audio", "Audio") { if postSong != nil, song != nil { withAnimation(.snappy(duration: 0.22)) { mixing = true } } else { choosingSong = true } } }
                tool("textformat", "Text", "Text") { newText() }
                tool("face.smiling", "Stickers", "Stickers") { stickers = true }
                tool("scribble.variable", "Draw", "Draw") { mode = .draw }
                tool("camera.filters", "Filter", "Filters") { mode = .filters }
                tool("slider.horizontal.3", "Adjust", "Adjust") { mode = .adjust }
                if forPost && !lockShape { tool("aspectratio", "Shape", "Shape") { nextShape() } }
                if video == nil ? image != nil : clipOnly { tool("rotate.right", "Rotate", "Rotate") { turn() } }
                if video != nil {
                    tool(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", "Sound", muted ? "Sound off" : "Sound on") { muted.toggle(); flash(muted ? "Sound off" : "Sound on") }
                    tool("scissors", "Trim", "Trim") { mode = .trim }
                }
                if !forPost && (image != nil || video != nil) { tool("arrow.down.to.line", "Save", "Save to Photos") { Task { await save() } } }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: 56)
    }

    private func tool(_ symbol: String, _ title: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(height: 22)
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white).frame(width: 64, height: 56)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    /// A quarter turn to the right. A photo is turned itself; a post's clip is shown turned and made that way when
    /// it's posted. The zoom and place start again: they were for the picture as it lay.
    private func turn() {
        UISelectionFeedbackGenerator().selectionChanged()
        if video != nil {
            turns = (turns + 1) % 4
            poster = poster?.quarterTurned()
            frames = frames.map { $0.quarterTurned() }
        } else {
            guard let now = work ?? image else { return }
            work = now.quarterTurned(); lite = lite?.quarterTurned(); preview = nil
            let l = flatLook
            Task { await refilter(l) }
        }
        thumbs = thumbs.mapValues { $0.quarterTurned() }
        withAnimation(.snappy) { bgScale = 1; bgOffset = .zero; bgSpin = 0; clipMove = .zero; clipCovers = true }
    }

    @ViewBuilder private var topRow: some View {
        HStack(spacing: 5) {
            switch mode {
            case .none:
                round("xmark") { if edited { leaving = true } else { close() } }.accessibilityLabel("Back")
                if !history.isEmpty { round("arrow.uturn.backward") { undo() }.accessibilityLabel("Undo") }
                Spacer(minLength: 6)
                if let song {
                    // the song, named at the top: tap its name for another (a post's video: for its volumes too), the x to take it off
                    HStack(spacing: 6) {
                        Button { if postSong != nil { withAnimation(.snappy(duration: 0.22)) { mixing = true } } else { choosingSong = true } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
                                Text(song.title).font(.footnote.weight(.bold)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        Button { SongPlayer.shared.stop(); withAnimation(.snappy) { setSong(nil) } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Take the song off")
                    }
                    .foregroundStyle(.white).padding(.leading, 11).padding(.trailing, 8).frame(height: 34)
                    .background(.black.opacity(0.45), in: Capsule()).frame(maxWidth: 200)
                    Spacer(minLength: 6)
                } else if let idea = suggested {
                    // a song put forward for this story: one tap takes it
                    Button {
                        storySong = idea
                        SongPlayer.shared.play(idea, key: "story-edit", loop: true)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(idea.title).font(.caption.weight(.bold)).lineLimit(1)
                                Text("Suggested song").font(.system(size: 9, weight: .semibold)).opacity(0.75)
                            }
                            Image(systemName: "plus").font(.system(size: 11, weight: .heavy))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 11).frame(height: 34).background(.black.opacity(0.45), in: Capsule()).frame(maxWidth: 200)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Add the suggested song, " + idea.title)
                    Spacer(minLength: 6)
                }
                if image != nil || video != nil || bgScale > 1.01 || bgOffset != .zero || bgSpin != 0 || !items.isEmpty || !strokes.isEmpty {
                Menu {
                    if image != nil || video != nil { Button { Task { await save() } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") } }
                    if bgScale > 1.01 || bgOffset != .zero || bgSpin != 0 { Button { withAnimation { bgScale = 1; bgOffset = .zero; bgSpin = 0; clipMove = .zero; clipCovers = true } } label: { Label(video == nil ? "Reset the photo" : "Reset the video", systemImage: "arrow.counterclockwise") } }
                    if !items.isEmpty || !strokes.isEmpty { Button(role: .destructive) { remember(); withAnimation { items = []; strokes = [] } } label: { Label("Clear everything", systemImage: "trash") } }
                } label: { roundLabel("ellipsis") }
                }
            case .text:
                Spacer()
                round(highlight ? "character.textbox" : "a.square") { highlight.toggle() }.accessibilityLabel("Highlight")
                round(align == "left" ? "text.alignleft" : align == "right" ? "text.alignright" : "text.aligncenter") {
                    align = align == "center" ? "left" : align == "left" ? "right" : "center"
                }.accessibilityLabel("Alignment")
                round(glow ? "sparkles" : "sparkle") { glow.toggle() }.accessibilityLabel("Glow")
                Button("Done") { finishText() }.font(.headline).foregroundStyle(.white).padding(.leading, 6)
            case .draw:
                round("arrow.uturn.backward") { undo() }.disabled(history.isEmpty).opacity(history.isEmpty ? 0.4 : 1).accessibilityLabel("Undo")
                Spacer()
                Button("Done") { mode = .none }.font(.headline).foregroundStyle(.white)
            case .filters, .trim:
                Spacer()
                Button("Done") { mode = .none }.font(.headline).foregroundStyle(.white)
            case .adjust:
                if !tune.isEmpty { Button("Reset") { withAnimation { tune = [:]; settled = [:] } }.font(.headline).foregroundStyle(.white.opacity(0.8)) }
                Spacer()
                Button("Done") { settled = tune; comparing = false; mode = .none }.font(.headline).foregroundStyle(.white)
            }
        }
    }

    /// Before a change: what it was, for Undo (thirty steps back).
    private func remember() {
        history.append((items, strokes))
        if history.count > 30 { history.removeFirst() }
    }
    private func undo() {
        guard let last = history.popLast() else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.22)) { items = last.items; strokes = last.strokes }
    }
    private var edited: Bool { !items.isEmpty || !strokes.isEmpty || filter != "Normal" || !tune.isEmpty || bgScale > 1.01 || bgSpin != 0 || turns != 0 || storySong != nil }

    private func round(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(symbol) }.buttonStyle(.plain)
    }
    private func roundLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            .frame(width: 34, height: 34).background(.black.opacity(0.45), in: Circle())
    }

    // MARK: what sits along the bottom of the story for each tool

    @ViewBuilder private func tray(_ cw: CGFloat) -> some View {
        switch mode {
        case .text:
            VStack(spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(StoryArt.fonts, id: \.self) { f in
                            Button { font = f } label: {
                                Text(StoryArt.fontNames[f] ?? f).font(StoryArt.font(f, 15)).foregroundStyle(font == f ? .black : .white)
                                    .padding(.horizontal, 15).frame(height: 36).background(font == f ? Color.white : Color.white.opacity(0.18), in: Capsule())
                                    .padding(.vertical, 5).padding(.horizontal, 2).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
                swatches($color)
            }
            // The whole band the styles and colours sit in takes touches, and does nothing with the ones that miss.
            // Behind it the picture is one big "tap to finish": a finger landing just beside a colour closed the
            // text instead of changing it.
            .padding(.vertical, 8).frame(maxWidth: .infinity)
            .contentShape(Rectangle()).onTapGesture {}
        case .draw:
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    ForEach([("pen", "pencil.tip"), ("marker", "highlighter"), ("neon", "wand.and.rays"), ("eraser", "eraser")], id: \.0) { p in
                        Button { pen = p.0 } label: {
                            Image(systemName: p.1).font(.system(size: 18, weight: .bold)).foregroundStyle(pen == p.0 ? .black : .white)
                                .frame(width: 44, height: 44).background(pen == p.0 ? Color.white : Color.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(p.0.capitalized)
                    }
                }
                if pen != "eraser" { swatches($penColor) }
            }
        case .filters:
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(StoryArt.filters, id: \.self) { f in
                        Button { withAnimation(.easeOut(duration: 0.2)) { filter = f } } label: {
                            VStack(spacing: 5) {
                                Group {
                                    if let t = thumbs[f] { Image(uiImage: t).resizable().scaledToFill() }
                                    else { LinearGradient(colors: [Color(white: 0.3), Color(white: 0.15)], startPoint: .top, endPoint: .bottom) }
                                }
                                .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(filter == f ? Color.white : .clear, lineWidth: 2.5).padding(-3))
                                Text(f).font(.caption2.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        case .adjust:
            adjuster
        case .trim:
            trimmer(cw - 24)
        case .none:
            EmptyView()
        }
    }

    /// Adjust: the tools in a row, and over them the slider for the one picked. Tapping its number puts it back.
    private var adjuster: some View {
        VStack(spacing: 8) {
            if let k = tool, let spec = StoryArt.tunes.first(where: { $0.0 == k }) {
                TuneSlider(name: spec.1, degrees: k == "t", lo: spec.3, hi: spec.4, value: tune[k] ?? 0,
                           changed: { v in
                               if video != nil {
                                   // a clip: straight to the frames being drawn; this screen isn't told until the finger lifts
                                   var t = tune; t[k] = v == 0 ? nil : v
                                   lookBox.name = StoryArt.look(filter, t)
                               } else { tune[k] = v == 0 ? nil : v }
                           },
                           sliding: { on in if video == nil { sliding = on } },
                           done: { v in tune[k] = v == 0 ? nil : v; settled = tune })
                    .id(k)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(StoryArt.tunes, id: \.0) { t in
                        let on = tool == t.0, changed = (tune[t.0] ?? 0) != 0
                        Button { withAnimation(.snappy(duration: 0.2)) { tool = on ? nil : t.0 } } label: {
                            VStack(spacing: 5) {
                                Image(systemName: t.2).font(.system(size: 18, weight: .semibold)).foregroundStyle(on ? .black : .white)
                                    .frame(width: 46, height: 46).background(on ? Color.white : Color.black.opacity(0.55), in: Circle())
                                    .overlay(Circle().stroke(Theme.accent, lineWidth: changed && !on ? 2 : 0))
                                Text(t.1).font(.caption2.weight(.bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3)
                            }
                            .frame(width: 66)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func swatches(_ value: Binding<String>) -> some View {
        HStack(spacing: 0) {
            ForEach(StoryArt.colors, id: \.self) { c in
                Button { UISelectionFeedbackGenerator().selectionChanged(); value.wrappedValue = c } label: {
                    Circle().fill(StoryArt.color(c)).frame(width: 28, height: 28)
                        .overlay(Circle().stroke(.white, lineWidth: value.wrappedValue == c ? 3 : 1.5))
                        .scaleEffect(value.wrappedValue == c ? 1.15 : 1)
                        .frame(width: 40, height: 46).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Size for text, line width for drawing: the slider down the left, as Instagram has it.
    private var sizeSlider: some View {
        let binding = mode == .text
            ? Binding(get: { (size - 16) / 44 }, set: { size = 16 + $0 * 44 })
            : Binding(get: { (penWidth - 0.004) / 0.036 }, set: { penWidth = 0.004 + $0 * 0.036 })
        return GeometryReader { g in
            ZStack(alignment: .bottom) {
                Capsule().fill(LinearGradient(colors: [.white, .white.opacity(0.25)], startPoint: .top, endPoint: .bottom)).frame(width: 6)
                Circle().fill(.white).frame(width: 24, height: 24).shadow(radius: 3)
                    .offset(y: -binding.wrappedValue * (g.size.height - 24))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in binding.wrappedValue = min(1, max(0, 1 - (v.location.y - 12) / (g.size.height - 24))) })
        }
        .frame(width: 30, height: 230)
        .accessibilityElement().accessibilityLabel(mode == .text ? "Text size" : "Line width")
        .accessibilityAdjustableAction { d in binding.wrappedValue = min(1, max(0, binding.wrappedValue + (d == .increment ? 0.1 : -0.1))) }
    }

    // MARK: text

    private func newText() {
        editing = nil; draft = ""; font = "classic"; color = "FFFFFF"; highlight = false; align = "center"; glow = false; size = 30
        mode = .text; typing = true
    }

    private func textEditor(_ cw: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture { finishText() }
            let k = cw / StoryArt.design, glows = glow || font == "neon"
            TextField("", text: $draft, prompt: Text("Type something").foregroundStyle(.white.opacity(0.5)), axis: .vertical)
                .focused($typing)
                .font(StoryArt.font(font, size * k))
                .foregroundStyle(highlight ? StoryArt.onColor(color) : StoryArt.color(color))
                .tint(highlight ? StoryArt.onColor(color) : .white)
                .multilineTextAlignment(align == "left" ? .leading : align == "right" ? .trailing : .center)
                .padding(.horizontal, highlight ? 12 * k : 0).padding(.vertical, highlight ? 6 * k : 0)
                .background { if highlight { RoundedRectangle(cornerRadius: 10 * k, style: .continuous).fill(StoryArt.color(color)) } }
                .shadow(color: glows ? StoryArt.color(color).opacity(0.9) : (highlight ? .clear : .black.opacity(0.45)), radius: glows ? 10 * k : 4 * k)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330 * k)
                .offset(y: -cw * 0.25)
                .animation(.snappy(duration: 0.2), value: highlight)
        }
    }

    private func finishText() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty || editing != nil { remember() }
        let o: [String: Any] = ["type": "text", "text": String(t.prefix(200)), "font": font, "color": color, "bg": highlight, "align": align, "glow": glow, "size": size]
        if let i = editing, items.indices.contains(i) {
            if t.isEmpty { items.remove(at: i) } else { items[i].merge(o) { _, n in n } }
        } else if !t.isEmpty {
            var n = o; n["x"] = 0.5; n["y"] = 0.38; n["scale"] = 1.0; n["rotation"] = 0.0
            items.append(n)
        }
        editing = nil; draft = ""; typing = false; mode = .none
    }

    // MARK: drawing

    private func drawCatcher(_ cw: CGFloat, _ ch: CGFloat) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if let last = current.last, hypot(last.x - v.location.x, last.y - v.location.y) < 2.5 { return }
                    current.append(v.location)
                }
                .onEnded { _ in if !current.isEmpty { remember(); strokes.append(stroke(current, cw, ch)) }; current = [] })
    }

    private func stroke(_ pts: [CGPoint], _ cw: CGFloat, _ ch: CGFloat) -> JSON {
        ["kind": pen, "color": penColor, "width": penWidth, "points": pts.map { [Double($0.x / cw), Double($0.y / ch)] }]
    }

    // MARK: stickers

    private func add(_ pick: String) {
        let s = Store.shared
        switch pick {
        // these open their own sheet once the sticker tray has gone
        case "food": food = true
        case "poll": polling = true
        case "mention": mentioning = true
        case "macros":
            let m = s.macros(s.todayItems)
            place(["type": "macros", "p": Int(m.p), "c": Int(m.c), "f": Int(m.f), "kcal": Int(s.eaten)])
        case "streak": place(["type": "streak", "days": s.streakInfo.days])
        case "left": place(["type": "left", "kcal": Int(max(0, s.left))])
        case "workout":
            if let w = s.todayWorkouts.last {
                place(["type": "workout", "name": str(w["name"]), "minutes": Int(num(w["minutes"]) ?? 0), "detail": "\(list(w["lifts"]).count) exercises"])
            } else { flash("No workout today yet") }
        case "time": place(["type": "time", "text": Date().formatted(date: .omitted, time: .shortened)])
        case "ring": place(["type": "ring", "eaten": Int(s.eaten), "budget": Int(s.budgetToday)])
        case "steps": place(["type": "steps", "steps": Steps.shared.today ?? 0])
        case "badge":
            if let id = StickerSheet.latestBadge { place(["type": "badge", "id": id]) } else { flash("Earn a badge first") }
        case "rank": place(["type": "rank", "level": s.rank.level])
        case "cheat":
            if let d = StickerSheet.daysToCheat { place(["type": "cheat", "days": d]) } else { flash("Set a cheat day first") }
        case "question", "hashtag": typingSticker = pick; stickerText = ""
        case "place":
            Task {
                if let sub = await Locator.shared.suburb() { place(["type": "place", "text": sub]) } else { flash("Couldn't find your suburb") }
            }
        default: place(["type": "emoji", "text": pick])
        }
    }

    private func addFood(_ it: JSON) {
        let m = Store.shared.macros([it])
        place(["type": "food", "name": str(it["name"]), "kcal": Int(num(it["kcal"]) ?? 0), "p": Int(m.p), "style": 0])
    }

    private func place(_ o: JSON) {
        remember(); UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        var n = o
        n["id"] = UUID().uuidString.prefix(8).lowercased(); n["x"] = 0.5; n["y"] = 0.55 + Double(items.count % 3) * 0.06; n["rotation"] = 0.0
        n["scale"] = ["poll", "question"].contains(str(o["type"])) ? 0.9 : 0.75
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { items.append(n) }
    }

    // MARK: video

    /// The clip as a strip of its frames, with a white frame round the part kept. The two ends of that frame are
    /// the handles: thick, with an arrow on each, standing outside the frames (inside the strip's rounded corners
    /// they were cut off and hard to catch) and taking a touch well beyond what shows.
    private func trimmer(_ width: CGFloat) -> some View {
        let total = max(length, 0.1), grip: CGFloat = 22, inner = max(1, width - 2 * grip)
        let lo = CGFloat(range.lowerBound / total), hi = CGFloat(range.upperBound / total)
        // a round end shows the picture behind in its corners when a square handle stands right against it
        let endL: CGFloat = lo < 0.01 ? 0 : 9, endR: CGFloat = hi > 0.99 ? 0 : 9
        return VStack(spacing: 10) {
            Text(scrub.map { "At \(clock($0))" } ?? "\(clock(range.lowerBound)) – \(clock(range.upperBound)) · \(max(1, Int(range.upperBound) - Int(range.lowerBound))) s")
                .font(.caption.weight(.heavy)).foregroundStyle(.white).monospacedDigit()
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in Image(uiImage: frames[i]).resizable().scaledToFill().frame(width: inner / CGFloat(max(1, frames.count)), height: 52).clipped() }
                }
                .frame(width: inner, height: 52).background(Color(white: 0.2))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: endL, bottomLeadingRadius: endL, bottomTrailingRadius: endR, topTrailingRadius: endR, style: .continuous))
                // a finger along the strip looks through the clip: it holds on that moment, and plays on from it after
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                    .onChanged { v in scrub = min(length, max(0, Double((v.location.x - grip) / inner) * length)) }
                    .onEnded { _ in scrub = nil })
                .offset(x: grip)
                // outside the kept part, dimmed
                UnevenRoundedRectangle(topLeadingRadius: endL, bottomLeadingRadius: endL, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                    .fill(.black.opacity(0.6)).frame(width: inner * lo, height: 52).offset(x: grip).allowsHitTesting(false)
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: endR, topTrailingRadius: endR, style: .continuous)
                    .fill(.black.opacity(0.6)).frame(width: inner * (1 - hi), height: 52).offset(x: grip + inner * hi).allowsHitTesting(false)
                // a light edge round the whole clip, so where it starts and ends shows against a dark picture
                UnevenRoundedRectangle(topLeadingRadius: endL, bottomLeadingRadius: endL, bottomTrailingRadius: endR, topTrailingRadius: endR, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1)
                    .frame(width: inner, height: 52).offset(x: grip).allowsHitTesting(false)
                // the kept part's top and bottom edges, joining the two handles
                Rectangle().fill(.white).frame(width: inner * (hi - lo) + 2, height: 4).offset(x: grip + inner * lo - 1, y: -28).allowsHitTesting(false)
                Rectangle().fill(.white).frame(width: inner * (hi - lo) + 2, height: 4).offset(x: grip + inner * lo - 1, y: 28).allowsHitTesting(false)
                if let at = scrub { Capsule().fill(Color.yellow).frame(width: 3.5, height: 66).shadow(color: .black.opacity(0.6), radius: 2).offset(x: grip + inner * CGFloat(at / total) - 1.5).allowsHitTesting(false) }
                handle(inner, grip, left: true).offset(x: inner * lo)
                handle(inner, grip, left: false).offset(x: grip + inner * hi)
            }
            .frame(width: width, height: 64, alignment: .leading)   // from the left: centred, everything sat a handle's width to the right
            .coordinateSpace(name: "strip")
        }
    }

    private func handle(_ inner: CGFloat, _ grip: CGFloat, left: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 10 : 0, bottomLeadingRadius: left ? 10 : 0, bottomTrailingRadius: left ? 0 : 10, topTrailingRadius: left ? 0 : 10, style: .continuous)
            .fill(.white).frame(width: grip, height: 60)
            .overlay(Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right").font(.system(size: 20, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
            // a thumb's width to catch it by, not just the sliver that shows
            .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle()).padding(.horizontal, -14).padding(.vertical, -8)
            // measured against the strip, which stays put: against the handle itself, which moves with the finger,
            // it came out as half the distance
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { v in
                // from where the end was when it was caught, by how far the finger has gone: it never jumps to the finger
                let from = grabbed ?? (left ? range.lowerBound : range.upperBound)
                if grabbed == nil { grabbed = from; UISelectionFeedbackGenerator().selectionChanged() }
                let at = min(length, max(0, from + Double(v.translation.width / inner) * length))
                if left { let s = min(at, range.upperBound - 1); range = max(0, max(s, range.upperBound - 30))...range.upperBound }
                else { let e = max(at, range.lowerBound + 1); range = range.lowerBound...min(length, min(e, range.lowerBound + 30)) }
                scrub = left ? range.lowerBound : range.upperBound
            }.onEnded { _ in scrub = nil; grabbed = nil })
            .accessibilityLabel(left ? "Start" : "End")
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    // MARK: getting ready, filters and sharing

    /// A clip far from the frame's shape (one filmed sideways, say) starts whole in the frame, on black, as
    /// Instagram shows it; one near enough starts filling it.
    private func seat(_ size: CGSize) {
        guard clipOnly, startShape == nil, bgScale == 1, bgOffset == .zero, bgSpin == 0 else { return }
        let own = size.width / max(size.height, 1), fits = min(own / ratio, ratio / own)
        if fits < 0.75 { bgScale = max(0.25, fits); clipCovers = false }
    }

    private func prepare() async {
        if shape == nil, let startShape { shape = startShape }
        if let image {
            // made off the main thread: shrinking a camera photo there held the screen black while the editor opened
            let src = image
            let (w, t) = await Task.detached(priority: .userInitiated) { () -> (UIImage, [String: UIImage]) in
                let long = max(src.size.width, src.size.height), k = min(1, 1920 / long)
                let w = k < 1 ? (src.preparingThumbnail(of: CGSize(width: src.size.width * k, height: src.size.height * k)) ?? src) : src
                let small = src.preparingThumbnail(of: CGSize(width: 140, height: 140 / src.size.width * src.size.height)) ?? src
                var t: [String: UIImage] = [:]
                for f in StoryArt.filters { t[f] = StoryArt.filtered(small, f) }
                return (w, t)
            }.value
            work = w; thumbs = t
            let long = max(w.size.width, w.size.height)
            if long > 1100 { lite = await w.byPreparingThumbnail(ofSize: CGSize(width: w.size.width * 1100 / long, height: w.size.height * 1100 / long)) }
        }
        if let video {
            let asset = AVURLAsset(url: video)
            length = (try? await asset.load(.duration).seconds) ?? 0
            range = 0...min(length, 30)
            // Its first frame straight away, behind the player, so there's never a black screen while it loads; then
            // eight along it for the trim strip and one for the filters' little pictures. Each is asked for the way
            // the cover picker asks (near the moment wanted, not "any frame you like"), and if none comes back the
            // lot is asked for again a moment later: asked once, as the player was starting, they sometimes all
            // failed, and the strip and the filters stayed blank.
            let plain = ClipEdit()
            if poster == nil, let first = await plain.still(video, at: 0, width: 1920) {
                poster = first
                seat(first.size)
            }
            var got: [UIImage] = []
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(700)) }
                if Task.isCancelled { return }
                got = []
                for i in 0..<8 {
                    if let f = await plain.still(video, at: min(max(0, length - 0.1), length * Double(i) / 8), width: 200) { got.append(f); frames = got }
                }
                if !got.isEmpty { break }
            }
            if poster == nil, let f = got.first { poster = f }
            if let first = got.first {
                let t = await Task.detached(priority: .userInitiated) { () -> [String: UIImage] in
                    var t: [String: UIImage] = [:]; for f in StoryArt.filters { t[f] = StoryArt.filtered(first, f) }; return t
                }.value
                thumbs = t
            }
        }
    }

    /// The photo through the look. A slider asks many times a second: each asking waits a moment and gives way to
    /// the next, so only the latest is drawn.
    private func refilter(_ f: String) async {
        guard let src = (sliding ? lite : nil) ?? work ?? image else { return }
        if f == "Normal" { preview = nil; return }
        try? await Task.sleep(for: .milliseconds(12))
        if Task.isCancelled { return }
        let out = await Task.detached { StoryArt.filtered(src, f) }.value
        if !Task.isCancelled { preview = out }
    }

    /// The photo as framed (zoom, position, filter), 1080 wide (1920 high for a story); what's placed on it stays
    /// sharp as its own layer.
    private func framedPhoto(_ cw: CGFloat) -> UIImage? {
        // made afresh from the full photo, Straighten and all: what's on screen may be the smaller copy, turned as a view
        guard let plain = work ?? image else { return nil }
        let base = look == "Normal" ? plain : StoryArt.filtered(plain, look)
        let ch = cw / ratio, k = 1080 / cw, oh = (1080 / ratio).rounded()
        let fill = max(cw / base.size.width, ch / base.size.height) * bgScale
        let w = base.size.width * fill, h = base.size.height * fill
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1080, height: oh), format: format).image { c in
            UIColor(white: 0.08, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1080, height: oh))
            // about its own middle, where it was carried to: turned there, then drawn at its size
            c.cgContext.translateBy(x: (cw / 2 + bgOffset.width) * k, y: (ch / 2 + bgOffset.height) * k)
            c.cgContext.rotate(by: CGFloat(bgSpin) * .pi / 180)
            base.draw(in: CGRect(x: -w * k / 2, y: -h * k / 2, width: w * k, height: h * k))
        }
    }

    private var everything: [JSON] {
        (strokes.isEmpty ? [] : [["type": "drawing", "strokes": strokes]]) + items
            + (storySong.map { [["type": "song", "id": $0.id, "title": $0.title] as JSON] } ?? [])
    }

    @ViewBuilder private var bottomBar: some View {
        if let finishVideo {
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                finishVideo(ClipEdit(look: look, range: length > 0 ? range : nil, muted: muted, crop: clipCovers ? clipCrop : nil, shape: ratio, overlay: overlayPicture(), turns: turns, spin: bgSpin, zoom: bgScale, move: clipMove, loose: !clipCovers))
            } label: {
                Text("Next").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 13).background(.white, in: Capsule())
            }
            .buttonStyle(.plain).disabled(mode != .none).opacity(mode == .none ? 1 : 0.3)
        } else if forPost {
            Button {
                if let out = baked() { UINotificationFeedbackGenerator().notificationOccurred(.success); finish?(out) }
            } label: {
                Text("Next").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 13).background(.white, in: Capsule())
            }
            .buttonStyle(.plain).disabled(mode != .none).opacity(mode == .none ? 1 : 0.3)
        } else { storyButtons }
    }

    private var storyButtons: some View {
        HStack(spacing: 10) {
            Button { share("friends") } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.2.fill").font(.system(size: 10, weight: .black)).foregroundStyle(Theme.onAccent).frame(width: 22, height: 22).background(Theme.accent, in: Circle())
                    Text("Friends only").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 11).background(Color(white: 0.14), in: Capsule())
            }
            Button { share("all") } label: {
                HStack(spacing: 8) {
                    Avatar(id: Profiles.shared.me, size: 24)
                    Text(stories.posting ? "Sharing…" : "Your story").font(.subheadline.weight(.heavy)).foregroundStyle(.black)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.subheadline.weight(.black)).foregroundStyle(.black)
                }
                .padding(.horizontal, 12).padding(.vertical, 9).background(.white, in: Capsule())
            }
        }
        .buttonStyle(.plain).disabled(stories.posting || mode != .none)
        .opacity(mode == .none ? 1 : 0.3)
    }

    private func share(_ audience: String) {
        Task {
            let ok: Bool
            if let video {
                ok = await stories.post(image: nil, video: video, overlays: everything, audience: audience, filter: look, range: length > 0 ? range : nil, muted: muted)
            } else {
                ok = await stories.post(image: framedPhoto(canvasWidth), video: nil, overlays: everything, audience: audience)
            }
            if ok { UINotificationFeedbackGenerator().notificationOccurred(.success); posted() }
            else { flash(stories.error ?? "Couldn't share it") }
        }
    }

    /// What's written, stuck and drawn on a post's clip, as one see-through picture in the frame's shape: the video
    /// is made with it over every frame. Nil when there's nothing on it.
    private func overlayPicture() -> UIImage? {
        guard !everything.isEmpty else { return nil }
        let r = ImageRenderer(content: StoryLayer(items: everything).frame(width: StoryArt.design, height: StoryArt.design / ratio))
        r.scale = 1080 / StoryArt.design; r.isOpaque = false
        return r.uiImage
    }

    /// The photo with everything on it, as one picture: a feed post, or Save to Photos.
    private func baked() -> UIImage? {
        guard let photo = framedPhoto(canvasWidth) else { return nil }
        let layer = ZStack {
            Image(uiImage: photo).resizable()
            StoryLayer(items: everything)
        }
        .frame(width: StoryArt.design, height: StoryArt.design / ratio)
        let r = ImageRenderer(content: layer); r.scale = 1080 / StoryArt.design
        return r.uiImage
    }

    /// The finished story, everything on it, saved as a photo.
    private func save() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { flash("Allow Photos in Settings to save"); return }
        if let video {
            // a video: made as it would be posted (the part kept, the look, its sound on or off) with what's written
            // and drawn laid over it, then handed to Photos
            flash("Saving…")
            let top = overlayPicture()
            guard let (data, _) = try? await Stories.compress(video, filter: look, range: length > 0 ? range : nil, muted: muted, overlay: top) else { flash("Couldn't save it"); return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            guard (try? data.write(to: file)) != nil else { flash("Couldn't save it"); return }
            let saved = (try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file) }) != nil
            try? FileManager.default.removeItem(at: file)
            flash(saved ? "Saved to Photos" : "Couldn't save it")
            return
        }
        guard let out = baked() else { return }
        UIImageWriteToSavedPhotosAlbum(out, nil, nil, nil)
        flash("Saved to Photos")
    }

    private func flash(_ text: String) {
        withAnimation(.snappy) { note = text }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { if note == text { note = nil } } }
    }
}

/// The sticker tray, Instagram's way: each sticker shown as it'll look. Yours, made from your own numbers (your food,
/// macros, a calories ring, steps, streak, latest badge, rank, the cheat-day countdown, a workout), the interactive ones
/// (poll, question, mention), the fun ones (time, place, hashtag); then 3D stickers built in, and GIPHY's.
struct StickerSheet: View {
    var forPost = false
    var pick: (String) -> Void
    var place: (JSON) -> Void
    @State private var q = ""
    @State private var tab = 0
    @State private var gifKind = "stickers"
    @State private var gifs: [JSON] = []
    @State private var limited = false
    @State private var loading = false
    private var store: Store { Store.shared }
    /// Trending stickers and GIFs, kept while the app's open: switching to the tab was a wait every time.
    @MainActor static var kept: [String: [JSON]] = [:]

    static var latestBadge: String? { (Store.shared.doc["seenBadges"] as? [String])?.last }
    /// Days until the cheat day, 0 on it; nil when there isn't one.
    static var daysToCheat: Int? {
        guard let c = Store.shared.cheatWeekday else { return nil }
        return (c - DayKey.weekday(Store.shared.today) + 7) % 7
    }

    /// Each of the app's stickers: its name for search, and how it looks with today's numbers.
    private var mine: [(id: String, words: String, sample: JSON)] {
        let m = store.macros(store.todayItems), food = store.todayItems.last
        var out: [(String, String, JSON)] = [
            ("food", "your food meal", ["type": "food", "name": food.map { str($0["name"]) } ?? "Your food", "kcal": Int(num(food?["kcal"]) ?? 410), "p": Int(food.map { store.macros([$0]).p } ?? 33), "style": 0]),
            ("ring", "calories ring today budget", ["type": "ring", "eaten": Int(store.eaten), "budget": Int(store.budgetToday)]),
            ("macros", "macros protein carbs fat", ["type": "macros", "p": Int(m.p), "c": Int(m.c), "f": Int(m.f), "kcal": Int(store.eaten)]),
            ("left", "calories left", ["type": "left", "kcal": Int(max(0, store.left))]),
            ("streak", "streak fire days", ["type": "streak", "days": store.streakInfo.days]),
            ("steps", "steps walk", ["type": "steps", "steps": Steps.shared.today ?? 0]),
        ]
        if let b = Self.latestBadge { out.append(("badge", "badge achievement", ["type": "badge", "id": b])) }
        out.append(("rank", "rank level", ["type": "rank", "level": store.rank.level]))
        if let d = Self.daysToCheat { out.append(("cheat", "cheat day countdown", ["type": "cheat", "days": d])) }
        if let w = store.todayWorkouts.last { out.append(("workout", "workout gym", ["type": "workout", "name": str(w["name"]), "minutes": Int(num(w["minutes"]) ?? 0)])) }
        if !forPost {
            out.append(("poll", "poll vote", ["type": "poll", "q": "Cheat day or not?", "a": "Yes", "b": "No"]))
            out.append(("question", "question ask me anything", ["type": "question", "q": "Ask me anything"]))
            out.append(("mention", "mention friend", ["type": "mention", "name": "friend"]))
        }
        out.append(("time", "time clock", ["type": "time", "text": Date().formatted(date: .omitted, time: .shortened)]))
        out.append(("place", "location place suburb", ["type": "place", "text": "Your suburb"]))
        out.append(("hashtag", "hashtag tag", ["type": "hashtag", "text": "mealprep"]))
        return out.map { (id: $0.0, words: $0.1, sample: $0.2) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tab == 2 ? "Search GIPHY" : "Search stickers", text: $q).autocorrectionDisabled()
                if !q.isEmpty { Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }
            .padding(10).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            // GIFs move, and a post is one still picture, so they're for stories
            Picker("Stickers", selection: $tab) { Text("Yours").tag(0); Text("3D").tag(1); if !forPost { Text("GIPHY").tag(2) } }.pickerStyle(.segmented)
            ScrollView {
                switch tab {
                case 1: threeD
                case 2: giphy
                default: yours
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .padding(.horizontal, 16).padding(.top, 16)
        .task { if !forPost, Self.kept[gifKind] == nil { await loadGifs() } }   // ready before the tab's opened
        .task(id: "\(tab)|\(q)|\(gifKind)") {
            guard tab == 2 else { return }
            if q.isEmpty, let k = Self.kept[gifKind] { gifs = k; return }
            try? await Task.sleep(for: .milliseconds(q.isEmpty ? 0 : 450))   // when typing stops, not every letter: 100 calls an hour
            if !Task.isCancelled { await loadGifs() }
        }
    }

    private var yours: some View {
        let shown = mine.filter { q.isEmpty || $0.words.localizedCaseInsensitiveContains(q) }
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(shown, id: \.id) { s in
                    // the sticker laid out at its own size first, then shrunk: squeezed into the tile it was cut short
                    // ("54-day str…") and spilled into its neighbours; and the tile itself takes the tap (it didn't)
                    // the tile is the size; the sticker sits over it, so a wide one (the poll) can't widen its column
                    Button { pick(s.id) } label: {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.tertiarySystemFill).opacity(0.5))
                            .frame(maxWidth: .infinity).frame(height: 104)
                            .overlay { StoryItem(o: s.sample).fixedSize().scaleEffect(0.5).allowsHitTesting(false) }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("tile-" + s.id)
                }
            }
            if q.isEmpty {
                Text("Emoji").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(Self.emoji, id: \.self) { e in Button { place(["type": "emoji", "text": e]) } label: { Text(e).font(.system(size: 34)) }.buttonStyle(.plain) }
                }
            }
        }
        .padding(.bottom, 20)
    }

    private var threeD: some View {
        let all = BuiltInStickers.all.filter { q.isEmpty || $0.emoji.contains(q) || q.count > 1 && (Self.names[$0.emoji] ?? "").localizedCaseInsensitiveContains(q) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
            ForEach(all, id: \.code) { st in
                Button { place(["type": "sticker3d", "code": st.code]) } label: {
                    Image("sticker-" + st.code).resizable().interpolation(.high).scaledToFit().frame(width: 66, height: 66)
                }
                .buttonStyle(.plain).accessibilityIdentifier("tile-3d")
            }
        }
        .padding(.bottom, 20)
    }

    private var giphy: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Chip(text: "Stickers", on: gifKind == "stickers") { gifKind = "stickers" }
                Chip(text: "GIFs", on: gifKind == "gifs") { gifKind = "gifs" }
                Spacer()
            }
            if limited && gifs.isEmpty {
                Text("GIF search is busy right now. Try the 3D stickers, or again in a bit.").font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.top, 30)
            } else if loading && gifs.isEmpty {
                ProgressView().padding(.top, 40)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(gifs.indices, id: \.self) { i in
                    let g = gifs[i]
                    Button { place(["type": "gif", "url": g["url"] ?? "", "w": g["w"] ?? 200, "h": g["h"] ?? 200]) } label: {
                        // GIPHY's 100-pixel copy in the grid (the 200 one is placed): a quarter of the frames to decode
                        AnimatedGIF(url: str(g["url"]).replacingOccurrences(of: "/200w.gif", with: "/100w.gif"), maxPixel: 200).frame(height: 96).frame(maxWidth: .infinity)
                            .background(gifKind == "stickers" ? Color.clear : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            // GIPHY asks for its name wherever its search is
            Text("Powered by GIPHY").font(.caption.weight(.heavy)).foregroundStyle(.secondary).padding(.vertical, 12)
        }
    }

    private func loadGifs() async {
        loading = true; defer { loading = false }
        guard let (d, code) = try? await Supabase.shared.call("/functions/v1/giphy", body: ["q": q, "kind": gifKind] as JSON, timeout: 20), code == 200,
              let r = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { limited = true; return }
        gifs = CheatDays.list(r["items"])
        limited = r["limited"] as? Bool ?? false
        if q.isEmpty && !gifs.isEmpty { Self.kept[gifKind] = gifs }
    }

    private static let emoji = ["😋", "🔥", "💪", "🥗", "🍕", "🎉", "🥵", "🤤", "🏋️", "🍳", "🍰", "👏", "😮‍💨", "🥑", "🍜", "🍣", "🥩", "🍓", "☕️", "🥤", "🏃", "🧘", "⚡️", "✨", "❤️", "😂", "🙌", "🤯", "😴", "🍫"]
    /// Words to find the 3D ones by.
    private static let names: [String: String] = [
        "🍕": "pizza", "🍔": "burger", "🌮": "taco", "🌯": "burrito wrap", "🥗": "salad", "🍜": "noodles ramen", "🍣": "sushi", "🍱": "bento",
        "🍛": "curry", "🍝": "pasta", "🥩": "steak meat", "🍗": "chicken", "🥓": "bacon", "🍳": "eggs breakfast", "🥞": "pancakes", "🧇": "waffle",
        "🥐": "croissant", "🥑": "avocado", "🍓": "strawberry", "🍌": "banana", "🍎": "apple", "🍉": "watermelon", "🫐": "blueberries", "🥦": "broccoli",
        "🥕": "carrot", "🌶️": "chilli spicy", "🧀": "cheese", "🥚": "egg", "🍞": "bread", "🍰": "cake", "🍩": "donut", "🍪": "cookie", "🍫": "chocolate",
        "🍦": "ice cream", "🧁": "cupcake", "🍿": "popcorn", "☕": "coffee", "🥤": "drink shake", "🧋": "bubble tea", "🍷": "wine", "🍺": "beer",
        "🥂": "cheers", "💧": "water", "🍽️": "plate dinner", "🥄": "spoon", "💪": "strong muscle", "🏋️": "lifting gym", "🏃": "running", "🚴": "cycling",
        "🧘": "yoga", "🤸": "workout", "⚽": "football", "🏆": "trophy win", "🥇": "gold first", "🔥": "fire", "⚡": "energy", "✨": "sparkle", "🎉": "party",
        "🎯": "target goal", "⏰": "time", "📈": "progress", "❤️": "love heart", "💯": "hundred", "😋": "yum", "🤤": "drool", "🥵": "hot", "😮‍💨": "phew",
        "😴": "sleep", "🤯": "mind blown", "😂": "laugh", "🥳": "celebrate", "😎": "cool", "🤩": "wow", "🙌": "hands", "👏": "clap", "👀": "eyes", "💀": "dead"]
}

/// A question and two answers for a poll sticker.
struct PollMaker: View {
    var done: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var a = "Yes"
    @State private var b = "No"
    var body: some View {
        NavigationStack {
            Form {
                TextField("Ask a question… (Cheat day or not?)", text: $q, axis: .vertical)
                Section("Answers") { TextField("First answer", text: $a); TextField("Second answer", text: $b) }
            }
            .navigationTitle("Poll").navigationBarTitleDisplayMode(.inline)
            .onAppear { KeyboardDone.quiet = false }
            .onDisappear { KeyboardDone.quiet = true }   // back in the editor, which has none
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { done(String(q.prefix(80)), String(a.prefix(20)), String(b.prefix(20))); dismiss() }
                        .disabled(q.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// A friend to mention: they get a message saying so.
struct MentionPicker: View {
    var done: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(Friends.shared.people) { p in
                Button { done(p.id, Profiles.shared.all[p.id]?.username.isEmpty == false ? Profiles.shared.all[p.id]!.username : p.name); dismiss() } label: {
                    HStack(spacing: 12) { Avatar(id: p.id, size: 34); Text(p.name) }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Mention").navigationBarTitleDisplayMode(.inline)
            .onAppear { KeyboardDone.quiet = false }
            .onDisappear { KeyboardDone.quiet = true }   // back in the editor, which has none
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// One of Adjust's sliders with its number over it. The number it's at is its own while a finger's on it: each
/// step goes straight to whatever draws the picture, and the editor around it is only told when the finger lifts.
/// Tapping the number puts it back to nothing.
struct TuneSlider: View {
    let name: String
    let degrees: Bool
    let lo: Double
    let hi: Double
    let value: Double
    var changed: (Double) -> Void
    var sliding: (Bool) -> Void
    var done: (Double) -> Void
    @State private var v: Double
    @State private var held = false

    init(name: String, degrees: Bool, lo: Double, hi: Double, value: Double,
         changed: @escaping (Double) -> Void, sliding: @escaping (Bool) -> Void, done: @escaping (Double) -> Void) {
        self.name = name; self.degrees = degrees; self.lo = lo; self.hi = hi; self.value = value
        self.changed = changed; self.sliding = sliding; self.done = done
        _v = State(initialValue: value)
    }

    var body: some View {
        let n = Int(v.rounded())
        VStack(spacing: 8) {
            Button { v = 0; changed(0); done(0) } label: {
                Text(degrees ? String(format: "%.1f°", v) : n > 0 ? "+\(n)" : "\(n)").font(.title3.weight(.heavy)).foregroundStyle(.white).monospacedDigit()
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            .buttonStyle(.plain).accessibilityLabel("Put \(name) back")
            // no steps: it moves as finely as the finger does (to a tenth of a degree for Straighten, a fifth of a
            // point for the rest), and catches at nothing when it's all but there
            Slider(value: Binding(get: { v }, set: { raw in
                       let fine: Double = degrees ? 10 : 5
                       var r = (raw * fine).rounded() / fine
                       if abs(r) < (degrees ? 0.25 : 1.2) { r = 0 }
                       if r != v { v = r; changed(r) }
                   }), in: lo...hi,
                   onEditingChanged: { on in held = on; sliding(on); if !on { done(v) } })
                .tint(.white).padding(.horizontal, 24).accessibilityLabel(name)
        }
        // put back from outside (Reset): follow it, unless a finger's on the slider
        .onChange(of: value) { _, now in if !held { v = now } }
    }
}

/// How loud something is, as a fine white line with a round handle: the editor's own, over the video. (The system's
/// slider came out with a wide pill of a handle and the app's blue, which sat oddly on a video.)
struct LevelBar: View {
    let symbol: String
    let name: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 22)
            Text(name).font(.subheadline.weight(.semibold)).frame(width: 48, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width, x = CGFloat(value) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                    Capsule().fill(.white).frame(width: max(0, x), height: 4)
                    Circle().fill(.white).frame(width: 20, height: 20).shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: min(max(0, x - 10), max(0, w - 20)))
                }
                .frame(height: 34).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in value = Double(min(1, max(0, d.location.x / max(1, w)))) })
            }
            .frame(height: 34)
            Text("\(Int((value * 100).rounded()))%").font(.footnote.weight(.semibold)).monospacedDigit().opacity(0.8).frame(width: 44, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore).accessibilityLabel(name + " volume").accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { way in value = min(1, max(0, value + (way == .increment ? 0.1 : -0.1))) }
    }
}
