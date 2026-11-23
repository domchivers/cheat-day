import SwiftUI

/// Your plan and your goal on one screen, a tab each (19 Nov). The card on Progress opens it: Budget and Cheat day
/// on Plan, the goal (and Weigh-ins' See all) on Goal. They were two screens, and the goal's was easy to miss: a tap
/// in the middle of the card only ever showed the plan. Tabs like the feed's Feed / Explore / People; swipe or tap.
struct PlanTabs: View {
    @State private var tab: Int
    init(start: Int = 0) { _tab = State(initialValue: start) }

    /// How far a swipe has the pages pulled, while it's held; and how far the finger had gone when it was taken up.
    @State private var pull: CGFloat = 0
    @State private var pullFrom: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                button("Plan", 0); button("Goal", 1)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 6)
            Divider().opacity(0.6)
            // The two screens side by side, slid by the tabs or a swipe (23 Nov). Both other ways hid each screen's
            // top behind this row: a paging TabView (1.4.43–1.4.46: "by default the top is getting cut off"), and a
            // sideways paging ScrollView (1.4.48: the row itself went up under the title, and Goal didn't show). This,
            // 1.4.47's, opened right; its swipe is reworked ("feels a little laggy switch and a text glitch"): it takes
            // the finger after 10 points with no jump, goes at a quarter or a flick, and the screens can't be touched
            // while they're being pulled, so a day's bar the swipe began on doesn't open (it moved with the finger,
            // so the finger was still on it when it lifted, and it opened Sunday).
            GeometryReader { geo in
                let w: CGFloat = geo.size.width
                ZStack(alignment: .topLeading) {
                    BudgetView(embedded: true)
                        .frame(width: w).offset(x: -CGFloat(tab) * w + pull)
                        .allowsHitTesting(tab == 0 && pullFrom == nil).accessibilityHidden(tab != 0)
                    BodyView(embedded: true, active: tab == 1)
                        .frame(width: w).offset(x: (1 - CGFloat(tab)) * w + pull)
                        .allowsHitTesting(tab == 1 && pullFrom == nil).accessibilityHidden(tab != 1)
                }
                .frame(width: w, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())   // (the swipe kept while the screens under it can't be touched)
                .simultaneousGesture(swipe(width: w))
            }
            // down behind the tab bar, as the screens it holds were on their own (19 Nov: they stopped above it, on black)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Theme.bg)
        .navigationTitle("Your plan")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A sideways swipe: taken up once it's plainly sideways, the pages following the finger from there (held back at
    /// the ends); past a quarter of the way, or flicked, it's the other tab. Up and down is the screen's own scrolling.
    private func swipe(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { (v: DragGesture.Value) in
                if pullFrom == nil {
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.2 else { return }
                    pullFrom = v.translation.width
                }
                let dx: CGFloat = v.translation.width - (pullFrom ?? 0)
                let edge: Bool = (tab == 0 && dx > 0) || (tab == 1 && dx < 0)
                pull = edge ? dx / 4 : dx
            }
            .onEnded { (v: DragGesture.Value) in
                guard pullFrom != nil else { return }
                let flick: CGFloat = v.predictedEndTranslation.width - v.translation.width
                var next: Int = tab
                if pull < -w / 4 || (pull < -12 && flick < -80) { next = min(1, tab + 1) }
                if pull > w / 4 || (pull > 12 && flick > 80) { next = max(0, tab - 1) }
                withAnimation(.snappy(duration: 0.28)) { tab = next; pull = 0 }
                // (the screens back to being touched only once the finger's off: lifted on a bar, it isn't a tap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pullFrom = nil }
            }
    }

    private func button(_ title: String, _ tag: Int) -> some View {
        let on = tab == tag
        return Button { withAnimation(.snappy) { tab = tag } } label: {
            VStack(spacing: 7) {
                Text(title).font(.headline).foregroundStyle(on ? .primary : .secondary)
                Capsule().fill(on ? Color.primary : .clear).frame(height: 2.5)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// For the UI test: Your plan as Progress opens it, pushed onto a navigation stack, to check each screen opens with
/// its top showing (23 Nov).
struct PlanTabsHarness: View {
    @State private var open = false
    var body: some View {
        NavigationStack {
            Button("Open your plan") { open = true }
                .navigationTitle("Progress")
                .navigationDestination(isPresented: $open) { PlanTabs() }
        }
    }
}

extension View {
    /// The screen's title, except where whatever it's inside gives one.
    @ViewBuilder func titled(_ t: String, unless inside: Bool) -> some View {
        if inside { self } else { self.navigationTitle(t).navigationBarTitleDisplayMode(.inline) }
    }
}
