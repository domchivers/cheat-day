import SwiftUI

/// The colour wheel's screen, for a caption's parts and for text (design/caption-colour-mockup.html).
struct ColourSheet<Top: View>: View {
    /// What's being coloured: another, and the wheel goes to its colour.
    let key: String
    let hex: String
    let alpha: Double
    let held: (Bool) -> Void
    let paint: (String) -> Void
    let fade: (Double) -> Void
    let use: (SavedColours.Saved) -> Void
    let dropper: () -> Void
    let back: () -> Void
    let take: () -> Void
    @ViewBuilder let top: () -> Top

    @State private var hsb = ColourCode.HSB(hue: 0, saturation: 0, brightness: 1)
    @State private var code = ""

    private var saved: SavedColours { SavedColours.shared }

    var body: some View {
        VStack(spacing: 0) {
            top().padding(.horizontal, 16).frame(height: 50)
            HStack(spacing: 22) {
                ColourWheel(hue: hsb.hue, saturation: hsb.saturation, held: held,
                            pick: { (hue: Double, strength: Double) in turned(hue, strength) },
                            diameter: 138)
                adjust
            }
            .padding(.horizontal, 16)
            .frame(height: 150)
            savedRow
            Spacer(minLength: 0)
            ProFoot(title: "Colour", left: SheetAction(icon: "chevron.left", name: "Back", run: back), done: take)
        }
        .onAppear { load() }
        .onChange(of: key) { (_: String, _: String) in load() }
        .onChange(of: hex) { (_: String, new: String) in
            // (changed from outside it; its own keeps the hue that black and white have none of)
            if new != ColourCode.hex(hsb) { load() }
        }
    }

    private var adjust: some View {
        let colour: Color = StoryArt.color(hex)
        let bright: Color = Color(hue: hsb.hue, saturation: hsb.saturation, brightness: 1)
        return VStack(spacing: 2) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 5).fill(colour).frame(width: 22, height: 22)
                TextField("#FFFFFF", text: $code)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .onChange(of: code) { (_: String, new: String) in typed(new) }
                Button(action: dropper) {
                    Image(systemName: "eyedropper").frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Pick a colour from the video")
            }
            .frame(height: 30)
            number("Brightness", hsb.brightness)
            ThinSlider(name: "Brightness", value: hsb.brightness, range: 0...1, track: [Color.black, bright],
                       held: held, set: { (v: Double) in brightened(v) })
            number("Opacity", alpha)
            ThinSlider(name: "Opacity", value: alpha, range: 0...1, track: [colour.opacity(0.08), colour],
                       held: held, set: fade)
        }
        .frame(maxWidth: .infinity)
    }

    private func number(_ name: String, _ value: Double) -> some View {
        HStack {
            Text(name).foregroundStyle(ProInk.quiet)
            Spacer(minLength: 0)
            Text(ProSlide.percent(value)).monospacedDigit()
        }
        .font(.system(size: 12))
        .frame(height: 18)
    }

    private var savedRow: some View {
        HStack(spacing: 10) {
            Text("Saved").font(.system(size: 11)).foregroundStyle(ProInk.quiet)
            ToolSwatch(icon: "plus", name: "Save this colour") {
                saved.add(hex: hex, alpha: alpha)
                UISelectionFeedbackGenerator().selectionChanged()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(saved.list, id: \.self) { (s: SavedColours.Saved) in
                        SavedSwatch(saved: s, on: s.hex == hex && abs(s.alpha - alpha) < 0.006, pick: { use(s) })
                    }
                }
                .padding(3)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private func load() {
        hsb = ColourCode.hsb(hex)
        code = hex
    }

    private func turned(_ hue: Double, _ strength: Double) {
        var c: ColourCode.HSB = hsb
        c.hue = hue
        c.saturation = strength
        // (from black, round the wheel stayed black)
        if c.brightness < 0.02 { c.brightness = 1 }
        show(c)
    }

    private func brightened(_ v: Double) {
        var c: ColourCode.HSB = hsb
        c.brightness = v
        show(c)
    }

    private func show(_ c: ColourCode.HSB) {
        let made: String = ColourCode.hex(c)
        hsb = c
        code = made
        paint(made)
    }

    private func typed(_ text: String) {
        guard let made = ColourCode.typed(text), made != ColourCode.hex(hsb) else { return }
        // (the wheel's own colour back, not typed)
        guard made != hex else { return }
        hsb = ColourCode.hsb(made)
        paint(made)
    }
}

/// The short sheet while a colour's picked from the video.
struct DropperSheet: View {
    let hex: String
    let back: () -> Void
    let take: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5).fill(StoryArt.color(hex)).frame(width: 22, height: 22)
                Text("Drag on the video to pick a colour").font(.system(size: 13)).foregroundStyle(ProInk.soft)
                Spacer(minLength: 0)
                Text(hex).font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 16)
            .frame(height: 60)
            ProFoot(title: "Pick from video", left: SheetAction(icon: "chevron.left", name: "Back", run: back), done: take)
        }
    }
}

struct ToolSwatch: View {
    let icon: String
    let name: String
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(ProInk.soft)
                .frame(width: 28, height: 28)
                .background(ProInk.tile, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityLabel(name)
    }
}

struct WheelSwatch: View {
    let run: () -> Void
    private static let hues: [Color] = (0...6).map { (i: Int) -> Color in Color(hue: Double(i) / 6, saturation: 1, brightness: 1) }

    var body: some View {
        Button(action: run) {
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: Self.hues), center: .center))
                Circle().fill(RadialGradient(gradient: Gradient(colors: [Color.white, Color.white.opacity(0)]),
                                             center: .center, startRadius: 0, endRadius: 12))
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain).accessibilityLabel("Colour wheel")
    }
}

struct PickedOutline: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(on ? Color.white : Color.clear, lineWidth: 1.5)
            .padding(-2.5)
            .allowsHitTesting(false)
    }
}

/// A saved colour; held, it can be deleted.
struct SavedSwatch: View {
    let saved: SavedColours.Saved
    let on: Bool
    let pick: () -> Void

    var body: some View {
        Button {
            guard !on else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            pick()
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(StoryArt.color(saved.hex).opacity(max(0.12, saved.alpha)))
                .frame(width: 28, height: 28)
                .overlay(PickedOutline(on: on))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Saved colour \(saved.hex)")
        .contextMenu {
            Button(role: .destructive) { SavedColours.shared.remove(saved) } label: { Label("Delete saved colour", systemImage: "trash") }
        }
    }
}
