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
    var finishVideo: ((String, ClosedRange<Double>?, Bool, CGRect?, CGFloat) -> Void)? = nil
    /// The shape picked the last time this clip was in the editor, to open on.
    var startShape: CGFloat? = nil
    private var forPost: Bool { finish != nil || finishVideo != nil }
    /// A post's clip: trimmed, filtered and muted only.
    private var clipOnly: Bool { finishVideo != nil }
    /// A post's photo: the shape picked for it (portrait 4:5 to start, as Instagram's is), else the editor's own.
    @State private var shape: CGFloat?
    /// A post's clip starts as it was filmed; a photo at the editor's own shape.
    private var ratio: CGFloat { shape ?? (clipOnly ? (clipShape ?? aspect) : aspect) }
    private static let shapes: [(name: String, ratio: CGFloat)] = [("Portrait 4:5", 4.0 / 5.0), ("Square 1:1", 1), ("Landscape 16:9", 16.0 / 9.0)]
    /// The photo's own shape, within what the feed shows (no taller than 4:5, no wider than 1.91:1).
    private var ownShape: CGFloat? { image.map { min(1.91, max(0.8, $0.size.width / max($0.size.height, 1))) } }
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
        withAnimation(.snappy) { shape = next.ratio; bgScale = 1; bgOffset = .zero; clipMove = .zero }
        flash(next.name)
    }

    /// The clip's size when it just fills a frame cw by ch.
    private func clipFill(_ cw: CGFloat, _ ch: CGFloat) -> CGSize {
        let v = clipShape ?? (cw / ch)
        return v > cw / ch ? CGSize(width: ch * v, height: ch) : CGSize(width: cw, height: cw / v)
    }
    /// A pinch or a drag on the clip, kept inside its edges so no blank shows.
    private func moveClip(_ sc: CGFloat, _ off: CGSize, cw: CGFloat, ch: CGFloat) {
        let f = clipFill(cw, ch), s = min(4, max(1, sc))
        let mx = max(0, (f.width * s - cw) / 2), my = max(0, (f.height * s - ch) / 2)
        let o = CGSize(width: min(mx, max(-mx, off.width)), height: min(my, max(-my, off.height)))
        bgScale = s; bgOffset = o   // no animation: the clip is already there, under the fingers
        clipMove = CGSize(width: o.width / cw, height: o.height / ch)
    }
    /// The part of the clip's picture showing in the frame, as fractions from its top left; nil when that's all of it.
    private var clipCrop: CGRect? {
        let r = ratio, f = clipFill(r, 1), s = bgScale
        let w = f.width * s, h = f.height * s
        let x = ((w - r) / 2 - clipMove.width * r) / w, y = ((h - 1) / 2 - clipMove.height) / h
        let cut = CGRect(x: max(0, x), y: max(0, y), width: min(1, r / w), height: min(1, 1 / h))
        return cut.width > 0.995 && cut.height > 0.995 ? nil : cut
    }

    enum Mode { case none, text, draw, filters, trim }
    @State private var mode: Mode = .none
    @State private var items: [JSON] = []
    @State private var strokes: [JSON] = []
    @State private var current: [CGPoint] = []
    @State private var filter = "Normal"
    @State private var preview: UIImage?
    @State private var work: UIImage?   // the photo at screen size: filtering and drawing a 4000-pixel one lagged
    @State private var thumbs: [String: UIImage] = [:]
    // the photo itself, pinched and moved
    @State private var bgScale: CGFloat = 1
    @State private var bgOffset: CGSize = .zero
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
            let cw = min(screen.size.width - 16, (screen.size.height - 96) * ratio)
            let ch = cw / ratio
            VStack(spacing: 10) {
                canvas(cw, ch)
                    .frame(width: cw, height: ch)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .top) { topBar.padding(12) }
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
                bottomBar.frame(width: cw)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task { await prepare() }
        .task { if startWriting { try? await Task.sleep(for: .milliseconds(350)); newText(); size = 40 } }
        .onChange(of: filter) { _, f in Task { await refilter(f) } }
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
                    MovableClip(cw: cw, ch: ch, fill: f, scale: bgScale, offset: bgOffset, movable: mode == .none, commit: { sc, off in moveClip(sc, off, cw: cw, ch: ch) }) {
                        ZStack {
                            if let poster { Image(uiImage: poster).resizable().scaledToFill() }
                            LoopingVideo(url: video, paused: false, muted: muted, filter: filter, range: length > 0 && mode != .trim ? range : nil, scrub: mode == .trim ? scrub : nil)
                        }
                        .frame(width: f.width, height: f.height)
                    }
                } else {
                if let poster { Image(uiImage: poster).resizable().scaledToFill().frame(width: cw, height: ch).clipped() }
                LoopingVideo(url: video, paused: mode == .text, muted: muted, filter: filter, range: length > 0 && mode != .trim ? range : nil, scrub: mode == .trim ? scrub : nil)
                }
            } else if let shown = preview ?? work ?? image {
                // the photo moves on its own too, and tells the editor only when the finger lifts
                let k = max(cw / max(1, shown.size.width), ch / max(1, shown.size.height))
                MovableClip(cw: cw, ch: ch, fill: CGSize(width: shown.size.width * k, height: shown.size.height * k), scale: bgScale, offset: bgOffset,
                            movable: mode == .none || mode == .filters, swipe: { nextFilter($0) },
                            commit: { sc, off in bgScale = sc; bgOffset = off }) {   // no animation: it is already there, under the fingers
                    Image(uiImage: shown).resizable().scaledToFill().frame(width: cw, height: ch)
                }
            }
            if video != nil && !clipOnly {   // a post's clip is pinched and dragged itself: this sheet over it took those touches
                // a video can't be zoomed, but swiping across it still changes the filter
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 20).onEnded { v in
                    guard abs(v.translation.width) > 50, abs(v.translation.width) > abs(v.translation.height) else { return }
                    nextFilter(v.translation.width < 0 ? 1 : -1)
                })
                .allowsHitTesting(mode == .none || mode == .filters)
            }
            StoryDrawing(strokes: strokes + (current.isEmpty ? [] : [stroke(current, cw, ch)]))
            ForEach(items.indices, id: \.self) { i in placed(i, cw, ch) }
            if snapX { Rectangle().fill(Color.yellow.opacity(0.9)).frame(width: 1.5).allowsHitTesting(false) }
            if snapY { Rectangle().fill(Color.yellow.opacity(0.9)).frame(height: 1.5).allowsHitTesting(false) }
            if active != nil {
                Image(systemName: "trash").font(.system(size: overBin ? 24 : 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: overBin ? 68 : 56, height: overBin ? 68 : 56)
                    .background(overBin ? Color.red.opacity(0.85) : Color.black.opacity(0.4), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(x: cw / 2, y: ch - 70).allowsHitTesting(false)
                    .animation(.snappy, value: overBin)
            }
            if mode == .draw { drawCatcher(cw, ch) }
            if mode == .text { textEditor(cw) }
        }
    }

    /// Something placed: drag, pinch and twist at once; tap text to edit it, tap a food sticker for its next look.
    private func placed(_ i: Int, _ cw: CGFloat, _ ch: CGFloat) -> some View {
        PlacedItem(o: items[i], cw: cw, ch: ch, hidden: editing == i, dim: active == i && overBin,
                   tap: { tapped(i) },
                   began: { if active != i { remember(); active = i } },
                   report: { sx, sy, bin in
                       if sx != snapX || sy != snapY { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                       if bin != overBin { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                       snapX = sx; snapY = sy; overBin = bin
                   },
                   commit: { change in guard items.indices.contains(i) else { return }; for (k, v) in change { items[i][k] = v } },
                   ended: { dropped(i) })
            .allowsHitTesting(mode == .none)
    }

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

    @ViewBuilder private var topBar: some View {
        HStack(spacing: 5) {
            switch mode {
            case .none:
                round("xmark") { if edited { leaving = true } else { close() } }.accessibilityLabel("Back")
                if !history.isEmpty { round("arrow.uturn.backward") { undo() }.accessibilityLabel("Undo") }
                Spacer()
                if !clipOnly {
                    round("textformat") { newText() }.accessibilityLabel("Text")
                    round("face.smiling") { stickers = true }.accessibilityLabel("Stickers")
                    round("scribble.variable") { mode = .draw }.accessibilityLabel("Draw")
                }
                if forPost { round("aspectratio") { nextShape() }.accessibilityLabel("Shape") }
                round("camera.filters") { mode = .filters }.accessibilityLabel("Filters")
                if video != nil {
                    round(muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { muted.toggle(); flash(muted ? "Sound off" : "Sound on") }.accessibilityLabel(muted ? "Sound off" : "Sound on")
                    round("scissors") { mode = .trim }.accessibilityLabel("Trim")
                }
                if image != nil || bgScale > 1.01 || bgOffset != .zero || !items.isEmpty || !strokes.isEmpty {
                Menu {
                    if image != nil { Button { Task { await save() } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") } }
                    if bgScale > 1.01 || bgOffset != .zero { Button { withAnimation { bgScale = 1; bgOffset = .zero; clipMove = .zero } } label: { Label(video == nil ? "Reset the photo" : "Reset the video", systemImage: "arrow.counterclockwise") } }
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
    private var edited: Bool { !items.isEmpty || !strokes.isEmpty || filter != "Normal" || bgScale > 1.01 }

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
                    HStack(spacing: 8) {
                        ForEach(StoryArt.fonts, id: \.self) { f in
                            Button { font = f } label: {
                                Text(StoryArt.fontNames[f] ?? f).font(StoryArt.font(f, 14)).foregroundStyle(font == f ? .black : .white)
                                    .padding(.horizontal, 13).padding(.vertical, 7).background(font == f ? Color.white : Color.white.opacity(0.18), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
                swatches($color)
            }
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
        case .trim:
            trimmer(cw - 24)
        case .none:
            EmptyView()
        }
    }

    private func swatches(_ value: Binding<String>) -> some View {
        HStack(spacing: 10) {
            ForEach(StoryArt.colors, id: \.self) { c in
                Button { value.wrappedValue = c } label: {
                    Circle().fill(StoryArt.color(c)).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(.white, lineWidth: value.wrappedValue == c ? 3 : 1.5))
                        .scaleEffect(value.wrappedValue == c ? 1.15 : 1)
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

    private func trimmer(_ width: CGFloat) -> some View {
        let total = max(length, 0.1)
        let lo = range.lowerBound / total, hi = range.upperBound / total
        return VStack(spacing: 8) {
            Text(scrub.map { "At \(clock($0))" } ?? "\(clock(range.lowerBound)) – \(clock(range.upperBound)) · \(Int((range.upperBound - range.lowerBound).rounded())) s")
                .font(.caption.weight(.heavy)).foregroundStyle(.white).monospacedDigit()
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in Image(uiImage: frames[i]).resizable().scaledToFill().frame(width: width / CGFloat(max(1, frames.count)), height: 52).clipped() }
                }
                .frame(width: width, height: 52).background(Color(white: 0.2))
                // a finger along the strip looks through the clip: it holds on that moment, and plays on from it after
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                    .onChanged { v in scrub = min(length, max(0, Double(v.location.x / width) * length)) }
                    .onEnded { _ in scrub = nil })
                // outside the kept part, dimmed
                Rectangle().fill(.black.opacity(0.6)).frame(width: width * lo, height: 52).allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.6)).frame(width: width * (1 - hi), height: 52).offset(x: width * hi).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 3).frame(width: max(20, width * (hi - lo)), height: 52).offset(x: width * lo).allowsHitTesting(false)
                if let at = scrub { Rectangle().fill(.white).frame(width: 2, height: 52).offset(x: width * CGFloat(at / total) - 1).allowsHitTesting(false) }
                handle(width, left: true).offset(x: width * lo - 8)
                handle(width, left: false).offset(x: width * hi - 8)
            }
            .frame(width: width, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
            .coordinateSpace(name: "strip")
        }
    }

    private func handle(_ width: CGFloat, left: Bool) -> some View {
        Capsule().fill(.white).frame(width: 16, height: 52).overlay(Capsule().fill(.black.opacity(0.4)).frame(width: 3, height: 18))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { v in
                let at = min(length, max(0, Double(v.location.x / width) * length))
                if left { let s = min(at, range.upperBound - 1); range = max(0, max(s, range.upperBound - 30))...range.upperBound }
                else { let e = max(at, range.lowerBound + 1); range = range.lowerBound...min(length, min(e, range.lowerBound + 30)) }
                scrub = left ? range.lowerBound : range.upperBound   // the frame that end lands on
            }.onEnded { _ in scrub = nil })
            .accessibilityLabel(left ? "Start" : "End")
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    // MARK: getting ready, filters and sharing

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
        }
        if let video {
            let asset = AVURLAsset(url: video)
            length = (try? await asset.load(.duration).seconds) ?? 0
            range = 0...min(length, 30)
            let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true; gen.maximumSize = CGSize(width: 160, height: 160)
            // its first frame straight away, behind the player, so there's never a black screen while it loads
            let big = AVAssetImageGenerator(asset: asset); big.appliesPreferredTrackTransform = true; big.maximumSize = CGSize(width: 1080, height: 1920)
            if let cg = try? await big.image(at: .zero).image { poster = UIImage(cgImage: cg) }
            var got: [UIImage] = []
            for i in 0..<8 {
                if let cg = try? await gen.image(at: CMTime(seconds: length * Double(i) / 8, preferredTimescale: 600)).image { got.append(UIImage(cgImage: cg)) }
            }
            frames = got
            if let first = got.first {
                let t = await Task.detached(priority: .userInitiated) { () -> [String: UIImage] in
                    var t: [String: UIImage] = [:]; for f in StoryArt.filters { t[f] = StoryArt.filtered(first, f) }; return t
                }.value
                thumbs = t
            }
        }
    }

    private func refilter(_ f: String) async {
        guard let src = work ?? image else { return }
        preview = f == "Normal" ? nil : await Task.detached { StoryArt.filtered(src, f) }.value
    }

    /// The photo as framed (zoom, position, filter), 1080 wide (1920 high for a story); what's placed on it stays
    /// sharp as its own layer.
    private func framedPhoto(_ cw: CGFloat) -> UIImage? {
        guard let base = preview ?? work ?? image else { return nil }
        let ch = cw / ratio, k = 1080 / cw, oh = (1080 / ratio).rounded()
        let fill = max(cw / base.size.width, ch / base.size.height) * bgScale
        let w = base.size.width * fill, h = base.size.height * fill
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1080, height: oh), format: format).image { _ in
            UIColor(white: 0.08, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1080, height: oh))
            base.draw(in: CGRect(x: ((cw - w) / 2 + bgOffset.width) * k, y: ((ch - h) / 2 + bgOffset.height) * k, width: w * k, height: h * k))
        }
    }

    private var everything: [JSON] { (strokes.isEmpty ? [] : [["type": "drawing", "strokes": strokes]]) + items }

    @ViewBuilder private var bottomBar: some View {
        if let finishVideo {
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                finishVideo(filter, length > 0 ? range : nil, muted, clipCrop, ratio)
            } label: {
                Text("Use this video").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 13).background(.white, in: Capsule())
            }
            .buttonStyle(.plain).disabled(mode != .none).opacity(mode == .none ? 1 : 0.3)
        } else if forPost {
            Button {
                if let out = baked() { UINotificationFeedbackGenerator().notificationOccurred(.success); finish?(out) }
            } label: {
                Text("Use this photo").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 13).background(.white, in: Capsule())
            }
            .buttonStyle(.plain).disabled(mode != .none).opacity(mode == .none ? 1 : 0.3)
        } else { storyButtons }
    }

    private var storyButtons: some View {
        HStack(spacing: 10) {
            Button { share("friends") } label: {
                HStack(spacing: 7) {
                    Image(systemName: "star.fill").font(.system(size: 11, weight: .black)).foregroundStyle(.black).frame(width: 22, height: 22).background(Color(red: 0.19, green: 0.82, blue: 0.35), in: Circle())
                    Text("Close friends").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
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
                ok = await stories.post(image: nil, video: video, overlays: everything, audience: audience, filter: filter, range: length > 0 ? range : nil, muted: muted)
            } else {
                ok = await stories.post(image: framedPhoto(canvasWidth), video: nil, overlays: everything, audience: audience)
            }
            if ok { UINotificationFeedbackGenerator().notificationOccurred(.success); posted() }
            else { flash(stories.error ?? "Couldn't share it") }
        }
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
        guard let out = baked() else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { flash("Allow Photos in Settings to save"); return }
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

/// One thing placed on the story, moved on its own. While a finger's on it only it redraws: before, every drag frame
/// changed the editor's list, and the whole editor (every sticker, the drawing, the photo) redrew sixty times a second.
/// The editor hears only when a snap line or the bin should change, and the final place when the finger lifts.
struct PlacedItem: View {
    let o: JSON
    let cw: CGFloat
    let ch: CGFloat
    var hidden: Bool
    var dim: Bool
    var tap: () -> Void
    var began: () -> Void
    var report: (_ snapX: Bool, _ snapY: Bool, _ bin: Bool) -> Void
    var commit: (JSON) -> Void
    var ended: () -> Void
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var twist: Angle = .zero
    @State private var told = ""
    @State private var upright = false
    @State private var resizing = false   // a real pinch under way: a small twist then is the fingers wobbling
    // where the fingers left it, shown until the editor's own copy says the same: without it the sticker jumped back
    // to its old size or place for a frame as they lifted
    @State private var held: JSON = [:]
    // the twist at which turning took hold (10 degrees, 25 during a pinch), kept for the rest of the gesture: the dead
    // zone growing part way through a pinch used to jerk the sticker back by 15 degrees
    @State private var twistFrom: Double?
    // the sticker drawn as a picture at the size it's shown: scaled up as it was, it went soft and fuzzy
    @State private var sharp: UIImage?
    @State private var sharpFor = ""
    @Environment(\.displayScale) private var displayScale

    /// A twist only counts past 10 degrees (25 while it's being pinched bigger or smaller), so resizing doesn't tilt it.
    private func turned(_ a: Angle) -> Double {
        guard let from = twistFrom else { return 0 }
        return a.degrees - from
    }

    /// What it looks like and how big, for knowing when to draw it again (where it is and its turn don't matter).
    private var lookKey: String {
        var look = o
        for k in ["x", "y", "rotation"] { look[k] = nil }
        let data = (try? JSONSerialization.data(withJSONObject: look, options: [.sortedKeys])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "") + "\(cw)"
    }

    private var drawn: Bool { str(o["type"]) != "gif" }   // a GIF moves, so it stays live

    private func draw() -> UIImage? {
        let r = ImageRenderer(content: StoryItem(o: o).environment(\.colorScheme, .dark))
        r.proposedSize = ProposedViewSize(width: StoryArt.design, height: nil)
        r.scale = min(9, displayScale * max(1, scale * cw / StoryArt.design))
        return r.uiImage
    }

    /// A turn snapped to straight (0, 90, 180, 270) when it's within 4 degrees.
    private func snapped(_ deg: Double) -> (Double, Bool) {
        let q = (deg / 90).rounded() * 90
        return abs(deg - q) < 4 ? (q, true) : (deg, false)
    }

    private var bx: Double { num(held["x"]) ?? num(o["x"]) ?? 0.5 }
    private var by: Double { num(held["y"]) ?? num(o["y"]) ?? 0.5 }
    private var scale: Double { num(held["scale"]) ?? num(o["scale"]) ?? 1 }
    private var rotation: Double { num(held["rotation"]) ?? num(o["rotation"]) ?? 0 }
    /// The editor's copy of where it is and how big: when this changes, what was held has been taken.
    private var theirs: String { "\(num(o["x"]) ?? 0.5),\(num(o["y"]) ?? 0.5),\(num(o["scale"]) ?? 1),\(num(o["rotation"]) ?? 0)" }
    private func keep(_ change: JSON) { for (k, v) in change { held[k] = v }; commit(change) }

    /// Where it is with the finger's move, snapped to the middle when it's close.
    private func place(_ t: CGSize) -> (x: Double, y: Double, sx: Bool, sy: Bool) {
        var x = bx + Double(t.width / cw), y = by + Double(t.height / ch)
        // not while two fingers are resizing it: their middle wobbles, and it kept catching and letting go of the centre
        let free = pinch == 1 && !resizing
        let sx = free && abs(x - 0.5) < 0.025, sy = free && abs(y - 0.5) < 0.02
        if sx { x = 0.5 }; if sy { y = 0.5 }
        return (min(1, max(0, x)), min(1, max(0, y)), sx, sy)
    }

    var body: some View {
        let at = place(drag), k = cw / StoryArt.design, eff = min(4, max(0.3, scale * Double(pinch))) * k
        Group {
            if drawn, let sharp, sharpFor == lookKey { Image(uiImage: sharp) } else { StoryItem(o: o) }
        }
            .padding(34 / max(0.2, eff))   // about 34 points on screen at any size
            .overlay(Color.black.opacity(0.001))
            .contentShape(Rectangle())
            .scaleEffect(eff)
            .rotationEffect(.degrees(snapped(rotation + turned(twist)).0))
            .accessibilityElement(children: .ignore).accessibilityIdentifier("placed-" + str(o["type"])).accessibilityAddTraits(.isButton)
            .position(x: at.x * cw, y: at.y * ch)
            .opacity(hidden ? 0 : (dim ? 0.45 : 1))
            .animation(.snappy(duration: 0.18), value: dim)
            .onTapGesture { tap() }
            .task(id: lookKey) { if drawn { let k = lookKey; sharp = draw(); sharpFor = k } }
            .onChange(of: theirs) { _, _ in held = [:] }
            .gesture(SimultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onChanged { v in
                        let p = place(v.translation)
                        let bin = hypot(p.x * cw - cw / 2, p.y * ch - (ch - 70)) < 70
                        let now = "\(p.sx)\(p.sy)\(bin)"
                        if told.isEmpty { began() }
                        if now != told { told = now; report(p.sx, p.sy, bin) }
                    }
                    .onEnded { v in
                        let p = place(v.translation)
                        keep(["x": p.x, "y": p.y]); told = ""; ended()
                    },
                SimultaneousGesture(
                    MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                        .onChanged { v in
                            if told.isEmpty { told = "pinch"; began() }
                            if abs(v.magnification - 1) > 0.12 { resizing = true }
                        }
                        .onEnded { v in keep(["scale": min(4, max(0.3, scale * Double(v.magnification)))]); told = ""; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { resizing = false }; ended() },
                    RotateGesture().updating($twist) { v, s, _ in s = v.rotation }
                        .onChanged { v in
                            // turning takes hold once, at the edge of the dead zone, so it starts from nothing
                            let dead: Double = resizing ? 25 : 10
                            if twistFrom == nil, abs(v.rotation.degrees) >= dead { twistFrom = v.rotation.degrees > 0 ? dead : -dead }
                            let on = snapped(rotation + turned(v.rotation)).1
                            if on != upright { upright = on; if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
                        }
                        .onEnded { v in keep(["rotation": snapped(rotation + turned(v.rotation)).0]); twistFrom = nil; told = ""; upright = false; ended() })))
    }
}

/// The photo behind a story: pinch to zoom, then drag to move it; while it isn't zoomed, a swipe across changes the
/// filter. Like a placed sticker it moves on its own and tells the editor only when the finger lifts.
/// The photo or clip behind the editor's frame: pinch to zoom, drag to choose the part that shows, never past its own
/// edges. It follows the fingers on its own and keeps where they left it until the editor's copy says the same:
/// handing the new zoom to the editor and waiting for it back made it spring to its old size and then swell again.
/// The two gestures end one after the other, so each reads what the other has just left rather than what was drawn
/// last: a drag ending a moment after the pinch used to put the old zoom back.
struct MovableClip<Content: View>: View {
    let cw: CGFloat
    let ch: CGFloat
    /// Its size when it just fills the frame.
    let fill: CGSize
    let scale: CGFloat
    let offset: CGSize
    var movable: Bool
    /// A photo's: a swipe across it at its plain size changes the filter, and it only moves once zoomed in.
    var swipe: ((Int) -> Void)? = nil
    var commit: (CGFloat, CGSize) -> Void
    @ViewBuilder var content: () -> Content
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @State private var heldScale: CGFloat?
    @State private var heldOffset: CGSize?

    private func clamped(_ sc: CGFloat, _ off: CGSize) -> (scale: CGFloat, offset: CGSize) {
        let s = min(4, max(1, sc))
        let mx = max(0, (fill.width * s - cw) / 2), my = max(0, (fill.height * s - ch) / 2)
        return (s, CGSize(width: min(mx, max(-mx, off.width)), height: min(my, max(-my, off.height))))
    }
    /// Where it stands with no finger on it, read as of now.
    private var from: (scale: CGFloat, offset: CGSize) { (heldScale ?? scale, heldOffset ?? offset) }
    private func pans(_ s: CGFloat) -> Bool { swipe == nil || s > 1.01 || pinch != 1 }
    private func settle(_ sc: CGFloat, _ off: CGSize) {
        if swipe != nil && sc <= 1.01 {
            withAnimation(.snappy) { heldScale = 1; heldOffset = .zero }
            commit(1, .zero)
        } else {
            heldScale = sc; heldOffset = off
            commit(sc, off)
        }
    }

    var body: some View {
        let b = from
        let live = clamped(b.scale * pinch, pans(b.scale) ? CGSize(width: b.offset.width + drag.width, height: b.offset.height + drag.height) : b.offset)
        content()
            .scaleEffect(live.scale)
            .offset(live.offset)
            .frame(width: cw, height: ch).clipped()
            .contentShape(Rectangle())
            .gesture(SimultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        let b = from
                        guard pans(b.scale) else {
                            if abs(v.translation.width) > 50, abs(v.translation.width) > abs(v.translation.height) { swipe?(v.translation.width < 0 ? 1 : -1) }
                            return
                        }
                        // within the edges at the size the fingers have it now, a pinch still going included
                        let end = clamped(b.scale * pinch, CGSize(width: b.offset.width + v.translation.width, height: b.offset.height + v.translation.height))
                        if pinch == 1 { settle(end.scale, end.offset) } else { heldOffset = end.offset }
                    },
                MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in
                        let b = from
                        let end = clamped(b.scale * v.magnification, b.offset)
                        settle(end.scale, end.offset)
                    }))
            .allowsHitTesting(movable)
            // the editor has caught up (or reset it, or changed its shape): its numbers from here
            .onChange(of: scale) { _, _ in heldScale = nil; heldOffset = nil }
            .onChange(of: offset) { _, _ in heldScale = nil; heldOffset = nil }
            .onChange(of: fill) { _, _ in heldScale = nil; heldOffset = nil }
    }
}
