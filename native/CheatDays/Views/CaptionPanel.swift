import SwiftUI

/// Which of the caption's screens the sheet shows.
enum CaptionScreen { case main, wheel, dropper }

/// A caption's panel (design/caption-panel-pro-mockup.html, design/caption-colour-mockup.html): one flat sheet of one
/// height, word tabs, each style shown, colours with their opacity, its name and tick along the bottom.
/// 'head' is the editor's own transport and strip.
struct CaptionPanel<Head: View>: View {
    let item: EditText
    @Binding var screen: CaptionScreen
    @Binding var part: CaptionPart
    /// The caption changed, by what's passed.
    let change: ((inout EditText) -> Void) -> Void
    let step: () -> Void
    let held: (Bool) -> Void
    let words: (String) -> Void
    let editAll: () -> Void
    let delete: () -> Void
    let applyAll: () -> Void
    let done: () -> Void
    @ViewBuilder let head: () -> Head

    @State private var tab = CaptionTab.style
    @State private var before: EditText?
    @FocusState private var typingWords: Bool

    private var saved: SavedColours { SavedColours.shared }

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .main: main
            case .wheel: wheel
            case .dropper: dropper
            }
        }
        .frame(height: screen == .dropper ? 108 : 310)
        .foregroundStyle(Color.white)
        .onChange(of: item.style) { (_: String, style: String) in
            if style != "Box" && part == .box { part = .lit }
        }
        .onAppear {
            if item.style != "Box" && part == .box { part = .lit }
        }
        .onDisappear { held(false) }
    }

    // MARK: the panel

    @ViewBuilder private var main: some View {
        head()
        wordsRow.padding(.horizontal, 16).padding(.top, 4)
        tabs
        VStack(spacing: 0) {
            switch tab {
            case .style: styleTiles
            case .colour: colours
            case .place: placing
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 104)
        Spacer(minLength: 0)
        foot("Caption", leftIcon: "square.stack.3d.down.right", leftName: "Apply to all", left: applyAll, tick: done)
    }

    private var wordsRow: some View {
        let text = Binding<String>(get: { item.text }, set: { (new: String) in words(new) })
        return HStack(spacing: 14) {
            TextField("What's said", text: text).font(.system(size: 16)).frame(maxWidth: .infinity)
                .focused($typingWords)
                // (held while it's typed in: one step, and the panel doesn't go on to the next caption)
                .onChange(of: typingWords) { (_: Bool, on: Bool) in held(on) }
            Button(action: editAll) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet").font(.system(size: 14))
                    Text("Edit all").font(.system(size: 11))
                }
                .foregroundStyle(CaptionInk.soft).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Color(white: 0.23)).frame(width: 0.5, height: 22)
            Button(action: delete) {
                Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(CaptionInk.soft)
                    .frame(width: 30, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Delete this caption")
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(CaptionInk.rule).frame(height: 0.5) }
    }

    private var tabs: some View {
        HStack(spacing: 26) {
            ForEach(CaptionTab.allCases, id: \.self) { (t: CaptionTab) in
                Button { tab = t } label: {
                    Text(t.rawValue).font(.system(size: 14, weight: t == tab ? .semibold : .regular))
                        .foregroundStyle(t == tab ? Color.white : CaptionInk.quiet)
                        .frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var styleTiles: some View {
        HStack(spacing: 8) {
            ForEach(EditText.captionStyles, id: \.self) { (style: String) in tile(style) }
        }
        .frame(maxHeight: .infinity)
    }

    /// A style shown as it's drawn on the video, in this caption's own colours.
    private func tile(_ style: String) -> some View {
        let on: Bool = item.style == style
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let outline: Color = on ? Color.white : Color.clear
        return Button {
            guard !on else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            step()
            change { (t: inout EditText) in t.style = style }
        } label: {
            VStack(spacing: 6) {
                shape.fill(CaptionInk.tile)
                    .overlay {
                        EditTextView(item: sample(style), at: 0).fixedSize().scaleEffect(0.56).allowsHitTesting(false)
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(outline, lineWidth: 1.5))
                    .frame(height: 62)
                Text(style).font(.system(size: 11)).foregroundStyle(on ? Color.white : CaptionInk.quiet)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func sample(_ style: String) -> EditText {
        var t = EditText(kind: "caption", text: "Say it", style: style, from: 0, to: 2,
                         words: [EditText.Word(text: "Say", at: 0), EditText.Word(text: "it", at: 1)])
        t.takeColours(from: item)
        t.detail = "1"
        return t
    }

    private var colours: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            parts(size: 12.5, gap: 20).frame(height: 24)
            Spacer(minLength: 0)
            swatches
            Spacer(minLength: 0)
            labelled("Opacity", value: item.alpha(of: part), range: 0...1) { (v: Double) in fade(v) }
            Spacer(minLength: 0)
        }
    }

    private func parts(size: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(CaptionPart.allCases, id: \.self) { (p: CaptionPart) in partTab(p, size: size) }
            Spacer(minLength: 0)
        }
    }

    private func partTab(_ p: CaptionPart, size: CGFloat) -> some View {
        let usable: Bool = p != .box || item.style == "Box"
        let on: Bool = p == part
        let ink: Color
        if !usable { ink = CaptionInk.off } else if on { ink = Color.white } else { ink = CaptionInk.quiet }
        return Button { part = p } label: {
            Text(p.name).font(.system(size: size, weight: on ? .semibold : .regular)).foregroundStyle(ink)
                .frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!usable)
    }

    private var swatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                noneSwatch
                toolSwatch("eyedropper", "Pick a colour from the video") { open(.dropper) }
                wheelSwatch
                Rectangle().fill(CaptionInk.off).frame(width: 0.5, height: 20).padding(.horizontal, 2)
                ForEach(saved.list, id: \.self) { (s: SavedColours.Saved) in savedSwatch(s) }
            }
            .padding(3)
        }
        .frame(height: 34)
    }

    private var noneSwatch: some View {
        let on: Bool = item.isClear(part)
        let can: Bool = part != .words
        return toolSwatch("nosign", part == .box ? "No box" : "No highlight") {
            step()
            change { (t: inout EditText) in t.clear(part) }
        }
        .overlay(picked(on))
        .disabled(!can)
        .opacity(can ? 1 : 0.3)
    }

    private var wheelSwatch: some View {
        Button { open(.wheel) } label: {
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: CaptionInk.rainbow), center: .center))
                Circle().fill(RadialGradient(gradient: Gradient(colors: [Color.white, Color.white.opacity(0)]),
                                             center: .center, startRadius: 0, endRadius: 12))
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain).accessibilityLabel("Colour wheel")
    }

    private func toolSwatch(_ icon: String, _ name: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(CaptionInk.soft)
                .frame(width: 28, height: 28)
                .background(CaptionInk.tile, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityLabel(name)
    }

    private func savedSwatch(_ s: SavedColours.Saved) -> some View {
        let same: Bool = item.hex(of: part) == s.hex && abs(item.alpha(of: part) - s.alpha) < 0.006
        let on: Bool = same && !item.isClear(part)
        return Button {
            if !on { use(s) }
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(StoryArt.color(s.hex).opacity(max(0.12, s.alpha)))
                .frame(width: 28, height: 28)
                .overlay(picked(on))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Saved colour \(s.hex)")
        .contextMenu {
            Button(role: .destructive) { saved.remove(s) } label: { Label("Delete saved colour", systemImage: "trash") }
        }
    }

    private func picked(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(on ? Color.white : Color.clear, lineWidth: 1.5)
            .padding(-2.5)
            .allowsHitTesting(false)
    }

    private var placing: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            labelled("Size", value: item.size, range: 0.4...3) { (v: Double) in
                change { (t: inout EditText) in t.size = v }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                position("Top", icon: "align.vertical.top.fill", y: 0.2, on: item.y < 0.35)
                position("Middle", icon: "align.vertical.center.fill", y: 0.5, on: item.y >= 0.35 && item.y < 0.62)
                position("Bottom", icon: "align.vertical.bottom.fill", y: 0.76, on: item.y >= 0.62)
            }
            Spacer(minLength: 0)
        }
    }

    private func position(_ name: String, icon: String, y: Double, on: Bool) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            step()
            change { (t: inout EditText) in
                t.y = y
                t.byHand = nil
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(name).font(.system(size: 11))
            }
            .foregroundStyle(on ? Color.white : CaptionInk.quiet)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func labelled(_ name: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 12)).foregroundStyle(CaptionInk.quiet).frame(width: 52, alignment: .leading)
            ThinSlider(name: name, value: value, range: range, held: held, set: set)
            Text("\(Int((value * 100).rounded()))%").font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 28)
    }

    private func foot(_ title: String, leftIcon: String, leftName: String,
                      left: @escaping () -> Void, tick: @escaping () -> Void) -> some View {
        ZStack {
            Text(title).font(.system(size: 14, weight: .medium))
            HStack(spacing: 0) {
                Button(action: left) {
                    HStack(spacing: 7) {
                        Image(systemName: leftIcon).font(.system(size: 15))
                        Text(leftName).font(.system(size: 11))
                    }
                    .foregroundStyle(CaptionInk.soft).frame(height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button(action: tick) {
                    Image(systemName: "checkmark").font(.system(size: 20)).frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Done")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(alignment: .top) { Rectangle().fill(CaptionInk.rule).frame(height: 0.5) }
    }

    // MARK: the wheel, and picking from the video

    private var wheel: some View {
        ColourSheet(key: part.rawValue + item.id.uuidString, hex: item.hex(of: part), alpha: item.alpha(of: part), held: held,
                    paint: { (hex: String) in change { (t: inout EditText) in t.paint(part, hex: hex) } },
                    fade: { (v: Double) in fade(v) },
                    use: { (s: SavedColours.Saved) in use(s) },
                    dropper: { screen = .dropper },
                    back: { backOut() },
                    take: { take() },
                    top: { parts(size: 14, gap: 26) })
    }

    private var dropper: some View {
        DropperSheet(hex: item.hex(of: part), back: { backOut() }, take: { take() })
    }

    private func open(_ next: CaptionScreen) {
        step()
        before = item
        screen = next
    }

    /// Back: as it was before the wheel or the eyedropper.
    private func backOut() {
        if let was = before { change { (t: inout EditText) in t.takeColours(from: was) } }
        before = nil
        screen = .main
    }

    private func take() {
        before = nil
        screen = .main
    }

    private func fade(_ v: Double) {
        change { (t: inout EditText) in t.fade(part, to: v) }
    }

    private func use(_ s: SavedColours.Saved) {
        UISelectionFeedbackGenerator().selectionChanged()
        step()
        change { (t: inout EditText) in
            t.paint(part, hex: s.hex)
            t.fade(part, to: s.alpha)
        }
    }
}

private enum CaptionTab: String, CaseIterable {
    case style = "Style"
    case colour = "Colour"
    case place = "Size & position"
}

private enum CaptionInk {
    static let quiet = Color(red: 0.494, green: 0.494, blue: 0.518)
    static let soft = Color(red: 0.79, green: 0.79, blue: 0.80)
    static let off = Color(red: 0.27, green: 0.27, blue: 0.29)
    static let rule = Color(red: 0.188, green: 0.188, blue: 0.204)
    static let tile = Color(red: 0.141, green: 0.141, blue: 0.153)
    static let rainbow: [Color] = (0...6).map { (i: Int) -> Color in Color(hue: Double(i) / 6, saturation: 1, brightness: 1) }
}
