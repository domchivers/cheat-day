import XCTest
import SwiftUI
@testable import CheatDays

/// The posted picture behind a story is the editor's own view of it drawn bigger (StoryBackdrop), so it lands exactly
/// where the editor showed it. A polaroid came out lower and about 12% smaller than placed when posting drew it again by
/// hand, and stickers put on its strip ended up on the photo.
final class StoryBackdropTests: XCTestCase {
    private func solid(_ c: UIColor, _ w: CGFloat, _ h: CGFloat) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image { ctx in c.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
    }

    /// The colour at a pixel, 0...1 each.
    private func pixel(_ img: UIImage, _ x: CGFloat, _ y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var px = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        ctx.translateBy(x: 0, y: 1); ctx.scaleBy(x: 1, y: -1)   // UIKit's way up, so y counts down from the top
        img.draw(at: CGPoint(x: -x, y: -y))
        UIGraphicsPopContext()
        return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
    }
    private func isPhoto(_ p: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool { p.r > 0.9 && p.g < 0.15 && p.b < 0.15 }
    private func isCard(_ p: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool { p.r > 0.85 && p.g > 0.85 && p.b > 0.8 }

    @MainActor
    func testPolaroidPostsWhereTheEditorPutsIt() throws {
        let cw: CGFloat = 390, ch = cw * 16 / 9, scale: CGFloat = 0.7
        let photo = solid(.red, 900, 1600)   // the story's own shape, so it just fills the frame at full size
        let out = try XCTUnwrap(StoryBackdrop.picture(photo: photo, cw: cw, ch: ch, scale: scale, offset: .zero, spin: 0, tilt: 0, style: 3))
        XCTAssertEqual(out.size.width, 1080); XCTAssertEqual(out.size.height, 1920)

        // what the editor shows, in posted pixels: the whole card centred, the photo inside it near the top
        let k = 1080 / cw
        let w = cw * scale * k, h = ch * scale * k, pad = w * 0.05, strip = w * 0.22
        let cardTop = 960 - (h + pad + strip) / 2, top = cardTop + pad, bottom = top + h
        let left = 540 - w / 2, right = 540 + w / 2

        XCTAssertTrue(isPhoto(pixel(out, 540, top + 10)), "photo starts where the editor has it")
        XCTAssertTrue(isCard(pixel(out, 540, top - 10)), "the card's top border is above it")
        XCTAssertTrue(isPhoto(pixel(out, 540, bottom - 10)), "photo ends where the editor has it")
        XCTAssertTrue(isCard(pixel(out, 540, bottom + strip / 2)), "the deep strip is under it, where a sticker was put")
        XCTAssertTrue(isPhoto(pixel(out, left + 10, 960)) && isPhoto(pixel(out, right - 10, 960)), "photo is the size it was shown")
        XCTAssertTrue(isCard(pixel(out, left - pad / 2, 960)) && isCard(pixel(out, right + pad / 2, 960)), "side borders")
        XCTAssertFalse(isPhoto(pixel(out, 20, 20)) || isCard(pixel(out, 20, 20)), "outside the card is the blurred, dimmed photo")
    }

    @MainActor
    func testAPhotoFillingTheFrameFillsThePicture() throws {
        let cw: CGFloat = 390, ch = cw * 16 / 9
        let out = try XCTUnwrap(StoryBackdrop.picture(photo: solid(.red, 900, 1600), cw: cw, ch: ch, scale: 1, offset: .zero, spin: 0, tilt: 0, style: 0))
        for (x, y) in [(5.0, 5.0), (1075.0, 5.0), (540.0, 960.0), (5.0, 1915.0), (1075.0, 1915.0)] {
            XCTAssertTrue(isPhoto(pixel(out, x, y)), "(\(x), \(y))")
        }
    }

    /// Drawn at the phone's size (as the editor shows it) and at the posted size, the same things are in the same
    /// places, as fractions of the frame: moved, made smaller, in each look.
    @MainActor
    func testSameAtEverySize() throws {
        let photo = solid(.red, 1200, 900)   // wider than the frame
        for style in 0..<StoryEditor.bgStyles.count {
            let small = try XCTUnwrap(StoryBackdrop.picture(photo: photo, cw: 300, ch: 300 * 16 / 9, scale: 0.6, offset: CGSize(width: 20, height: -40), spin: 0, tilt: 0, style: style))
            let big = try XCTUnwrap(StoryBackdrop.picture(photo: photo, cw: 430, ch: 430 * 16 / 9, scale: 0.6, offset: CGSize(width: 20 * 430 / 300, height: -40 * 430 / 300), spin: 0, tilt: 0, style: style))
            var differ = 0
            for fx in stride(from: 0.05, through: 0.95, by: 0.075) {
                for fy in stride(from: 0.05, through: 0.95, by: 0.05) {
                    let a = pixel(small, fx * 1080, fy * 1920), b = pixel(big, fx * 1080, fy * 1920)
                    if isPhoto(a) != isPhoto(b) || isCard(a) != isCard(b) { differ += 1 }
                }
            }
            XCTAssertLessThanOrEqual(differ, 2, "look \(StoryEditor.bgStyles[style]): \(differ) points differ")   // an edge can fall either side
        }
    }
}
