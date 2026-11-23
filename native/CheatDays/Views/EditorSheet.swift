import SwiftUI

/// The editor's panels' colours (design/editor-panels-mockup.html).
enum ProInk {
    static let back = Color(red: 0.086, green: 0.086, blue: 0.094)
    static let quiet = Color(red: 0.494, green: 0.494, blue: 0.518)
    static let soft = Color(red: 0.79, green: 0.79, blue: 0.80)
    static let off = Color(red: 0.27, green: 0.27, blue: 0.29)
    static let rule = Color(red: 0.188, green: 0.188, blue: 0.204)
    static let tile = Color(red: 0.141, green: 0.141, blue: 0.153)
    static let key = Color(red: 1, green: 0.816, blue: 0.231)
}

/// What's on the left of a panel's bottom bar.
struct SheetAction {
    var icon: String
    var name: String
    var run: () -> Void

    /// Going back, rather than doing something to what's picked.
    var isBack: Bool { icon == "chevron.left" }
}

/// A panel as pro editors lay them out: one flat sheet of one height, the transport and strip along its top, its name
/// and tick along the bottom, under the thumb.
struct ProSheet<Head: View, Main: View>: View {
    let title: String
    let left: SheetAction?
    let done: () -> Void
    /// How tall with the keyboard up, when the transport and strip make way.
    var whileTyping: CGFloat = 244
    @ViewBuilder let head: () -> Head
    @ViewBuilder let main: () -> Main
    @State private var typing = false

    static var height: CGFloat { 310 }

    var body: some View {
        VStack(spacing: 0) {
            // (there still, with no height: taken out, a row scrolled along came back at its start)
            VStack(spacing: 0) { head() }
                .frame(height: typing ? 0 : nil, alignment: .top).clipped()
                .opacity(typing ? 0 : 1)
                .allowsHitTesting(!typing)
                .accessibilityHidden(typing)
            VStack(spacing: 0) { main() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            ProFoot(title: title, left: left, done: done)
        }
        .frame(height: typing ? whileTyping : Self.height)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
        .foregroundStyle(Color.white)
        .background { ProInk.back.ignoresSafeArea(edges: .bottom) }
    }
}

struct ProFoot: View {
    let title: String
    let left: SheetAction?
    let done: () -> Void

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).frame(maxWidth: 150)
            HStack(spacing: 0) {
                if let left {
                    if left.isBack { backButton(left) } else { leftButton(left) }
                }
                Spacer(minLength: 0)
                Button(action: done) {
                    Image(systemName: "checkmark").font(.system(size: 20)).frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Done")
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(alignment: .top) { Rectangle().fill(ProInk.rule).frame(height: 0.5) }
    }

    /// As every other back in the editor (23 Nov: small and grey with a word, it looked like Apply to all).
    private func backButton(_ a: SheetAction) -> some View {
        Button(action: a.run) {
            Image(systemName: a.icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.white)
                .frame(width: 44, height: 48, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(a.name == "Back" ? "Back" : "Back to \(a.name)")
    }

    private func leftButton(_ a: SheetAction) -> some View {
        Button(action: a.run) {
            HStack(spacing: 7) {
                Image(systemName: a.icon).font(.system(size: 15))
                Text(a.name).font(.system(size: 11))
            }
            .foregroundStyle(ProInk.soft).frame(height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What a panel's for, and what can be done to it.
struct ProLead<Actions: View>: View {
    let title: String
    let sub: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 15)).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(ProInk.quiet).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) { actions() }.fixedSize()
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(ProInk.rule).frame(height: 0.5) }
        .padding(.horizontal, 16)
    }
}

/// A small icon with its name; on, white (a keyframe's, yellow).
struct ProAction: View {
    let icon: String
    let name: String
    var on = false
    var enabled = true
    var lit: Color = .white
    let run: () -> Void

    var body: some View {
        let ink: Color = on ? lit : ProInk.soft
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            run()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13))
                Text(name).font(.system(size: 11, weight: on ? .bold : .regular)).lineLimit(1)
            }
            .foregroundStyle(ink).frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct ProDelete: View {
    let name: String
    let run: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Rectangle().fill(ProInk.off).frame(width: 0.5, height: 22)
            Button(action: run) {
                Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(ProInk.soft)
                    .frame(width: 24, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(name)
        }
    }
}

/// A panel's tabs: words, white for the one open.
struct ProTabs: View {
    let names: [String]
    let on: String
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 26) {
            ForEach(names, id: \.self) { (name: String) in tab(name) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func tab(_ name: String) -> some View {
        let here: Bool = name == on
        return Button { pick(name) } label: {
            Text(name).font(.system(size: 14, weight: here ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(here ? Color.white : ProInk.quiet)
                .frame(height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(here ? .isSelected : [])
    }
}

/// The 104 points under a panel's tabs (144 with no tabs).
struct ProBody<Content: View>: View {
    private let height: CGFloat
    private let spacing: CGFloat
    private let content: Content

    // (made now, not in this view's own body: that ran after the caller had checked the clip or sound was still there)
    init(height: CGFloat = 104, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.height = height
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(spacing: spacing) { content }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, 16)
    }
}

/// A choice shown, not only named: a thin white outline round the one picked.
struct ProTile<Preview: View>: View {
    let name: String
    let on: Bool
    var tall: CGFloat = 62
    let pick: () -> Void
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let outline: Color = on ? Color.white : Color.clear
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            pick()
        } label: {
            VStack(spacing: 5) {
                shape.fill(ProInk.tile)
                    .overlay { preview().foregroundStyle(Color.white).allowsHitTesting(false) }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(outline, lineWidth: 1.5))
                    .frame(height: tall)
                Text(name).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(on ? Color.white : ProInk.quiet)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct ProOption: Identifiable {
    var id: String
    var name: String
}

/// A row of words to choose among, after what they're for.
struct ProPick: View {
    let title: String
    let options: [ProOption]
    let value: String
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 16) {
            if !title.isEmpty {
                Text(title).font(.system(size: 12)).foregroundStyle(ProInk.quiet).lineLimit(1).frame(width: 58, alignment: .leading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(options) { (o: ProOption) in choice(o) }
                }
            }
        }
        .frame(height: 30)
    }

    private func choice(_ o: ProOption) -> some View {
        let here: Bool = o.id == value
        return Button {
            // (the one shown as picked too: it can be what some have, or what's to be done again)
            UISelectionFeedbackGenerator().selectionChanged()
            pick(o.id)
        } label: {
            Text(o.name).font(.system(size: 13, weight: here ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(here ? Color.white : ProInk.quiet)
                .frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(here ? .isSelected : [])
    }
}

/// A hairline slider after its name, its number after it.
struct ProSlide: View {
    let name: String
    let value: Double
    let range: ClosedRange<Double>
    let shown: String
    let held: (Bool) -> Void
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 12)).foregroundStyle(ProInk.quiet).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 58, alignment: .leading)
            ThinSlider(name: name, value: value, range: range, said: shown, held: held, set: set)
            Text(shown).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 42, alignment: .trailing)
        }
        .frame(height: 28)
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func seconds(_ v: Double) -> String { v < 0.05 ? "Off" : String(format: "%.1f s", v) }
}

struct ProHint: View {
    let words: String
    var warn = false

    var body: some View {
        Text(words).font(.system(size: 12)).foregroundStyle(warn ? Theme.warn : ProInk.quiet)
            .multilineTextAlignment(.leading).lineLimit(2).minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch with what it is and where it shows.
struct ProSwitch: View {
    let title: String
    let sub: String
    @Binding var on: Bool
    var open: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if let open { open() } else { on.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    Text(sub).font(.system(size: 11)).foregroundStyle(ProInk.quiet)
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle(title, isOn: $on).labelsHidden().tint(Color(red: 0.19, green: 0.82, blue: 0.35))
                .scaleEffect(0.72).frame(width: 40)
        }
    }
}

/// Where a row of tools has slid to: its content's left edge, against the row's own.
struct ToolsLeft: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
