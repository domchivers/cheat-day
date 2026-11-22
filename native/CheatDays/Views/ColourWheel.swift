import SwiftUI

/// The colour wheel: round it for the colour, out from the middle for how strong.
struct ColourWheel: View {
    let hue: Double
    let saturation: Double
    let held: (Bool) -> Void
    let pick: (Double, Double) -> Void
    let diameter: CGFloat
    @State private var down = false
    @GestureState private var touching = false

    private static let hues: [Color] = (0...6).map { (i: Int) -> Color in
        Color(hue: Double(i) / 6, saturation: 1, brightness: 1)
    }

    var body: some View {
        let r: CGFloat = diameter / 2
        let angle: Double = hue * 2 * Double.pi
        let out: CGFloat = r * CGFloat(min(1, saturation))
        let dx: CGFloat = out * CGFloat(cos(angle))
        let dy: CGFloat = out * CGFloat(sin(angle))
        return ZStack {
            Circle().fill(AngularGradient(gradient: Gradient(colors: Self.hues), center: .center))
            Circle().fill(RadialGradient(gradient: Gradient(colors: [Color.white, Color.white.opacity(0)]),
                                         center: .center, startRadius: 0, endRadius: r))
            Circle().stroke(Color.white, lineWidth: 2).frame(width: 17, height: 17)
                .shadow(color: Color.black.opacity(0.4), radius: 1)
                .offset(x: dx, y: dy)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, on, _ in on = true }
            .onChanged { (v: DragGesture.Value) in moved(v.location, radius: r) }
            .onEnded { _ in letGo() })
        .onChange(of: touching) { (_: Bool, on: Bool) in
            if !on { letGo() }
        }
        .onDisappear { letGo() }
        .accessibilityLabel("Colour wheel")
    }

    private func moved(_ at: CGPoint, radius: CGFloat) {
        if !down {
            down = true
            held(true)
        }
        let x: Double = Double(at.x - radius)
        let y: Double = Double(at.y - radius)
        var turn: Double = atan2(y, x) / (2 * Double.pi)
        if turn < 0 { turn += 1 }
        let strength: Double = min(1, hypot(x, y) / Double(max(radius, 1)))
        pick(turn, strength)
    }

    private func letGo() {
        guard down else { return }
        down = false
        held(false)
    }
}
