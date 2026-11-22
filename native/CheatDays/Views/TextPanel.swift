import SwiftUI

/// A text's panel, as a caption's is: its style, font, colour and size without the keyboard coming up for them
/// (design/editor-panels-mockup.html, 2). Its words are still typed on the video.
struct TextPanel<Head: View>: View {
    let item: EditText
    @Binding var screen: CaptionScreen
    let change: ((inout EditText) -> Void) -> Void
    let step: () -> Void
    let held: (Bool) -> Void
    let edit: () -> Void
    let delete: () -> Void
    let done: () -> Void
    @ViewBuilder let head: () -> Head

    @State private var tab = "Style"
    @State private var before: EditText?

    private var hex: String { ColourCode.hex(named: item.colour) }
    private var alpha: Double { item.colourAlpha ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .main: main
            case .wheel: wheel
            case .dropper: DropperSheet(hex: hex, back: { backOut() }, take: { take() })
            }
        }
        .frame(height: screen == .dropper ? 108 : 310)
        .foregroundStyle(Color.white)
        .background { ProInk.back.ignoresSafeArea(edges: .bottom) }
    }

    @ViewBuilder private var main: some View {
        head()
        ProLead(title: item.text.isEmpty ? "Text" : item.text.replacingOccurrences(of: "\n", with: " "), sub: "") {
            ProAction(icon: "pencil", name: item.text.isEmpty ? "Type" : "Edit", run: edit)
            ProDelete(name: "Delete this text", run: delete)
        }
        ProTabs(names: ["Style", "Font", "Colour", "Size"], on: tab, pick: { (name: String) in tab = name })
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
