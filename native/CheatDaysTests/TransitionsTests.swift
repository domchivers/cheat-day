import XCTest
import CoreImage
@testable import CheatDays

/// The transitions (21 Nov, design/transitions-mockup.html): each starts on the old clip and ends on the new one,
/// fills the frame the whole way, and edits saved with the old names still play.
final class TransitionsTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 72, height: 128)
    private let context = CIContext()

    private func middle(_ img: CIImage) -> (r: Int, g: Int, b: Int, a: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        context.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: frame.midX, y: frame.midY, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    func testEveryKindGoesFromTheOldClipToTheNew() {
        let red = CIImage(color: .red).cropped(to: frame), blue = CIImage(color: .blue).cropped(to: frame)
        for kind in ClipTransition.kinds {
            for dir in ClipTransition.directions {
                let first = middle(EditCompositor.blend(red, blue, kind: kind, direction: dir, p: 0, frame: frame))
                XCTAssert(first.r > 240 && first.b < 15, "\(kind) \(dir) starts on the old clip: \(first)")
                let last = middle(EditCompositor.blend(red, blue, kind: kind, direction: dir, p: 1, frame: frame))
                XCTAssert(last.b > 240 && last.r < 15, "\(kind) \(dir) ends on the new clip: \(last)")
                for p in stride(from: 0.1, through: 0.9, by: 0.2) {
                    let img = EditCompositor.blend(red, blue, kind: kind, direction: dir, p: CGFloat(p), frame: frame)
                    XCTAssertEqual(img.extent, frame, "\(kind) \(dir) at \(p) fills the frame, no more")
                    XCTAssertEqual(middle(img).a, 255, "\(kind) \(dir) at \(p): nothing see-through")
                }
            }
        }
    }

    func testOldNamesStillPlay() throws {
        XCTAssertEqual(ClipTransition.named("Crossfade"), "Dissolve")
        XCTAssertEqual(ClipTransition.named("Fade to black"), "Black")
        XCTAssertEqual(ClipTransition.named("Slide"), "Push")
        XCTAssertEqual(ClipTransition.named("Zoom"), "Zoom in")
        XCTAssertEqual(ClipTransition.named("Whip"), "Whip")
        // saved before there was a direction
        let old = try JSONDecoder().decode(ClipTransition.self, from: Data(#"{"kind":"Slide","length":0.4}"#.utf8))
        XCTAssertEqual(old.name, "Push"); XCTAssertNil(old.direction); XCTAssertEqual(old.length, 0.4)
        var t = ClipTransition(kind: "Whip", length: 0.3); t.direction = "up"
        XCTAssertEqual(try JSONDecoder().decode(ClipTransition.self, from: JSONEncoder().encode(t)), t)
        for k in ClipTransition.moving { XCTAssert(ClipTransition.kinds.contains(k)) }
    }
}
