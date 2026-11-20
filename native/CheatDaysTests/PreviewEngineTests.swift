import AVFoundation
import CoreImage
import XCTest
import UIKit
@testable import CheatDays

/// The clip editor's own player (21 Nov): it shows the right clip at each moment, from the clips themselves, and an
/// edit shows without anything being made again; its sound plan has each clip's sound where the finished video has it.
/// (Each test on the main thread, as the editor calls the engine.)
final class PreviewEngineTests: XCTestCase {
    private var made: [URL] = []
    override func tearDown() { for u in made { try? FileManager.default.removeItem(at: u) }; made = [] }

    /// A video of one colour, `seconds` long (picture only).
    private func video(_ colour: (UInt8, UInt8, UInt8), seconds: Double) async throws -> URL {
        let size = CGSize(width: 360, height: 640)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("engine-" + UUID().uuidString + ".mov")
        made.append(out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                      AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        v.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
        writer.add(v)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var line = [UInt8](repeating: 255, count: Int(size.width) * 4)
        for x in 0..<Int(size.width) { line[x * 4] = colour.2; line[x * 4 + 1] = colour.1; line[x * 4 + 2] = colour.0 }
        for f in 0..<Int(seconds * 30) {
            let began = Date()
            while !v.isReadyForMoreMediaData {
                if writer.status == .failed || Date().timeIntervalSince(began) > 20 {
                    throw NSError(domain: "the writer stuck at frame \(f): \(String(describing: writer.error))", code: 1)
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var px: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &px)
            guard let px else { break }
            CVPixelBufferLockBaseAddress(px, [])
            let base = CVPixelBufferGetBaseAddress(px)!, row = CVPixelBufferGetBytesPerRow(px)
            line.withUnsafeBytes { src in for y in 0..<Int(size.height) { memcpy(base + y * row, src.baseAddress!, src.count) } }
            CVPixelBufferUnlockBaseAddress(px, [])
            adaptor.append(px, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        v.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return out
    }

    private func pair() async throws -> [Clip] {
        let red = try await video((230, 40, 40), seconds: 2), blue = try await video((40, 60, 230), seconds: 2)
        let a = await ClipJoin.clip(red), b = await ClipJoin.clip(blue)
        return [try XCTUnwrap(a), try XCTUnwrap(b)]
    }

    /// The engine's picture at `t`, held still, as soon as its frames are read (at most 5 s), as average colour.
    @MainActor private func colour(_ e: PreviewEngine, at t: Double, _ label: String) async throws -> (Double, Double, Double) {
        e.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        let began = Date()
        var img: CIImage?
        while img == nil {
            img = e.picture(host: CACurrentMediaTime())
            if img != nil { break }
            if Date().timeIntervalSince(began) > 5 { XCTFail("\(label): no picture at \(t) s in 5 s"); return (0, 0, 0) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let ctx = CIContext()
        let small = img!.transformed(by: CGAffineTransform(scaleX: 8 / img!.extent.width, y: 8 / img!.extent.height))
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        ctx.render(small, toBitmap: &px, rowBytes: 32, bounds: CGRect(x: 0, y: 0, width: 8, height: 8), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<64 { r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2]) }
        return (r / 64, g / 64, b / 64)
    }

    @MainActor func testShowsEachClipFromTheClipsThemselves() async throws {
        let clips = try await pair()
        let e = PreviewEngine()
        e.update(clips: clips, soundOf: nil, look: EditLook(), sounds: [], pips: [], swap: [:])
        XCTAssertEqual(e.total, ClipJoin.total(clips), accuracy: 0.01)
        let first = try await colour(e, at: 0.5, "first clip")
        XCTAssertGreaterThan(first.0, first.2, "at 0.5 s it should be the red clip: \(first)")
        let second = try await colour(e, at: 2.6, "second clip")
        XCTAssertGreaterThan(second.2, second.0, "at 2.6 s it should be the blue clip: \(second)")
        // back again (a jump back starts its reader again)
        let again = try await colour(e, at: 0.2, "first clip again")
        XCTAssertGreaterThan(again.0, again.2, "back at 0.2 s it should be red again: \(again)")
        e.shutdown()
    }

    /// A photo (two frames, its start and its end) shows in its middle too (21 Nov: a photo overlay never showed).
    @MainActor func testAPhotoShowsInItsMiddle() async throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640)).image { c in
            UIColor(red: 0.1, green: 0.85, blue: 0.2, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
        }
        let still = await ClipJoin.still(img, seconds: 4)
        let url = try XCTUnwrap(still); made.append(url)
        let clip = await ClipJoin.clip(url, still: true)
        let photo = try XCTUnwrap(clip)
        let e = PreviewEngine()
        e.update(clips: [photo], soundOf: nil, look: EditLook(), sounds: [], pips: [], swap: [:])
        let mid = try await colour(e, at: 2, "the photo's middle")
        XCTAssertGreaterThan(mid.1, mid.0 + 60, "at 2 s it should be the green photo: \(mid)")
        e.shutdown()
    }

    /// The clips swapped round: shown at once, with nothing made.
    @MainActor func testAnEditShowsWithNothingMade() async throws {
        let clips = try await pair()
        let e = PreviewEngine()
        e.update(clips: clips, soundOf: nil, look: EditLook(), sounds: [], pips: [], swap: [:])
        _ = try await colour(e, at: 0.5, "before")
        e.update(clips: [clips[1], clips[0]], soundOf: nil, look: EditLook(), sounds: [], pips: [], swap: [:])
        let swapped = try await colour(e, at: 0.5, "swapped")
        XCTAssertGreaterThan(swapped.2, swapped.0, "swapped round, 0.5 s should be the blue clip: \(swapped)")
        e.shutdown()
    }

    /// Which clips show when: one, then both while a crossfade turns one into the next.
    @MainActor func testTwoClipsWhileOneTurnsIntoTheNext() async throws {
        var clips = try await pair()
        clips[0].transition = ClipTransition(kind: "Crossfade", length: 0.5)
        let e = PreviewEngine()
        e.update(clips: clips, soundOf: nil, look: EditLook(), sounds: [], pips: [], swap: [:])
        let starts = ClipJoin.starts(clips)
        XCTAssertEqual(e.clipsAt(0.3).map { $0.0 }, [0])
        XCTAssertEqual(e.clipsAt(starts[1] + 0.1).map { $0.0 }, [0, 1])
        XCTAssertEqual(e.clipsAt(starts[1] + ClipJoin.overlap(clips, after: 0) + 0.1).map { $0.0 }, [1])
        e.shutdown()
    }

    /// The sound plan: each clip's own where it plays, a muted one at nothing, a separated one as its own piece.
    @MainActor func testSoundPiecesWhereTheVideoHasThem() async throws {
        var clips = try await pair()
        clips[1].soundOn = false
        var s = EditSound(kind: "clip", name: "Clip 1 sound", file: clips[0].source, from: 0.5, start: 0.5, length: 1, volume: 0.5, full: 2)
        s.clip = clips[0].id
        let e = PreviewEngine()
        e.update(clips: clips, soundOf: nil, look: EditLook(), sounds: [s], pips: [], swap: [:])
        let p = e.soundPieces()
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p[0].from, 0, accuracy: 0.01)
        XCTAssertEqual(p[1].from, ClipJoin.starts(clips)[1], accuracy: 0.01)
        XCTAssertEqual(p[1].level(p[1].from + 0.5), 0, "a muted clip's sound at nothing")
        XCTAssertEqual(p[2].from, 0.5, accuracy: 0.01)
        XCTAssertEqual(p[2].level(1), 0.5, accuracy: 0.001)
        e.shutdown()
    }
}
