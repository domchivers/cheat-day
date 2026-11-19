import AVFoundation
import UIKit
import XCTest
@testable import CheatDays

/// 20 Nov: a clip went black in the editor after its sound was changed. The picture only changes when the preview is
/// made again, so: real videos with sound, the edit made the way the editor makes it after each sound tool, and every
/// clip's frames looked at. A frame with no clip in it comes out black.
final class EditFramesTests: XCTestCase {
    private var made: [URL] = []
    override func tearDown() { for u in made { try? FileManager.default.removeItem(at: u) }; made = [] }

    /// A test video that couldn't be written: the case fails with why, instead of the run hanging.
    private struct Stuck: Error, CustomStringConvertible { let what: String; var description: String { what } }

    /// Waits for the writer to take more, at most 20 s; a failed writer stops it at once.
    private func ready(_ input: AVAssetWriterInput, _ writer: AVAssetWriter, _ what: String) async throws {
        let began = Date()
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw Stuck(what: "the writer failed at \(what): \(String(describing: writer.error))") }
            if Date().timeIntervalSince(began) > 20 {
                throw Stuck(what: "the writer stuck at \(what): status \(writer.status.rawValue) \(String(describing: writer.error))")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// A video of one colour with a tone under it, `seconds` long.
    private func video(_ colour: (UInt8, UInt8, UInt8), seconds: Double, size: CGSize = CGSize(width: 540, height: 960)) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("frames-" + UUID().uuidString + ".mov")
        made.append(out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                      AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
        let rate = 44_100.0
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                                      AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
                                                                      AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
        v.expectsMediaDataInRealTime = false; a.expectsMediaDataInRealTime = false
        writer.add(v); writer.add(a)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // the sound: a 440 Hz tone, a tenth of a second a buffer
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        let chunk = 4410, sound = Int(seconds * rate)
        var at = 0
        // The sound goes in alongside the picture, never all after it. (21 Nov: written picture first, a 4K clip's
        // frames got so far ahead of its still-empty sound track that the writer stopped taking frames, and waited
        // for ever.)
        func addSound(until end: Int) async throws {
          while at < min(end, sound) {
            var samples = (0..<chunk).map { Float(sin(2 * Double.pi * 440 * Double(at + $0) / rate) * 0.3) }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 4, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: chunk * 4, flags: 0, blockBufferOut: &block)
            guard let block else { break }
            CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: chunk * 4)
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format!,
                                                                 sampleCount: chunk, presentationTimeStamp: CMTime(value: CMTimeValue(at), timescale: CMTimeScale(rate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
            guard let sb else { break }
            try await ready(a, writer, "sound at sample \(at)")
            a.append(sb)
            at += chunk
          }
        }
        // the picture: thirty frames a second of the one colour (one row made, copied down the frame)
        let frames = Int(seconds * 30)
        var line = [UInt8](repeating: 255, count: Int(size.width) * 4)
        for x in 0..<Int(size.width) { line[x * 4] = colour.2; line[x * 4 + 1] = colour.1; line[x * 4 + 2] = colour.0 }
        for f in 0..<frames {
            // sound up to a tenth of a second past this frame first
            try await addSound(until: Int(Double(f + 3) / 30 * rate))
            guard let pool = adaptor.pixelBufferPool else { throw Stuck(what: "no pixel buffer pool: \(writer.status.rawValue) \(String(describing: writer.error))") }
            var px: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &px)
            guard let px else { throw Stuck(what: "no pixel buffer at frame \(f)") }
            CVPixelBufferLockBaseAddress(px, [])
            let base = CVPixelBufferGetBaseAddress(px)!, row = CVPixelBufferGetBytesPerRow(px)
            line.withUnsafeBytes { src in
                for y in 0..<Int(size.height) { memcpy(base + y * row, src.baseAddress!, src.count) }
            }
            CVPixelBufferUnlockBaseAddress(px, [])
            try await ready(v, writer, "frame \(f) of \(Int(size.width))x\(Int(size.height))")
            adaptor.append(px, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        v.markAsFinished()
        try await addSound(until: sound)
        a.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return out
    }

    /// The colour of the middle of the frame at `t`, as the editor's preview would draw it.
    private func colour(_ comp: AVComposition, _ vc: AVVideoComposition, at t: Double) async throws -> (Double, Double, Double) {
        let gen = AVAssetImageGenerator(asset: comp)
        gen.videoComposition = vc
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 120, height: 120)
        let img = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        let w = 8, h = 8
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(w * h) { r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2]) }
        let n = Double(w * h)
        return (r / n, g / n, b / n)
    }

    /// Every half second of the edit: red while the first clip shows, blue while the second does, never black.
    private func check(_ clips: [Clip], soundOf: UUID? = nil, swap: [URL: URL] = [:], _ label: String) async throws {
        guard let (comp, vc, _) = await ClipJoin.compose(clips, soundOf: soundOf, swap: swap) else { return XCTFail("\(label): nothing made") }
        let starts = ClipJoin.starts(clips), total = ClipJoin.total(clips)
        let join = ClipJoin.overlap(clips, after: 0)
        var t = 0.25
        while t < total - 0.2 {
            let (r, g, b) = try await colour(comp, vc, at: t)
            XCTAssertGreaterThan(max(r, g, b), 60, "\(label): black at \(t) s")
            // (while one turns into the other it's a mix of both: only not black)
            let turning = clips.count > 1 && t > starts[1] - 0.05 && t < starts[1] + join + 0.05
            let second = clips.count > 1 && t >= starts[1] + 0.05
            if turning {
            } else if second { XCTAssertGreaterThan(b, r, "\(label): at \(t) s it should be the blue clip") }
            else { XCTAssertGreaterThan(r, b, "\(label): at \(t) s it should be the red clip") }
            t += 0.5
        }
    }

    private func pair() async throws -> [Clip] {
        let red = try await video((230, 40, 40), seconds: 3), blue = try await video((40, 60, 230), seconds: 3)
        let ca = await ClipJoin.clip(red), cb = await ClipJoin.clip(blue)
        return [try XCTUnwrap(ca), try XCTUnwrap(cb)]
    }

    func testFramesThroughEverySoundTool() async throws {
        let clips = try await pair()
        try await check(clips, "as picked")
        var c = clips
        c[0].soundOn = false
        try await check(c, "first clip muted")
        c = clips; c[0].volume = 0.2
        try await check(c, "volume down")
        c = clips; c[0].keys = [VolumeKey(at: 0.5, volume: 1), VolumeKey(at: 2, volume: 0.1)]
        try await check(c, "volume keyframes")
        c = clips; c[0].fadeIn = 1; c[0].fadeOut = 1; c[1].fadeIn = 0.5
        try await check(c, "fades")
        try await check(clips, soundOf: clips[0].id, "first clip's sound for all")
        c = clips; c[0].soundStart = 1; c[0].soundEnd = 2
        try await check(c, "part of its sound kept")
        c = clips; c[0].soundOn = false; c[1].soundOn = false
        try await check(c, "every clip muted")
    }

    func testFramesWithClearerSound() async throws {
        var clips = try await pair()
        let made0 = await Clarity.clearer(clips[0])
        let clean = try XCTUnwrap(made0, "the clearer sound wasn't made")
        made.append(clean)
        clips[0].clean = clean
        try await check(clips, "clearer sound")
    }

    func testFramesWithSpeedTrimAndTransition() async throws {
        var clips = try await pair()
        clips[0].end = 2.2; clips[0].speed = 1.5
        clips[0].transition = ClipTransition(kind: "Crossfade", length: 0.4)
        clips[1].start = 0.5
        try await check(clips, "speed, trim and a crossfade")
    }

    /// A 4K clip plays from a smaller copy in the editor: that copy shows the clip too.
    func testFramesFromABigClipsSmallerCopy() async throws {
        let big = try await video((230, 40, 40), seconds: 2, size: CGSize(width: 3840, height: 2160))
        let blue = try await video((40, 60, 230), seconds: 2)
        let ca = await ClipJoin.clip(big), cb = await ClipJoin.clip(blue), cp = await ClipJoin.proxy(big)
        let a = try XCTUnwrap(ca), b = try XCTUnwrap(cb)
        let copy = try XCTUnwrap(cp, "no smaller copy made of a 4K clip")
        made.append(copy)
        try await check([a, b], swap: [big: copy], "a 4K clip from its smaller copy")
        var muted = [a, b]; muted[0].soundOn = false
        try await check(muted, swap: [big: copy], "a 4K clip from its smaller copy, muted")
    }
}
