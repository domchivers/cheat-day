import SwiftUI

/// Your plan and your goal on one screen, a tab each (19 Nov). The card on Progress opens it: Budget and Cheat day
/// on Plan, the goal (and Weigh-ins' See all) on Goal. They were two screens, and the goal's was easy to miss: a tap
/// in the middle of the card only ever showed the plan. Tabs like the feed's Feed / Explore / People; swipe or tap.
struct PlanTabs: View {
    @State private var tab: Int
    init(start: Int = 0) { _tab = State(initialValue: start) }

    /// How far a swipe has the pages pulled, while it's held.
    @State private var pull: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                button("Plan", 0); button("Goal", 1)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 6)
            Divider().opacity(0.6)
            // The two screens side by side, slid along by the tabs or a swipe (23 Nov, twice: "by default the top is
            // getting cut off", then "didn't fix the issue"). They were the pages of a paging TabView, and both opened
            // scrolled down with their top hidden, seen only by pulling down; a paging TabView is the only place in the
            // app a scrolling screen sat, and moving the row into an inset didn't help, so it's gone: each screen is
            // laid out as one on its own is. Both are kept, so each stays where it was scrolled to.
            GeometryReader { geo in
                let w: CGFloat = geo.size.width
                ZStack(alignment: .topLeading) {
                    BudgetView(embedded: true)
                        .frame(width: w).offset(x: -CGFloat(tab) * w + pull)
                        .allowsHitTesting(tab == 0).accessibilityHidden(tab != 0)
                    BodyView(embedded: true, active: tab == 1)
                        .frame(width: w).offset(x: (1 - CGFloat(tab)) * w + pull)
                        .allowsHitTesting(tab == 1).accessibilityHidden(tab != 1)
                }
                .frame(width: w, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .simultaneousGesture(swipe(width: w))
            }
            // down behind the tab bar, as the screens it holds were on their own (19 Nov: they stopped above it, on black)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Theme.bg)
        .navigationTitle("Your plan")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A sideways swipe: the pages follow the finger (held back at the ends), and past a third of the way, or flicked,
    /// it's the other tab. An up-and-down drag is left to the screen's own scrolling.
    private func swipe(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { (v: DragGesture.Value) in
                guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                let dx: CGFloat = v.translation.width
                let edge: Bool = (tab == 0 && dx > 0) || (tab == 1 && dx < 0)
                pull = edge ? dx / 4 : dx
            }
            .onEnded { (v: DragGesture.Value) in
                let dx: CGFloat = v.predictedEndTranslation.width
                var next: Int = tab
                if pull != 0 && abs(dx) > w / 3 { next = dx < 0 ? min(1, tab + 1) : max(0, tab - 1) }
                withAnimation(.snappy(duration: 0.3)) { tab = next; pull = 0 }
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
