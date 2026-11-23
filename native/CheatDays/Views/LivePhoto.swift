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
/// Here the picture is its own small view, and since 23 Nov it's drawn on the graphics chip as the clip editor's is
/// (LookSurface): a step is one drawing at the screen's next refresh.
struct LivePhoto: UIViewRepresentable {
    let base: UIImage
    let box: PhotoLook

    func makeCoordinator() -> Link { Link() }

    func makeUIView(context: Context) -> LookSurface { LookSurface(still: true) }

    func updateUIView(_ v: LookSurface, context: Context) {
        v.take(base)
        let link: Link = context.coordinator
        if link.box !== box {
            link.box = box
            box.changed = { [weak v] (look: String) in
                v?.filter = LiveLook.through(look)
                v?.redraw()
            }
        }
        v.filter = LiveLook.through(box.look)
        v.redraw()
    }

    final class Link {
        weak var box: PhotoLook?
    }
}
