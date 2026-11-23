import SwiftUI

/// The app's own icons for posts and profiles (23 Nov, design/repost-round-mockup.html and profile-tabs-compare.html:
/// send H, save B, repost X, the round comment bubble, and the profile's tab icons). Drawn here on a 24-point square
/// with round ends and corners, so they're exactly the mockups the owner chose and all one line: Apple's symbols
/// for these came in four different weights and shapes.
enum Glyph {
    case send, save, repost, comment, grid, videos, tagged, heart, more

    /// Drawn filled (the grid and the three dots always; the bookmark and heart once they're on) rather than as a line.
    var solid: Bool { self == .grid || self == .more }
}

struct GlyphShape: Shape {
    let glyph: Glyph

    func path(in rect: CGRect) -> Path {
        let k: CGFloat = min(rect.width, rect.height) / 24
        let ox: CGFloat = rect.midX - 12 * k, oy: CGFloat = rect.midY - 12 * k
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: ox + x * k, y: oy + y * k, width: w * k, height: h * k) }
        var path = Path()
        switch glyph {
        case .send:
            // a paper plane, chunky and soft (H)
            path.move(to: p(4.7, 10.1))
            path.addLine(to: p(19.2, 4))
            path.addCurve(to: p(20.1, 4.9), control1: p(19.8, 3.8), control2: p(20.3, 4.3))
            path.addLine(to: p(14.0, 19.4))
            path.addCurve(to: p(12.6, 19.4), control1: p(13.7, 20.0), control2: p(12.8, 20.0))
            path.addLine(to: p(10.4, 13.7))
            path.addLine(to: p(4.7, 11.5))
            path.addCurve(to: p(4.7, 10.1), control1: p(4.1, 11.3), control2: p(4.1, 10.4))
            path.closeSubpath()
        case .save:
            // a bookmark, wide, every corner soft (B)
            path.move(to: p(5.5, 5))
            path.addCurve(to: p(8, 2.5), control1: p(5.5, 3.62), control2: p(6.62, 2.5))
            path.addLine(to: p(16, 2.5))
            path.addCurve(to: p(18.5, 5), control1: p(17.38, 2.5), control2: p(18.5, 3.62))
            path.addLine(to: p(18.5, 20))
            path.addCurve(to: p(16.9, 20.8), control1: p(18.5, 20.8), control2: p(17.6, 21.3))
            path.addLine(to: p(12, 17.2))
            path.addLine(to: p(7.1, 20.8))
            path.addCurve(to: p(5.5, 20), control1: p(6.4, 21.3), control2: p(5.5, 20.8))
            path.closeSubpath()
        case .repost:
            // two arrows round a soft square (X)
            path.move(to: p(4, 12.5))
            path.addLine(to: p(4, 9.5))
            path.addCurve(to: p(9.5, 4), control1: p(4, 6.46), control2: p(6.46, 4))
            path.addLine(to: p(16.5, 4))
            path.move(to: p(14, 1.5)); path.addLine(to: p(16.5, 4)); path.addLine(to: p(14, 6.5))
            path.move(to: p(20, 11.5))
            path.addLine(to: p(20, 14.5))
            path.addCurve(to: p(14.5, 20), control1: p(20, 17.54), control2: p(17.54, 20))
            path.addLine(to: p(7.5, 20))
            path.move(to: p(10, 22.5)); path.addLine(to: p(7.5, 20)); path.addLine(to: p(10, 17.5))
        case .comment:
            // a round speech bubble, its tail at the bottom left
            path.move(to: p(12, 3.5))
            path.addCurve(to: p(20.5, 12), control1: p(16.69, 3.5), control2: p(20.5, 7.31))
            path.addCurve(to: p(12, 20.5), control1: p(20.5, 16.69), control2: p(16.69, 20.5))
            path.addCurve(to: p(8, 19.5), control1: p(10.6, 20.5), control2: p(9.2, 20.1))
            path.addLine(to: p(4, 20.5))
            path.addLine(to: p(5, 16.7))
            path.addCurve(to: p(3.5, 12), control1: p(4.0, 15.3), control2: p(3.5, 13.7))
            path.addCurve(to: p(12, 3.5), control1: p(3.5, 7.31), control2: p(7.31, 3.5))
            path.closeSubpath()
        case .heart:
            // the like (23 Nov: Apple's heart beside these was a different line and stood bigger; own-heart-mockup)
            path.move(to: p(12, 20))
            path.addCurve(to: p(3.5, 9.2), control1: p(12, 20), control2: p(3.5, 15))
            path.addCurve(to: p(8, 4.6), control1: p(3.5, 6.6), control2: p(5.5, 4.6))
            path.addCurve(to: p(12, 7), control1: p(9.8, 4.6), control2: p(11.2, 5.6))
            path.addCurve(to: p(16, 4.6), control1: p(12.8, 5.6), control2: p(14.2, 4.6))
            path.addCurve(to: p(20.5, 9.2), control1: p(18.5, 4.6), control2: p(20.5, 6.6))
            path.addCurve(to: p(12, 20), control1: p(20.5, 15), control2: p(12, 20))
            path.closeSubpath()
        case .more:
            for x in [CGFloat(5.5), 12, 18.5] { path.addEllipse(in: box(x - 1.7, 10.3, 3.4, 3.4)) }
        case .grid:
            // nine soft tiles, solid
            for row in 0..<3 {
                for col in 0..<3 {
                    let r: CGRect = box(2 + CGFloat(col) * 7.2, 2 + CGFloat(row) * 7.2, 5.6, 5.6)
                    path.addRoundedRect(in: r, cornerSize: CGSize(width: 1.4 * k, height: 1.4 * k), style: .continuous)
                }
            }
        case .videos:
            path.addRoundedRect(in: box(2.5, 2.5, 19, 19), cornerSize: CGSize(width: 5 * k, height: 5 * k), style: .continuous)
            path.move(to: p(10, 8.3)); path.addLine(to: p(10, 15.7)); path.addLine(to: p(16, 12)); path.closeSubpath()
        case .tagged:
            path.addRoundedRect(in: box(2.5, 2.5, 19, 19), cornerSize: CGSize(width: 5 * k, height: 5 * k), style: .continuous)
            path.addEllipse(in: box(8.8, 6.8, 6.4, 6.4))
            path.move(to: p(6.5, 20.5))
            path.addCurve(to: p(12, 15.9), control1: p(7.5, 17.5), control2: p(9.6, 15.9))
            path.addCurve(to: p(17.5, 20.5), control1: p(14.4, 15.9), control2: p(16.5, 17.5))
        }
        return path
    }
}

/// One of the app's icons at a size: a line 1.9 of its 24 points thick, as in the mockups, or filled.
struct GlyphIcon: View {
    let glyph: Glyph
    var size: CGFloat = 26
    var filled: Bool = false

    var body: some View {
        let shape = GlyphShape(glyph: glyph)
        let line: CGFloat = size * 1.9 / 24
        ZStack {
            if glyph.solid { shape.fill() } else {
                if filled { shape.fill() }
                shape.stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        // a little pop as it fills or empties (the heart liked, the bookmark saved), as Apple's symbols bounced
        .phaseAnimator([CGFloat(1), 1.22, 1], trigger: filled) { content, s in content.scaleEffect(s) } animation: { _ in .spring(response: 0.2, dampingFraction: 0.55) }
    }
}

extension Color {
    /// A post you've reposted: its icon in green, as a liked one's heart is red.
    static let reposted = Color(red: 0.30, green: 0.85, blue: 0.39)
}
