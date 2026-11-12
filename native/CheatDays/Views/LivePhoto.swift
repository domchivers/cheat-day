import SwiftUI
import CoreImage

/// The look a photo's being given while an Adjust slider moves. The slider writes here and nowhere else: the picture
/// on screen listens and draws itself, and the editor isn't told until the finger lifts.
final class PhotoLook {
    var changed: ((String) -> Void)?
    var look = "Normal" { didSet { if look != oldValue { changed?(look) } } }
}

/// A photo drawn through whatever look the box holds, as the box changes.
///
/// Every step of a slider used to go the long way round: the editor's whole screen was worked out again (it's a big
/// one), a new background job was started and the one before it called off, a new picture was made and handed back,
/// and the screen was worked out a second time to show it. The finger was always ahead of the picture.
/// Here the picture is its own small view. A step asks for one drawing on a queue of its own; while that's being
/// made, later steps just replace the one that's waiting, so it always goes straight to the newest and never falls
/// behind. The finished picture is put on the view's layer directly.
struct LivePhoto: UIViewRepresentable {
    let base: UIImage
    let box: PhotoLook

    func makeUIView(context: Context) -> Surface {
        let v = Surface()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.layer.contentsGravity = .resize
        return v
    }
    func updateUIView(_ v: Surface, context: Context) { v.take(base, box) }

    final class Surface: UIView {
        private var source: CIImage?
        private var from: ObjectIdentifier?
        private weak var box: PhotoLook?
        private let queue = DispatchQueue(label: "photo.look", qos: .userInteractive)
        private var busy = false
        private var waiting: String?
        private var shown: String?

        func take(_ image: UIImage, _ box: PhotoLook) {
            if from != ObjectIdentifier(image) {
                from = ObjectIdentifier(image)
                source = Self.upright(image).map { CIImage(cgImage: $0) }
                shown = nil
            }
            if self.box !== box {
                self.box = box
                box.changed = { [weak self] look in self?.draw(look) }
            }
            draw(box.look)
        }

        /// The picture the right way up as plain pixels (a photo can carry a note saying it's on its side).
        private static func upright(_ image: UIImage) -> CGImage? {
            if image.imageOrientation == .up, let cg = image.cgImage { return cg }
            let f = UIGraphicsImageRendererFormat(); f.scale = image.scale
            return UIGraphicsImageRenderer(size: image.size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
        }

        private func draw(_ look: String) {
            guard let source, look != shown else { return }
            if busy { waiting = look; return }
            busy = true
            queue.async { [weak self] in
                let out = look == "Normal" ? source : StoryArt.filtered(source, look)
                let cg = StoryArt.context.createCGImage(out, from: source.extent)
                DispatchQueue.main.async {
                    guard let self else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.layer.contents = cg
                    CATransaction.commit()
                    self.shown = look
                    self.busy = false
                    if let next = self.waiting { self.waiting = nil; self.draw(next) }
                }
            }
        }
    }
}
