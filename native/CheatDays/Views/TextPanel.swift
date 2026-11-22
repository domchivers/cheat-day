import SwiftUI

/// A text's panel, as a caption's is, typed in as well (design/text-typing-mockup.html; 23 Nov: typed over the whole
/// screen, it felt like a story, with every control there twice). Typing, it's the words and its tabs on the
/// keyboard, so the video keeps the room.
struct TextPanel<Head: View>: View {
    let item: EditText
    @Binding var screen: CaptionScreen
    /// Just added: it opens on the keyboard.
    let typeFirst: Bool
    let change: ((inout EditText) -> Void) -> Void
    let step: () -> Void
    let held: (Bool) -> Void
    /// The keyboard up for it, and away again.
    let typed: (Bool) -> Void
    let delete: () -> Void
    let done: () -> Void
    /// The panel's gone.
    let left: () -> Void
    @ViewBuilder let head: () -> Head

    @State private var tab = "Style"
    @State private var before: EditText?
    @State private var appeared = false
    @FocusState private var focused: Bool

    private static var keyboard: String { "Keyboard" }

    private var hex: String { ColourCode.hex(named: item.colour) }
    private var alpha: Double { item.colourAlpha ?? 1 }
    private var typing: Bool { screen == .main && (focused || tab == Self.keyboard || (typeFirst && !appeared)) }

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .main: main
            case .wheel: wheel
            case .dropper: DropperSheet(hex: hex, back: { backOut() }, take: { take() })
            }
        }
        .frame(height: tall)
        .fixedSize(horizontal: false, vertical: typing)
        .foregroundStyle(Color.white)
        .background { ProInk.back.ignoresSafeArea(edges: .bottom) }
        .onAppear { opened() }
        .onChange(of: focused) { (_: Bool, on: Bool) in focusChanged(on) }
        // (the wheel's hex box keeps the keyboard's Done; the words have a tick of their own)
        .onChange(of: screen) { (_: CaptionScreen, now: CaptionScreen) in KeyboardDone.quiet = now == .main }
        .onDisappear { closed() }
    }

    private var tall: CGFloat? {
        if screen == .dropper { return 108 }
        return typing ? nil : 310
    }

    @ViewBuilder private var main: some View {
        // (there still, with no height: taken out, the field lost the keyboard as it came up)
        VStack(spacing: 0) { head() }
            .frame(height: typing ? 0 : nil, alignment: .top).clipped()
            .opacity(typing ? 0 : 1)
            .allowsHitTesting(!typing)
            .accessibilityHidden(typing)
        wordsRow
        textTabs
        if !typing {
            ProBody {
                switch tab {
                case "Font": fonts
                case "Colour": colours
                case "Size": size
                default: styles
                }
            }
            Spacer(minLength: 0)
            ProFoot(title: "Text", left: nil, done: done)
        }
    }

    private var wordsRow: some View {
        let words = Binding<String>(get: { item.text }, set: { (new: String) in change { (t: inout EditText) in t.text = new } })
        let lines: ClosedRange<Int> = typing ? 1...3 : 1...1
        return HStack(spacing: 12) {
            TextField("Type something", text: words, axis: .vertical)
                .font(.system(size: 16)).lineLimit(lines)
                .tint(ProInk.key)
                .focused($focused)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            rowButton
        }
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(ProInk.rule).frame(height: 0.5) }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var rowButton: some View {
        if typing {
            Button { tick() } label: {
                Image(systemName: "checkmark").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Done typing")
        } else {
            ProDelete(name: "Delete this text", run: delete)
        }
    }

    /// (Five of them: closer than other panels' four, to fit a small phone.)
    private var textTabs: some View {
        let names: [String] = [Self.keyboard, "Style", "Font", "Colour", "Size"]
        return HStack(spacing: 0) {
            ForEach(names, id: \.self) { (name: String) in
                textTab(name)
                if name != "Size" { Spacer(minLength: 8) }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func textTab(_ name: String) -> some View {
        let here: Bool = typing ? name == Self.keyboard : name == tab
        return Button { pickTab(name) } label: {
            Text(name).font(.system(size: 14, weight: here ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(here ? Color.white : ProInk.quiet)
                .frame(height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(here ? .isSelected : [])
    }

    private func pickTab(_ name: String) {
        tab = name
        focused = name == Self.keyboard
    }

    private func opened() {
        guard !appeared else { return }
        appeared = true
        KeyboardDone.quiet = true
        guard typeFirst else { return }
        tab = Self.keyboard
        // (once it's on the screen: asked as it arrived, the keyboard didn't come)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if tab == Self.keyboard { focused = true }
        }
    }

    private func focusChanged(_ on: Bool) {
        if on {
            KeyboardDone.quiet = true
            tab = Self.keyboard
        } else if tab == Self.keyboard {
            tab = "Style"
        }
        typed(on)
    }

    /// The tick over the keyboard: it away; nothing typed, the text's not wanted.
    private func tick() {
        focused = false
        tab = "Style"
        if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { done() }
    }

    private func closed() {
        KeyboardDone.quiet = false
        typed(false)
        left()
    }

    private var styles: some View {
        HStack(spacing: 8) {
            ForEach(EditText.textStyles, id: \.self) { (style: String) in styleTile(style) }
        }
    }

    private func styleTile(_ style: String) -> some View {
        var sample = EditText(kind: "text", text: "Text", style: style, colour: item.colour, from: 0, to: 2)
        sample.font = item.font
        sample.colourAlpha = item.colourAlpha
        let shown: EditText = sample
        return ProTile(name: style, on: item.style == style, pick: {
            guard item.style != style else { return }
            step()
            change { (t: inout EditText) in t.style = style }
        }, preview: {
            EditTextView(item: shown, at: 0).fixedSize().scaleEffect(0.56)
        })
    }

    private var fonts: some View {
        HStack(spacing: 8) {
            ForEach(EditText.fonts, id: \.self) { (font: String) in fontTile(font) }
        }
    }

    private func fontTile(_ font: String) -> some View {
        let on: Bool = (item.font ?? "classic") == font
        return ProTile(name: font.capitalized, on: on, pick: {
            guard !on else { return }
            step()
            change { (t: inout EditText) in t.font = font == "classic" ? nil : font }
        }, preview: {
            Text("Aa").font(EditText.font(font, size: 22))
        })
    }

    private var colours: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ToolSwatch(icon: "eyedropper", name: "Pick a colour from the video") { open(.dropper) }
                    WheelSwatch { open(.wheel) }
                    Rectangle().fill(ProInk.off).frame(width: 0.5, height: 20).padding(.horizontal, 2)
                    ForEach(SavedColours.shared.list, id: \.self) { (s: SavedColours.Saved) in
                        SavedSwatch(saved: s, on: s.hex == hex && abs(s.alpha - alpha) < 0.006, pick: { use(s) })
                    }
                    Rectangle().fill(ProInk.off).frame(width: 0.5, height: 20).padding(.horizontal, 2)
                    ForEach(EditText.palette, id: \.self) { (colour: String) in paletteSwatch(colour) }
                }
                .padding(3)
            }
            ProSlide(name: "Opacity", value: alpha, range: 0...1, shown: ProSlide.percent(alpha), held: held,
                     set: { (v: Double) in fade(v) })
        }
    }

    private func paletteSwatch(_ colour: String) -> some View {
        let on: Bool = hex == colour
        return Button {
            guard !on else { return }
            step()
            paint(colour)
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(StoryArt.color(colour))
                .frame(width: 28, height: 28)
                .overlay(PickedOutline(on: on))
        }
        .buttonStyle(.plain).accessibilityLabel("Colour " + colour)
    }

    private var size: some View {
        VStack(spacing: 14) {
            ProSlide(name: "Size", value: item.size, range: 0.4...3, shown: ProSlide.percent(item.size), held: held,
                     set: { (v: Double) in change { (t: inout EditText) in t.size = v } })
            ProHint(words: "Or use the dot on the video, or pinch.")
        }
    }

    private var wheel: some View {
        ColourSheet(key: item.id.uuidString, hex: hex, alpha: alpha, held: held,
                    paint: { (made: String) in paint(made) },
                    fade: { (v: Double) in fade(v) },
                    use: { (s: SavedColours.Saved) in use(s) },
                    dropper: { screen = .dropper },
                    back: { backOut() },
                    take: { take() },
                    top: { wheelTop })
    }

    private var wheelTop: some View {
        Text("Text colour").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ next: CaptionScreen) {
        step()
        before = item
        screen = next
    }

    private func backOut() {
        if let was = before {
            change { (t: inout EditText) in
                t.colour = was.colour
                t.colourAlpha = was.colourAlpha
            }
        }
        take()
    }

    private func take() {
        before = nil
        screen = .main
    }

    private func paint(_ made: String) {
        change { (t: inout EditText) in t.colour = made }
    }

    private func fade(_ v: Double) {
        change { (t: inout EditText) in t.colourAlpha = v < 1 ? v : nil }
    }

    private func use(_ s: SavedColours.Saved) {
        step()
        paint(s.hex)
        fade(s.alpha)
    }
}
