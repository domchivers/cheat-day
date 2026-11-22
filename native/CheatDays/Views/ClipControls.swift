import SwiftUI

/// A clip's speed on a ruler, a click at 0.25, 0.5, 1, 2 and 4 times.
struct SpeedRuler: View {
    let speed: Double
    let held: (Bool) -> Void
    let set: (Double) -> Void
    @State private var from: Double?
    @GestureState private var touching = false

    static let stops: [Double] = [0.25, 0.5, 1, 2, 4]

    /// The speed at a place along it, held on a stop it's near.
    static func speed(at place: Double) -> Double {
        let p: Double = min(2, max(-2, place))
        for stop in stops where abs(p - log2(stop)) < 0.08 { return stop }
        return min(4, max(0.25, (pow(2.0, p) * 20).rounded() / 20))
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { g in
                ruler(g.size)
            }
            .frame(height: 34)
            GeometryReader { g in
                labels(width: max(g.size.width - 20, 1))
            }
            .frame(height: 24)
        }
        .accessibilityElement()
        .accessibilityLabel("Speed")
        .accessibilityValue(Self.name(speed))
        .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
            let by: Double = direction == .increment ? 0.25 : -0.25
            set(Self.speed(at: log2(max(0.25, speed)) + by))
        }
    }

    static func name(_ x: Double) -> String {
        var s: String = String(format: "%.2f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "×"
    }

    private func labels(width w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.stops, id: \.self) { (stop: Double) in
                mark(stop).frame(width: 52).position(x: 10 + w * CGFloat((log2(stop) + 2) / 4), y: 12)
            }
        }
    }

    private func ruler(_ size: CGSize) -> some View {
        let w: CGFloat = max(size.width - 20, 1)
        let here: Double = log2(min(4, max(0.25, speed)))
        let x: CGFloat = 10 + w * CGFloat((here + 2) / 4)
        return ZStack(alignment: .topLeading) {
            Canvas { (ctx: inout GraphicsContext, box: CGSize) in
                for i in 0...40 {
                    let big: Bool = i % 10 == 0
                    let h: CGFloat = big ? 17 : 9
                    let tick = CGRect(x: 10 + w * CGFloat(i) / 40 - 0.5, y: box.height - 4 - h, width: 1, height: h)
                    ctx.fill(Path(tick), with: .color(Color(white: big ? 0.67 : 0.34)))
                }
            }
            Rectangle().fill(Color.white).frame(width: 2, height: size.height).offset(x: x - 1)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, down, _ in down = true }
            .onChanged { (v: DragGesture.Value) in dragged(v.translation.width, width: w, here: here) }
            .onEnded { _ in letGo() })
        .onChange(of: touching) { (_: Bool, down: Bool) in
            if !down { letGo() }
        }
        .onDisappear { letGo() }
    }

    private func mark(_ stop: Double) -> some View {
        Button { set(stop) } label: {
            Text(Self.name(stop)).font(.system(size: 11)).foregroundStyle(stop == speed ? Color.white : ProInk.quiet)
                .frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dragged(_ dx: CGFloat, width: CGFloat, here: Double) {
        if from == nil {
            guard abs(dx) > 0.5 else { return }
            from = here
            held(true)
        }
        let place: Double = (from ?? here) + Double(dx / width) * 4
        let next: Double = Self.speed(at: place)
        guard next != speed else { return }
        if Self.stops.contains(next) { UISelectionFeedbackGenerator().selectionChanged() }
        set(next)
    }

    private func letGo() {
        guard from != nil else { return }
        from = nil
        held(false)
    }
}

/// Adjust's tools as icons, with their names.
struct TuneTools: View {
    let tools: [(id: String, name: String, icon: String)]
    let on: String
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tools.indices, id: \.self) { (i: Int) in tool(tools[i]) }
        }
    }

    private func tool(_ t: (id: String, name: String, icon: String)) -> some View {
        let here: Bool = t.id == on
        return Button { pick(t.id) } label: {
            VStack(spacing: 5) {
                Image(systemName: t.icon).font(.system(size: 17)).frame(height: 20)
                Text(t.name).font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(here ? Color.white : ProInk.quiet)
            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
