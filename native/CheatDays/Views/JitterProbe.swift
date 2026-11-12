import SwiftUI
import UIKit

/// A measuring screen (UI tests only, `-uitest-jitter`): the same small tile, made many times bigger, slid a twentieth
/// of a point at a time, built four ways. A test reads off the screen where each one's edge really is, to see which
/// ways follow smoothly and which jump.
///   A  made bigger, then put at the place with `.position` (how the story editor places text and stickers)
///   B  made bigger, kept at one place, slid with `.transformEffect`
///   C  kept at one place and plain size; bigger and slid in one `.transformEffect`
///   D  made bigger, kept at one place, slid with `.offset`
struct JitterProbe: View {
    @State private var k = 0
    static let steps = 25
    private let tile: UIImage = {
        let f = UIGraphicsImageRendererFormat(); f.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: f).image { c in
            UIColor.black.setFill(); c.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
            UIColor.white.setFill(); c.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
        }
    }()

    static func scale(_ k: Int) -> CGFloat { k < steps ? 30 : 4 }
    static func x(_ k: Int) -> CGFloat { 150.02 + CGFloat(k % steps) * 0.05 }

    var body: some View {
        let s = Self.scale(k), x = Self.x(k)
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 100)
            band { Image(uiImage: tile).scaleEffect(s).position(x: x, y: 60) }
            band { Image(uiImage: tile).scaleEffect(s).position(x: 150, y: 60).transformEffect(CGAffineTransform(translationX: x - 150, y: 0)) }
            band {
                Image(uiImage: tile).frame(width: 40, height: 40).position(x: 20, y: 20)
                    .transformEffect(CGAffineTransform(translationX: x, y: 60).scaledBy(x: s, y: s).translatedBy(x: -20, y: -20))
            }
            band { Image(uiImage: tile).scaleEffect(s).position(x: 150, y: 60).offset(x: x - 150) }
            Spacer()
            HStack {
                Text("k=\(k)").foregroundStyle(.gray).accessibilityIdentifier("probe-k")
                Button("Next") { k += 1 }.accessibilityIdentifier("probe-next")
            }
            .frame(maxWidth: .infinity).padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
    }

    private func band<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ZStack(alignment: .topLeading) { Color.black; content() }
            .frame(maxWidth: .infinity).frame(height: 120).clipped()
    }
}
