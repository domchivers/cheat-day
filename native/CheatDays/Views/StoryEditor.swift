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
    var close: () -> Void
    var posted: () -> Void = {}
    /// A feed post: the finished photo, with everything on it, instead of sharing to a story.
    var finish: ((UIImage) -> Void)? = nil
    private var forPost: Bool { finish != nil }

    enum Mode { case none, text, draw, filters, trim }
    @State private var mode: Mode = .none
    @State private var items: [JSON] = []
    @State private var strokes: [JSON] = []
    @State private var current: [CGPoint] = []
    @State private var filter = "Normal"
    @State private var preview: UIImage?
    @State private var thumbs: [String: UIImage] = [:]
    // the photo itself, pinched and moved
    @State private var bgScale: CGFloat = 1
    @State private var bgOffset: CGSize = .zero
    @State private var bgStart: (CGFloat, CGSize) = (1, .zero)
    // something placed, being moved
    @State private var active: Int?
    @State private var start: (x: Double, y: Double, s: Double, r: Double) = (0.5, 0.5, 1, 0)
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
    @State private var frames: [UIImage] = []
    // sheets
    @State private var stickers = false
    @State private var food = false
    @State private var polling = false
    @State private var mentioning = false
    @State private var note: String?
    @State private var canvasWidth: CGFloat = 360
    private var stories: Stories { Stories.shared }

    var body: some View {
        GeometryReader { screen in
            let cw = min(screen.size.width - 16, (screen.size.height - 96) * aspect)
            let ch = cw / aspect
            VStack(spacing: 10) {
                canvas(cw, ch)
                    .frame(width: cw, height: ch)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .top) { topBar.padding(12) }
                    .overlay(alignment: mode == .text ? .top : .bottom) { tray(cw).padding(mode == .text ? .top : .bottom, mode == .text ? 64 : 12) }
                    .overlay(alignment: .leading) { if mode == .text || mode == .draw { sizeSlider.padding(.leading, 8) } }
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
        .statusBarHidden()
        .task { await prepare() }
        .onChange(of: filter) { _, f in Task { await refilter(f) } }
        .sheet(isPresented: $stickers) {
            StickerSheet(forPost: forPost) { pick in stickers = false; add(pick) }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $food) { FoodStickerPicker { it in addFood(it) }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $polling) { PollMaker { q, a, b in place(["type": "poll", "q": q, "a": a, "b": b]) }.presentationDetents([.medium]) }
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
                LoopingVideo(url: video, paused: mode == .text, muted: muted, filter: filter, range: length > 0 ? range : nil)
            } else if let shown = preview ?? image {
                Image(uiImage: shown).resizable().scaledToFill().frame(width: cw, height: ch)
                    .scaleEffect(bgScale).offset(bgOffset).frame(width: cw, height: ch).clipped()
            }
            Color.clear.contentShape(Rectangle()).gesture(backgroundGesture(cw)).simultaneousGesture(backgroundPinch)
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
        let o = items[i], k = cw / StoryArt.design
        return StoryItem(o: o)
            .scaleEffect((num(o["scale"]) ?? 1) * k)
            .rotationEffect(.degrees(num(o["rotation"]) ?? 0))
            .position(x: (num(o["x"]) ?? 0.5) * cw, y: (num(o["y"]) ?? 0.5) * ch)
            .opacity(editing == i ? 0 : (active == i && overBin ? 0.5 : 1))
            .onTapGesture { tapped(i) }
            .gesture(SimultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { v in moving(i, by: v.translation, at: v.location, cw, ch) }
                    .onEnded { _ in dropped(i) },
                SimultaneousGesture(
                    MagnifyGesture().onChanged { m in grab(i); items[i]["scale"] = min(4.0, max(0.3, start.s * Double(m.magnification))) }.onEnded { _ in dropped(i) },
                    RotateGesture().onChanged { r in grab(i); items[i]["rotation"] = start.r + r.rotation.degrees }.onEnded { _ in dropped(i) })))
            .allowsHitTesting(mode == .none)
    }

    private func grab(_ i: Int) {
        guard active != i else { return }
        active = i
        start = (num(items[i]["x"]) ?? 0.5, num(items[i]["y"]) ?? 0.5, num(items[i]["scale"]) ?? 1, num(items[i]["rotation"]) ?? 0)
    }

    private func moving(_ i: Int, by t: CGSize, at p: CGPoint, _ cw: CGFloat, _ ch: CGFloat) {
        grab(i)
        var x: Double = start.x + Double(t.width / cw), y: Double = start.y + Double(t.height / ch)
        // snap to the middle, with a line and a tap
        let sx = abs(x - 0.5) < 0.025, sy = abs(y - 0.5) < 0.02
        if sx { x = 0.5 }; if sy { y = 0.5 }
        if sx != snapX || sy != snapY { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        snapX = sx; snapY = sy
        items[i]["x"] = min(1, max(0, x)); items[i]["y"] = min(1, max(0, y))
        let bin = CGPoint(x: cw / 2, y: ch - 70), here = CGPoint(x: x * cw, y: y * ch)
        let near = hypot(here.x - bin.x, here.y - bin.y) < 70
        if near != overBin { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        overBin = near
    }

    private func dropped(_ i: Int) {
        if overBin, items.indices.contains(i) { withAnimation(.snappy) { _ = items.remove(at: i) } }
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
        case "food": items[i]["style"] = (Int(num(o["style"]) ?? 0) + 1) % 3
        default: break
        }
    }

    /// One finger on the photo: move it once it's zoomed, otherwise swipe through the filters.
    private func backgroundGesture(_ cw: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                guard mode == .none || mode == .filters, video == nil, bgScale > 1.01 else { return }
                bgOffset = CGSize(width: bgStart.1.width + v.translation.width, height: bgStart.1.height + v.translation.height)
            }
            .onEnded { v in
                if bgScale > 1.01 && video == nil { bgStart.1 = bgOffset; return }
                guard abs(v.translation.width) > 50, abs(v.translation.width) > abs(v.translation.height) else { return }
                let i = StoryArt.filters.firstIndex(of: filter) ?? 0
                let next = (i + (v.translation.width < 0 ? 1 : -1) + StoryArt.filters.count) % StoryArt.filters.count
                withAnimation(.easeOut(duration: 0.2)) { filter = StoryArt.filters[next] }
                flash(StoryArt.filters[next])
            }
    }
    private var backgroundPinch: some Gesture {
        MagnifyGesture()
            .onChanged { m in guard video == nil, mode == .none, active == nil else { return }; bgScale = min(4, max(1, bgStart.0 * m.magnification)) }
            .onEnded { _ in bgStart.0 = bgScale; if bgScale <= 1.01 { withAnimation(.snappy) { bgOffset = .zero }; bgStart.1 = .zero } }
    }

    // MARK: tools along the top

    @ViewBuilder private var topBar: some View {
        HStack(spacing: 6) {
            switch mode {
            case .none:
                round("xmark") { close() }.accessibilityLabel("Back")
                Spacer()
                round("textformat") { newText() }.accessibilityLabel("Text")
                round("face.smiling") { stickers = true }.accessibilityLabel("Stickers")
                round("scribble.variable") { mode = .draw }.accessibilityLabel("Draw")
                round("camera.filters") { mode = .filters }.accessibilityLabel("Filters")
                if video != nil {
                    round(muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { muted.toggle(); flash(muted ? "Sound off" : "Sound on") }.accessibilityLabel(muted ? "Sound off" : "Sound on")
                    round("scissors") { mode = .trim }.accessibilityLabel("Trim")
                }
                Menu {
                    if image != nil { Button { Task { await save() } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") } }
                    if bgScale > 1.01 || bgOffset != .zero { Button { withAnimation { bgScale = 1; bgOffset = .zero; bgStart = (1, .zero) } } label: { Label("Reset the photo", systemImage: "arrow.counterclockwise") } }
                    if !items.isEmpty || !strokes.isEmpty { Button(role: .destructive) { items = []; strokes = [] } label: { Label("Clear everything", systemImage: "trash") } }
                } label: { roundLabel("ellipsis") }
            case .text:
                Spacer()
                round(highlight ? "character.textbox" : "a.square") { highlight.toggle() }.accessibilityLabel("Highlight")
                round(align == "left" ? "text.alignleft" : align == "right" ? "text.alignright" : "text.aligncenter") {
                    align = align == "center" ? "left" : align == "left" ? "right" : "center"
                }.accessibilityLabel("Alignment")
                round(glow ? "sparkles" : "sparkle") { glow.toggle() }.accessibilityLabel("Glow")
                Button("Done") { finishText() }.font(.headline).foregroundStyle(.white).padding(.leading, 6)
            case .draw:
                round("arrow.uturn.backward") { if !strokes.isEmpty { strokes.removeLast() } }.disabled(strokes.isEmpty).accessibilityLabel("Undo")
                Spacer()
                Button("Done") { mode = .none }.font(.headline).foregroundStyle(.white)
            case .filters, .trim:
                Spacer()
                Button("Done") { mode = .none }.font(.headline).foregroundStyle(.white)
            }
        }
    }

    private func round(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(symbol) }.buttonStyle(.plain)
    }
    private func roundLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            .frame(width: 36, height: 36).background(.black.opacity(0.45), in: Circle())
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
            let o: JSON = ["type": "text", "text": draft.isEmpty ? " " : draft, "font": font, "color": color, "bg": highlight, "align": align, "glow": glow, "size": size]
            ZStack {
                StoryItem(o: o).scaleEffect(cw / StoryArt.design).allowsHitTesting(false)
                TextField("", text: $draft, axis: .vertical).focused($typing)
                    .font(StoryArt.font(font, size * cw / StoryArt.design)).foregroundStyle(.clear).tint(.white)
                    .multilineTextAlignment(align == "left" ? .leading : align == "right" ? .trailing : .center)
                    .frame(maxWidth: 330 * cw / StoryArt.design)
            }
            .offset(y: -cw * 0.25)
        }
    }

    private func finishText() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
                .onChanged { v in current.append(v.location) }
                .onEnded { _ in if !current.isEmpty { strokes.append(stroke(current, cw, ch)) }; current = [] })
    }

    private func stroke(_ pts: [CGPoint], _ cw: CGFloat, _ ch: CGFloat) -> JSON {
        ["kind": pen, "color": penColor, "width": penWidth, "points": pts.map { [Double($0.x / cw), Double($0.y / ch)] }]
    }

    // MARK: stickers

    private func add(_ pick: String) {
        let s = Store.shared
        switch pick {
        // these open their own sheet once the sticker tray has gone
        case "food": DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { food = true }
        case "poll": DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { polling = true }
        case "mention": DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { mentioning = true }
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
        var n = o
        n["id"] = UUID().uuidString.prefix(8).lowercased(); n["x"] = 0.5; n["y"] = 0.55 + Double(items.count % 3) * 0.06; n["scale"] = 1.0; n["rotation"] = 0.0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { items.append(n) }
    }

    // MARK: video

    private func trimmer(_ width: CGFloat) -> some View {
        let total = max(length, 0.1)
        let lo = range.lowerBound / total, hi = range.upperBound / total
        return VStack(spacing: 8) {
            Text("\(clock(range.lowerBound)) – \(clock(range.upperBound)) · \(Int((range.upperBound - range.lowerBound).rounded())) s")
                .font(.caption.weight(.heavy)).foregroundStyle(.white)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in Image(uiImage: frames[i]).resizable().scaledToFill().frame(width: width / CGFloat(max(1, frames.count)), height: 52).clipped() }
                }
                .frame(width: width, height: 52).background(Color(white: 0.2))
                // outside the kept part, dimmed
                Rectangle().fill(.black.opacity(0.6)).frame(width: width * lo, height: 52)
                Rectangle().fill(.black.opacity(0.6)).frame(width: width * (1 - hi), height: 52).offset(x: width * hi)
                RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 3).frame(width: max(20, width * (hi - lo)), height: 52).offset(x: width * lo)
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
            })
            .accessibilityLabel(left ? "Start" : "End")
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    // MARK: getting ready, filters and sharing

    private func prepare() async {
        if let image {
            let small = image.preparingThumbnail(of: CGSize(width: 140, height: 140 / image.size.width * image.size.height)) ?? image
            var t: [String: UIImage] = [:]
            for f in StoryArt.filters { t[f] = StoryArt.filtered(small, f) }
            thumbs = t
        }
        if let video {
            let asset = AVURLAsset(url: video)
            length = (try? await asset.load(.duration).seconds) ?? 0
            range = 0...min(length, 30)
            let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true; gen.maximumSize = CGSize(width: 160, height: 160)
            var got: [UIImage] = []
            for i in 0..<8 {
                if let cg = try? await gen.image(at: CMTime(seconds: length * Double(i) / 8, preferredTimescale: 600)).image { got.append(UIImage(cgImage: cg)) }
            }
            frames = got
            if let first = got.first { for f in StoryArt.filters { thumbs[f] = StoryArt.filtered(first, f) } }
        }
    }

    private func refilter(_ f: String) async {
        guard let image else { return }
        let src = image
        preview = f == "Normal" ? nil : await Task.detached { StoryArt.filtered(src, f) }.value
    }

    /// The photo as framed (zoom, position, filter), 1080 wide (1920 high for a story); what's placed on it stays
    /// sharp as its own layer.
    private func framedPhoto(_ cw: CGFloat) -> UIImage? {
        guard let base = preview ?? image else { return nil }
        let ch = cw / aspect, k = 1080 / cw, oh = (1080 / aspect).rounded()
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
        if forPost {
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
        .frame(width: StoryArt.design, height: StoryArt.design / aspect)
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

/// The sticker tray: the app's own stickers from your numbers, then emoji, with search.
struct StickerSheet: View {
    var forPost = false
    var pick: (String) -> Void
    @State private var q = ""
    private var store: Store { Store.shared }
    private static let emoji = ["😋", "🔥", "💪", "🥗", "🍕", "🎉", "🥵", "🤤", "🏋️", "🍳", "🍰", "👏", "😮‍💨", "🥑", "🍜", "🍣", "🥩", "🍓", "☕️", "🥤", "🏃", "🧘", "⚡️", "✨", "❤️", "😂", "🙌", "🤯", "😴", "🍫"]

    private var app: [(id: String, title: String, detail: String)] {
        let m = store.macros(store.todayItems)
        return [("food", "Your food", "from today's log"),
                ("macros", "Macros", "P \(Int(m.p)) · C \(Int(m.c)) · F \(Int(m.f))"),
                ("streak", "🔥 Streak", "\(store.streakInfo.days) days"),
                ("left", "Calories left", "\(Fmt.int(max(0, store.left))) today"),
                ("workout", "🏋️ Workout", store.todayWorkouts.last.map { str($0["name"]) } ?? "today's"),
                ("poll", "📊 Poll", "ask your friends"),
                ("time", "Time", Date().formatted(date: .omitted, time: .shortened)),
                ("place", "📍 Location", "your suburb"),
                ("mention", "@ Mention", "a friend")]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search stickers", text: $q)
                }
                .padding(10).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                // a poll or a mention needs a story to vote or tap on; a post is one picture
                let shown = app.filter { (!forPost || ($0.id != "poll" && $0.id != "mention")) && (q.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(q)) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(shown, id: \.id) { s in
                        Button { pick(s.id) } label: {
                            VStack(spacing: 3) {
                                Text(s.title).font(.subheadline.weight(.heavy)).lineLimit(1)
                                Text(s.detail).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 66).padding(.horizontal, 6)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if q.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.emoji, id: \.self) { e in Button { pick(e) } label: { Text(e).font(.system(size: 34)) }.buttonStyle(.plain) }
                    }
                }
            }
            .padding(16)
        }
    }
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
