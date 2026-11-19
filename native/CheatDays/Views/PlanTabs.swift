import SwiftUI

/// Your plan and your goal on one screen, a tab each (19 Nov). The card on Progress opens it: Budget and Cheat day
/// on Plan, the goal (and Weigh-ins' See all) on Goal. They were two screens, and the goal's was easy to miss: a tap
/// in the middle of the card only ever showed the plan. Tabs like the feed's Feed / Explore / People; swipe or tap.
struct PlanTabs: View {
    @State private var tab: Int
    init(start: Int = 0) { _tab = State(initialValue: start) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                button("Plan", 0); button("Goal", 1)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 6)
            Divider().opacity(0.6)
            TabView(selection: $tab) {
                BudgetView(embedded: true).tag(0)
                BodyView(embedded: true, active: tab == 1).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // down behind the tab bar, as the screens it holds were on their own (19 Nov: they stopped above it, on black)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Theme.bg)
        .navigationTitle("Your plan")
        .navigationBarTitleDisplayMode(.inline)
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

extension View {
    /// The screen's title, except where whatever it's inside gives one.
    @ViewBuilder func titled(_ t: String, unless inside: Bool) -> some View {
        if inside { self } else { self.navigationTitle(t).navigationBarTitleDisplayMode(.inline) }
    }
}
