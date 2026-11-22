import SwiftUI

/// As wide as its words, wrapped at a width: the same on the screen, which offers all the room there is, and drawn
/// for the finished video, which offers none.
struct HugWidth: Layout {
    let most: CGFloat

    struct UpTo: ViewModifier {
        let most: CGFloat

        func body(content: Content) -> some View {
            HugWidth(most: most) { content }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let wide: CGFloat = min(most, proposal.width ?? most)
        return child.sizeThatFits(ProposedViewSize(width: wide, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
