import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import SwiftUI

/// A picture drawn through a look on the graphics chip, as the clip editor's preview is (23 Nov: "the way this editor
/// works with filters… is super smooth. How can we get the same thing with stories and posts?"). A change asks for
/// one drawing at the screen's next refresh: nothing's made on the main thread, nor copied back off the chip.
/// What's saved is made as before, by the same look, so it's what was on the screen.
final class LookSurface: MTKView, MTKViewDelegate {
    private static let gpu: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let ci: CIContext? = gpu.map { (d: MTLDevice) -> CIContext in CIContext(mtlDevice: d, options: [.cacheIntermediates: false]) }
    private lazy var queue: MTLCommandQueue? = device?.makeCommandQueue()
    private let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// A photo: made the drawable's size once, so a step of a slider is only the look's work. (A clip's frames change.)
    private let still: Bool
    private var sized: (size: CGSize, image: CIImage)?
    private var from: ObjectIdentifier?

    /// The picture, the right way up.
    var source: CIImage? { didSet { sized = nil } }
    /// A clip's newest frame, asked for at each refresh; nil when there isn't a new one.
    var pull: (() -> CIImage?)?
    /// What it's drawn through, given the picture at the drawable's size with its corner at the origin.
    var filter: (CIImage) -> CIImage = { (i: CIImage) -> CIImage in i }
    /// Filling the view and cropped, as a clip's is; or stretched to it (a photo whose view already has its shape).
    var fills = false

    init(still: Bool) {
        self.still = still
        super.init(frame: .zero, device: Self.gpu)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isOpaque = false
        backgroundColor = .clear
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        autoResizeDrawable = true
        isUserInteractionEnabled = false
        delegate = self
        runs(false)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Drawing at every refresh (a clip's), or only when asked (a photo's).
    func runs(_ on: Bool) {
        isPaused = !on
        enableSetNeedsDisplay = !on
        if on { preferredFramesPerSecond = 60 }
    }

    /// Drawn again at the next refresh.
    func redraw() { setNeedsDisplay() }

    /// A photo to draw: a new one only when it is one.
    func take(_ image: UIImage) {
        guard from != ObjectIdentifier(image) else { return }
        from = ObjectIdentifier(image)
        source = Self.upright(image).map { (cg: CGImage) -> CIImage in CIImage(cgImage: cg) }
    }

    /// The picture the right way up as plain pixels (a photo can carry a note saying it's on its side).
    static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let f = UIGraphicsImageRendererFormat()
        f.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        sized = nil
        redraw()
    }

    func draw(in view: MTKView) {
        if let pull, let fresh = pull() { source = fresh }
        let size: CGSize = drawableSize
        guard let src = source, size.width > 0, size.height > 0, let ctx = Self.ci, let queue,
              let drawable = currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
        let frame = CGRect(origin: .zero, size: size)
        let out: CIImage = filter(fitted(src, to: size, ctx: ctx)).cropped(to: frame)
        let tex: MTLTexture = drawable.texture
        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height), pixelFormat: colorPixelFormat,
                                       commandBuffer: buffer, mtlTextureProvider: { () -> MTLTexture in tex })
        dest.colorSpace = space
        _ = try? ctx.startTask(toRender: out, from: frame, to: dest, at: .zero)
        buffer.present(drawable)
        buffer.commit()
    }

    private func fitted(_ src: CIImage, to size: CGSize, ctx: CIContext) -> CIImage {
        if let s = sized, s.size == size { return s.image }
        let e: CGRect = src.extent
        var sx: CGFloat = size.width / max(e.width, 1), sy: CGFloat = size.height / max(e.height, 1)
        if fills { let k: CGFloat = max(sx, sy); sx = k; sy = k }
        let dx: CGFloat = fills ? (size.width - e.width * sx) / 2 : 0
        let dy: CGFloat = fills ? (size.height - e.height * sy) / 2 : 0
        let move = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
        let frame = CGRect(origin: .zero, size: size)
        var img: CIImage = src.transformed(by: move).cropped(to: frame)
        if still {
            // (the full photo made small once: drawn from it each step, it was sent to the chip every time)
            if let cg = ctx.createCGImage(img, from: frame) { img = CIImage(cgImage: cg) }
            sized = (size, img)
        }
        return img
    }
}

/// A story's look on its own picture, kept to the picture's frame (as the old one was drawn).
enum LiveLook {
    static func through(_ look: String) -> (CIImage) -> CIImage {
        { (img: CIImage) -> CIImage in
            guard look != "Normal" else { return img }
            let whole: CGRect = img.extent
            return StoryArt.filtered(img.clampedToExtent(), look, frame: whole).cropped(to: whole)
        }
    }
}

/// A post's photo with its brightness, contrast and colour, drawn as the sliders move.
struct LiveAdjust: UIViewRepresentable {
    let base: UIImage
    let brightness: Double
    let contrast: Double
    let saturation: Double

    func makeUIView(context: Context) -> LookSurface {
        let v = LookSurface(still: true)
        v.fills = true
        return v
    }

    func updateUIView(_ v: LookSurface, context: Context) {
        v.take(base)
        let b = Float(brightness), c = Float(contrast), s = Float(saturation)
        v.filter = { (img: CIImage) -> CIImage in
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.brightness = b
            f.contrast = c
            f.saturation = s
            return f.outputImage ?? img
        }
        v.redraw()
    }
}
