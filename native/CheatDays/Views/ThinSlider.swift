import SwiftUI

/// A hairline slider with a small round knob, as pro editors' (design/caption-panel-pro-mockup.html). It moves as far
/// as the finger has from where it was, rather than jumping to where the finger landed.
struct ThinSlider: View {
    let name: String
    let value: Double
    let range: ClosedRange<Double>
    var track: [Color]? = nil
    let held: (Bool) -> Void
    let set: (Double) -> Void
    @State private var from: Double?
    @GestureState private var touching = false

    private static let knob: CGFloat = 14

    var body: some View {
        GeometryReader { g in
            bar(width: max(g.size.width - Self.knob, 1), height: g.size.height)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
            let step: Double = (range.upperBound - range.lowerBound) / 20
            let next: Double = direction == .increment ? value + step : value - step
            set(min(range.upperBound, max(range.lowerBound, next)))
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        let span: Double = range.upperBound - range.lowerBound
        let part: Double = min(1, max(0, (value - range.lowerBound) / max(span, 0.0001)))
        let x: CGFloat = width * CGFloat(part)
        return ZStack(alignment: .leading) {
            rail(width: width, x: x).offset(x: Self.knob / 2)
            Circle().fill(Color.white).frame(width: Self.knob, height: Self.knob).offset(x: x)
        }
        .frame(width: width + Self.knob, height: height, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, down, _ in down = true }
            .onChanged { (v: DragGesture.Value) in dragged(v.translation.width, width: width) }
            .onEnded { _ in letGo() })
        .onChange(of: touching) { (_: Bool, down: Bool) in
            if !down { letGo() }
        }
    }

    @ViewBuilder private func rail(width: CGFloat, x: CGFloat) -> some View {
        if let track {
            Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)).frame(width: width, height: 4)
        } else {
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.23)).frame(width: width, height: 2)
                Capsule().fill(Color.white).frame(width: x, height: 2)
            }
        }
    }

    private func dragged(_ dx: CGFloat, width: CGFloat) {
        if from == nil {
            from = value
            held(true)
        }
        let start: Double = from ?? value
        let moved: Double = Double(dx / width) * (range.upperBound - range.lowerBound)
        set(min(range.upperBound, max(range.lowerBound, start + moved)))
    }

    private func letGo() {
        guard from != nil else { return }
        from = nil
        held(false)
    }
}
