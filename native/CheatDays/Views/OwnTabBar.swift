import SwiftUI

/// What our own tab bar needs to know from the rest of the app: the pages that want the screen to themselves, and
/// where each button sits (for the tour).
@Observable final class OwnBar {
    static let shared = OwnBar()
    var hiders = Set<UUID>()
    var homeInset: CGFloat = 34   // the home indicator's strip; 0 on a phone with a button
    @ObservationIgnored var frames: [String: CGRect] = [:]
    var hidden: Bool { !hiders.isEmpty }
    /// How far the bar lifts the bottom of a tab's content: what Apple's bar did, so nothing on any page moved.
    var space: CGFloat { hidden ? 0 : max(49, 83 - homeInset) }
}

/// The tab bar, drawn by the app rather than Apple's, to Instagram's measurements: 58 high, a lighter pill 44 high
/// behind the tab you're on with 7 clear all round, icons about 23, your photo 24.
struct OwnTabBar: View {
    @Binding var tab: Int
    @Namespace private var pill
    private static let items: [(tag: Int, symbol: String, name: String)] = [
        (0, "fork.knife", "Today"), (1, "dumbbell.fill", "Workouts"), (4, "chart.line.uptrend.xyaxis", "Progress"),
        (2, "person.2.fill", "Friends"), (3, "person.crop.circle.fill", "Me")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items, id: \.tag) { it in button(it.tag, it.symbol, it.name) }
        }
        .padding(.horizontal, 7).frame(height: 58)
        .ownBarGlass()
        .padding(.horizontal, 21)
        .animation(.snappy(duration: 0.25), value: tab)
        .onAppear {
            if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first { OwnBar.shared.homeInset = win.safeAreaInsets.bottom }
        }
    }

    private func button(_ tag: Int, _ symbol: String, _ name: String) -> some View {
        let on = tab == tag, unread = tag == 2 ? FriendActivity.shared.unread : 0
        return Button { tab = tag } label: {
            icon(tag, symbol, on: on)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text("\(min(unread, 99))").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 17, minHeight: 17).background(Color.red, in: Capsule()).offset(x: 9, y: -7)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 44)
                .background { if on { Capsule().fill(Color.primary.opacity(0.16)).matchedGeometryEffect(id: "on", in: pill) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unread > 0 ? "\(name), \(unread) new" : name)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { OwnBar.shared.frames[name] = $0 }
    }

    @ViewBuilder private func icon(_ tag: Int, _ symbol: String, on: Bool) -> some View {
        // your photo, once you've added one
        if tag == 3, let photo = on ? Profiles.shared.meIconOn : Profiles.shared.meIcon {
            Image(uiImage: photo).renderingMode(.original)
        } else {
            Image(uiImage: TabGlyph.make(symbol)).renderingMode(.template).foregroundStyle(on ? Theme.accent : Color.primary)
        }
    }
}

private struct OwnBarTab: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .background { BarSpace(space: OwnBar.shared.space).frame(width: 0, height: 0).accessibilityHidden(true) }
    }
}

/// The room Apple's bar kept at the bottom of a tab, given back as the tab's own safe area, the way UIKit does it: a
/// SwiftUI safeAreaInset outside the tab's NavigationStack didn't reach what's inside (the feed's + sat under the bar).
private struct BarSpace: UIViewControllerRepresentable {
    let space: CGFloat
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ vc: Probe, context: Context) { vc.space = space; vc.apply() }

    final class Probe: UIViewController {
        var space: CGFloat = 0
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); apply() }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); apply() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }
        func apply() {
            // the controller the tab bar controller holds for this tab
            var vc: UIViewController? = self
            while let c = vc, !(c.parent is UITabBarController) { vc = c.parent }
            if let host = vc, host.additionalSafeAreaInsets.bottom != space { host.additionalSafeAreaInsets.bottom = space }
        }
    }
}

private struct HidesOwnBar: ViewModifier {
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { OwnBar.shared.hiders.insert(id) }
            .onDisappear { OwnBar.shared.hiders.remove(id) }
    }
}

extension View {
    /// On a TabView: our bar over it, 23 up from the bottom of the screen where Apple's sat, behind the keyboard.
    func ownTabBar(_ tab: Binding<Int>) -> some View {
        overlay {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if !OwnBar.shared.hidden { OwnTabBar(tab: tab).padding(.bottom, 23).transition(.opacity) }
            }
            .ignoresSafeArea(.all, edges: .bottom)
            .animation(.easeInOut(duration: 0.2), value: OwnBar.shared.hidden)
        }
    }
    /// On each tab's root: Apple's bar hidden, and the room it kept at the bottom given back.
    func ownBarTab() -> some View { modifier(OwnBarTab()) }
    /// On a page that has the screen to itself (Settings): the bar steps aside while it's showing.
    func hidesOwnBar() -> some View { modifier(HidesOwnBar()) }

    @ViewBuilder fileprivate func ownBarGlass() -> some View {
        if #available(iOS 26, *) { glassEffect(.regular, in: Capsule()) }
        else { background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(Color.primary.opacity(0.1))) }
    }
}
