import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A photo editor for posts, like Instagram's: pick the shape (tall 4:5, square or wide), pinch to zoom, drag to
/// place it, rotate, and adjust brightness, contrast and colour. Gives back the finished picture at 1080 px wide.
struct PhotoEditor: View {
    let original: UIImage
    var done: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Shape: String, CaseIterable, Identifiable {
        case tall = "4:5", square = "1:1", wide = "16:9"
        var id: String { rawValue }
        var ratio: CGFloat { switch self { case .tall: return 4 / 5; case .square: return 1; case .wide: return 16 / 9 } }
        var symbol: String { switch self { case .tall: return "rectangle.portrait"; case .square: return "square"; case .wide: return "rectangle" } }
    }

    @State private var shape: Shape = .tall
    @State private var base: UIImage            // rotated, shrunk to a sensible size once
    @State private var shown: UIImage           // with the adjustments
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var moving = false
    @State private var brightness = 0.0
    @State private var contrast = 1.0
    @State private var saturation = 1.0
    @State private var tab = 0
    private static let ci = CIContext()

    init(image: UIImage, done: @escaping (UIImage) -> Void) {
        original = image
        self.done = done
        let small = Self.shrink(image, to: 2000)
        _base = State(initialValue: small)
        _shown = State(initialValue: small)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { g in
                    let w = g.size.width, h = min(g.size.height, w / shape.ratio), fw = min(w, h * shape.ratio)
                    ZStack {
                        Color.black
                        canvas(width: fw, height: fw / shape.ratio, scaleBy: 1)
                            .overlay { if moving { grid } }
                            .gesture(drag(fw: fw).simultaneously(with: pinch))
                    }
                    .frame(width: w, height: g.size.height)
                    .onAppear { frameWidth = fw }
                    .onChange(of: fw) { _, v in frameWidth = v }
                }
                .animation(.snappy, value: shape)
                Picker("Edit", selection: $tab) { Text("Crop").tag(0); Text("Adjust").tag(1) }.pickerStyle(.segmented).padding(.horizontal)
                if tab == 0 {
                    HStack(spacing: 14) {
                        ForEach(Shape.allCases) { s in
                            Button { withAnimation(.snappy) { shape = s; reset() } } label: {
                                VStack(spacing: 4) { Image(systemName: s.symbol).font(.title3); Text(s.rawValue).font(.caption2.weight(.bold)) }
                                    .frame(width: 58, height: 52)
                                    .background(shape == s ? Theme.accent.opacity(0.25) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        Button { rotate() } label: {
                            VStack(spacing: 4) { Image(systemName: "rotate.right").font(.title3); Text("Rotate").font(.caption2.weight(.bold)) }
                                .frame(width: 58, height: 52).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Pinch to zoom, drag to move it").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        slider("Brightness", value: $brightness, in: -0.3...0.3, neutral: 0)
                        slider("Contrast", value: $contrast, in: 0.7...1.4, neutral: 1)
                        slider("Colour", value: $saturation, in: 0...2, neutral: 1)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 12)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Edit photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { done(render()); dismiss() }.fontWeight(.bold) }
            }
            .onChange(of: brightness) { _, _ in adjust() }
            .onChange(of: contrast) { _, _ in adjust() }
            .onChange(of: saturation) { _, _ in adjust() }
        }
        .preferredColorScheme(.dark)
    }

    /// The picture inside the frame. Drawn at screen size while editing, and again at 1080 px for the result.
    private func canvas(width: CGFloat, height: CGFloat, scaleBy k: CGFloat) -> some View {
        Image(uiImage: shown).resizable().scaledToFill()
            .frame(width: width, height: height)
            .scaleEffect(scale)
            .offset(x: offset.width * k, y: offset.height * k)
            .frame(width: width, height: height)
            .clipped()
    }

    private var grid: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }

    @State private var frameWidth: CGFloat = 1
    private func drag(fw: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { v in
                moving = true
                offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
            }
            .onEnded { _ in moving = false; lastOffset = offset }
    }
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in moving = true; scale = max(1, min(5, lastScale * v.magnification)) }
            .onEnded { _ in moving = false; lastScale = scale }
    }

    private func reset() { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }

    private func rotate() {
        base = Self.rotated(base)
        reset(); adjust()
    }

    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, neutral: Double) -> some View {
        HStack {
            Text(label).font(.subheadline).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Button { value.wrappedValue = neutral } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    private func adjust() {
        guard let input = CIImage(image: base) else { shown = base; return }
        let f = CIFilter.colorControls()
        f.inputImage = input; f.brightness = Float(brightness); f.contrast = Float(contrast); f.saturation = Float(saturation)
        guard let out = f.outputImage, let cg = Self.ci.createCGImage(out, from: input.extent) else { return }
        shown = UIImage(cgImage: cg, scale: base.scale, orientation: .up)
    }

    /// The finished picture: what's inside the frame, 1080 px wide.
    @MainActor
    private func render() -> UIImage {
        let outW: CGFloat = 1080, outH = (outW / shape.ratio).rounded()
        let k = outW / max(1, frameWidth)   // drags were in screen points; the result is 1080 px wide
        let r = ImageRenderer(content: canvas(width: outW, height: outH, scaleBy: k))
        r.scale = 1
        return r.uiImage ?? shown
    }

    static func shrink(_ img: UIImage, to side: CGFloat) -> UIImage {
        let s = min(1, side / max(img.size.width, img.size.height))
        let size = CGSize(width: (img.size.width * s).rounded(), height: (img.size.height * s).rounded())
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    static func rotated(_ img: UIImage) -> UIImage {
        let size = CGSize(width: img.size.height, height: img.size.width)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { c in
            c.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            c.cgContext.rotate(by: .pi / 2)
            img.draw(in: CGRect(x: -img.size.width / 2, y: -img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }
}
