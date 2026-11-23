import SwiftUI

/// Your plan and your goal on one screen, a tab each (19 Nov). The card on Progress opens it: Budget and Cheat day
/// on Plan, the goal (and Weigh-ins' See all) on Goal. They were two screens, and the goal's was easy to miss: a tap
/// in the middle of the card only ever showed the plan. Tabs like the feed's Feed / Explore / People; swipe or tap.
struct PlanTabs: View {
    @State private var tab: Int
    init(start: Int = 0) { _tab = State(initialValue: start) }

    /// The page the sideways scroll is on.
    @State private var page: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                button("Plan", 0); button("Goal", 1)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 6)
            Divider().opacity(0.6)
            // The two screens side by side in a sideways scroll that pages (23 Nov). They were the pages of a paging
            // TabView, and both opened scrolled down with their top hidden behind this row ("by default the top is
            // getting cut off", then "didn't fix the issue"); 1.4.47 slid them with a drag of its own, which opened
            // them right but swiped badly ("feels a little laggy switch and a text glitch": it moved only once it was
            // sure, sprang back short of a third, and let a tap on a day's bar through, opening Sunday as it went).
            // A scroll view's own paging moves with the finger and cancels the taps under it once it scrolls.
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    BudgetView(embedded: true)
                        .containerRelativeFrame([.horizontal, .vertical]).id(0)
                    BodyView(embedded: true, active: tab == 1)
                        .containerRelativeFrame([.horizontal, .vertical]).id(1)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            .onChange(of: page) { _, now in if let now, now != tab { withAnimation(.snappy) { tab = now } } }
            .onAppear { page = tab }
            // down behind the tab bar, as the screens it holds were on their own (19 Nov: they stopped above it, on black)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Theme.bg)
        .navigationTitle("Your plan")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func button(_ title: String, _ tag: Int) -> some View {
        let on = tab == tag
        return Button { withAnimation(.snappy) { tab = tag; page = tag } } label: {
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
