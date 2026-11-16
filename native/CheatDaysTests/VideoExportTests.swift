import XCTest
import AVFoundation
@testable import CheatDays

/// Videos go up at 1080 × 1920 like photos (they were 720 × 1280), and stay small enough to upload: well under the
/// storage's 50 MB a file at the longest, 30 seconds.
final class VideoExportTests: XCTestCase {
    /// A tall 1080 × 1920 clip with moving detail (so the encoder has real work), `seconds` long, at 30 a second.
    private func clip(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1080, AVVideoHeightKey: 1920])
        let pool = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1080, kCVPixelBufferHeightKey as String: 1920])
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        for f in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool.pixelBufferPool!, &buf)
            let b = buf!
            CVPixelBufferLockBaseAddress(b, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: 1080, height: 1920, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(UIColor(hue: CGFloat(f % 90) / 90, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 1080, height: 1920))
            ctx.setFillColor(UIColor.white.cgColor)
            for i in 0..<40 { ctx.fill(CGRect(x: CGFloat((i * 53 + f * 7) % 1080), y: CGFloat(i * 48), width: 24, height: 24)) }
            CVPixelBufferUnlockBaseAddress(b, [])
            pool.append(b, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        await w.finishWriting()
        return url
    }

    func testVideosPostAtFullHDAndStaySmall() async throws {
        let src = try await clip(seconds: 10)
        defer { try? FileManager.default.removeItem(at: src) }
        let (data, seconds) = try await Stories.compress(src)
        XCTAssertEqual(seconds, 10, accuracy: 0.1)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: out); defer { try? FileManager.default.removeItem(at: out) }
        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        XCTAssertEqual(size.width, 1080); XCTAssertEqual(size.height, 1920)
        let mb = Double(data.count) / 1_000_000
        print("VIDEO EXPORT: \(Int(size.width))x\(Int(size.height)), \(String(format: "%.1f", mb)) MB for 10 s (≈\(String(format: "%.0f", mb * 3)) MB for 30 s)")
        XCTAssertLessThan(mb * 3, 40, "30 seconds would be \(mb * 3) MB")
    }
}
