import CoreImage
import MetalKit
import SwiftUI

/// The clip editor's picture, drawn by the app itself on every frame the screen draws (21 Nov; the owner: "build it
/// properly like CapCut"): each frame asked of the editor's own player (PreviewEngine) and drawn through Metal, as
/// Apple's sample for video through Core Image does (WWDC20, "Optimize the Core Image pipeline for your video app").
/// When there's nothing new (held still, or a clip's frames not read yet) nothing's drawn, and the last frame stays up:
/// never a blank, never a flash. (Apple's player view went black a moment each time the edit was made again.)
struct EditPreviewView: UIViewRepresentable {
    let engine: PreviewEngine

    func makeCoordinator() -> Drawer { Drawer(engine: engine) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.framebufferOnly = false          // (Core Image draws into it)
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.backgroundColor = .black
        v.isOpaque = true
        v.preferredFramesPerSecond = 120   // (as fast as the screen goes: 60 on one that can't)
        v.autoResizeDrawable = true
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {}

    final class Drawer: NSObject, MTKViewDelegate {
        let engine: PreviewEngine
        let device = MTLCreateSystemDefaultDevice()
        private lazy var queue = device?.makeCommandQueue()
        private lazy var context: CIContext? = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        private let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        private var last: CIImage?
        private var drawnSize = CGSize.zero

        init(engine: PreviewEngine) { self.engine = engine }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { drawnSize = .zero }

        func draw(in view: MTKView) {
            let size = view.drawableSize
            // the moment this frame will be on the screen
            let host = CACurrentMediaTime() + 1 / Double(max(view.preferredFramesPerSecond, 30))
            let fresh = engine.picture(host: host)
            if fresh != nil { last = fresh }
            let pick = fresh ?? (size != drawnSize ? last : nil)   // (a new size: the last again)
            guard let image = pick, size.width > 0, size.height > 0, let context, let queue,
                  let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
            // the frame whole in the view, on black
            let e = image.extent
            let k = min(size.width / max(e.width, 1), size.height / max(e.height, 1))
            let w = e.width * k, h = e.height * k
            let placed = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: k, y: k)))
                .transformed(by: CGAffineTransform(translationX: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded()))
            let frame = CGRect(origin: .zero, size: size)
            let shown = placed.composited(over: CIImage(color: .black).cropped(to: frame))
            let tex = drawable.texture
            let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height), pixelFormat: view.colorPixelFormat,
                                           commandBuffer: buffer, mtlTextureProvider: { tex })
            dest.colorSpace = space
            _ = try? context.startTask(toRender: shown, from: frame, to: dest, at: .zero)
            buffer.present(drawable)
            buffer.commit()
            drawnSize = size
        }
    }
}
