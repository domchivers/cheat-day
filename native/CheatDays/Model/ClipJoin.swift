import AVFoundation
import UIKit

/// One clip in a video made of several (19 Nov; design/multi-clip-editor-mockup.html): the part of its file kept, and
/// its own sound. A photo is a clip too, made into a short silent video first (ClipJoin.still).
struct Clip: Identifiable, Equatable {
    var id = UUID()
    var source: URL
    var length: Double          // the whole file, seconds
    var start: Double           // the part kept, in the file's own seconds
    var end: Double
    var still = false           // made from a photo: no sound of its own
    // its sound
    var soundOn = true
    var volume: Float = 1
    var soundStart: Double?     // only part of its sound kept (the file's own seconds, inside start…end)
    var soundEnd: Double?
    var fadeIn = false
    var fadeOut = false

    var duration: Double { max(0, end - start) }
    var heardStart: Double { max(start, soundStart ?? start) }
    var heardEnd: Double { min(end, soundEnd ?? end) }
}

enum ClipJoin {
    /// The longest a joined post can be (Stories.compress keeps 30 seconds).
    static let longest = 30.0
    static let photoSeconds = 3.0
    private static func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    /// A file picked, as a clip: all of it kept.
    static func clip(_ url: URL, still: Bool = false) async -> Clip? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0.1 else { return nil }
        return Clip(source: url, length: d, start: 0, end: d, still: still, soundOn: !still)
    }

    /// One clip in two at `at` seconds into it (its own kept part), or nil if that's too near an end.
    static func split(_ c: Clip, at: Double) -> (Clip, Clip)? {
        let cut = c.start + at
        guard cut - c.start > 0.3, c.end - cut > 0.3 else { return nil }
        var a = c, b = c
        a.end = cut; a.fadeOut = false
        b.id = UUID(); b.start = cut; b.fadeIn = false
        // the sound kept stays where it was in time, cut with the picture (a half with none of it left is silent)
        a.soundEnd = min(c.soundEnd ?? cut, cut)
        b.soundStart = max(c.soundStart ?? cut, cut)
        return (a, b)
    }

    /// The clips as one: a composition to play straight away (the editor's preview) and to export. Each clip filled
    /// into one frame the shape of the first (a landscape clip among portrait ones is filled, as Instagram does), its
    /// sound at its own level, with its fades; `soundOf`: one clip's sound for the whole of it instead, round again
    /// if it's shorter, and every other clip's sound off.
    static func compose(_ clips: [Clip], soundOf: UUID? = nil) async -> (AVMutableComposition, AVMutableVideoComposition, AVMutableAudioMix)? {
        let comp = AVMutableComposition()
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        // the frame: the first clip's shape, the right way up, at most 1080 across
        var frame = CGSize(width: 1080, height: 1920)
        if let first = clips.first, let v = try? await AVURLAsset(url: first.source).loadTracks(withMediaType: .video).first,
           let n = try? await v.load(.naturalSize), let tf = try? await v.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: n).applying(tf)
            let w = abs(r.width), h = abs(r.height)
            if w > 0, h > 0 { let k = min(1, 1080 / w); frame = CGSize(width: (w * k / 2).rounded() * 2, height: (h * k / 2).rounded() * 2) }
        }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        let levels = AVMutableAudioMixInputParameters(track: at)
        var cursor = 0.0
        let total = clips.reduce(0) { $0 + $1.duration }
        for c in clips where c.duration > 0.05 {
            let asset = AVURLAsset(url: c.source)
            guard let v = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            try? vt.insertTimeRange(CMTimeRange(start: t(c.start), end: t(c.end)), of: v, at: t(cursor))
            // the clip filled into the frame: turned the right way up, scaled to cover it, centred
            let n = (try? await v.load(.naturalSize)) ?? frame, tf = (try? await v.load(.preferredTransform)) ?? .identity
            let up = CGRect(origin: .zero, size: n).applying(tf)
            let k = max(frame.width / max(abs(up.width), 1), frame.height / max(abs(up.height), 1))
            let place = tf.concatenating(CGAffineTransform(translationX: -up.minX, y: -up.minY))
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: (frame.width - abs(up.width) * k) / 2, y: (frame.height - abs(up.height) * k) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
            layer.setTransform(place, at: t(cursor))
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: t(cursor), duration: t(c.duration))
            ins.layerInstructions = [layer]
            instructions.append(ins)
            // its own sound, unless one clip's sound plays over everything
            if soundOf == nil, c.soundOn, !c.still, c.heardEnd - c.heardStart > 0.05,
               let a = try? await asset.loadTracks(withMediaType: .audio).first {
                let from = cursor + (c.heardStart - c.start), span = c.heardEnd - c.heardStart
                try? at.insertTimeRange(CMTimeRange(start: t(c.heardStart), end: t(c.heardEnd)), of: a, at: t(from))
                let fade = min(0.6, span / 3)
                if c.fadeIn { levels.setVolumeRamp(fromStartVolume: 0, toEndVolume: c.volume, timeRange: CMTimeRange(start: t(from), duration: t(fade))) }
                else { levels.setVolume(c.volume, at: t(from)) }
                if c.fadeOut { levels.setVolumeRamp(fromStartVolume: c.volume, toEndVolume: 0, timeRange: CMTimeRange(start: t(from + span - fade), duration: t(fade))) }
            }
            cursor += c.duration
        }
        // one clip's sound for all of it
        if let id = soundOf, let c = clips.first(where: { $0.id == id }), !c.still,
           let a = try? await AVURLAsset(url: c.source).loadTracks(withMediaType: .audio).first {
            let span = c.heardEnd - c.heardStart
            var put = 0.0
            while span > 0.2, put < total - 0.01 {
                let piece = min(span, total - put)
                try? at.insertTimeRange(CMTimeRange(start: t(c.heardStart), duration: t(piece)), of: a, at: t(put))
                put += piece
            }
            levels.setVolume(c.volume, at: .zero)
        }
        // no sound anywhere (all photos, or every clip silent): no sound track at all, as an empty one can stop the export
        let silent = at.segments.isEmpty
        if silent { comp.removeTrack(at) }
        let vc = AVMutableVideoComposition()
        vc.renderSize = frame
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = instructions
        let mix = AVMutableAudioMix()
        mix.inputParameters = silent ? [] : [levels]
        return (comp, vc, mix)
    }

    /// The clips as one video file on the phone, for the editor to take on as it takes a single video.
    static func join(_ clips: [Clip], soundOf: UUID? = nil) async -> URL? {
        guard let (comp, vc, mix) = await compose(clips, soundOf: soundOf),
              let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        export.outputURL = out; export.outputFileType = .mov
        export.videoComposition = vc; export.audioMix = mix
        await export.export()
        return export.status == .completed ? out : nil
    }

    /// A photo as a short silent video (photoSeconds), at most 1080 across, so it can sit among clips.
    static func still(_ image: UIImage) async -> URL? {
        let k = min(1, 1080 / max(image.size.width, 1))
        let size = CGSize(width: (image.size.width * k / 2).rounded() * 2, height: (image.size.height * k / 2).rounded() * 2)
        guard size.width >= 16, size.height >= 16 else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                          AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { writer.cancelWriting(); return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let px = buffer else { writer.cancelWriting(); return nil }
        CVPixelBufferLockBaseAddress(px, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(px), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(px), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            UIGraphicsPushContext(ctx)
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)   // UIKit draws from the top
            image.draw(in: CGRect(origin: .zero, size: size))
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(px, [])
        // the same picture at the start and the end: a still for photoSeconds
        for time in [CMTime.zero, t(photoSeconds - 1.0 / 30)] {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(px, withPresentationTime: time)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: t(photoSeconds))
        await writer.finishWriting()
        return writer.status == .completed ? out : nil
    }

    /// A clip's sound as `count` levels from 0 to 1, for the bars drawn under it.
    static func levels(_ c: Clip, count: Int = 60) async -> [Float] {
        let asset = AVURLAsset(url: c.source)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(start: t(c.start), end: t(c.end))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                                                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1,
                                                                           AVSampleRateKey: 8000])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var samples: [Int16] = []
        while let sb = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: n / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: &chunk)
            samples += chunk
        }
        guard !samples.isEmpty else { return [] }
        let per = max(1, samples.count / count)
        let peaks = stride(from: 0, to: samples.count, by: per).map { i -> Float in
            let slice = samples[i..<min(samples.count, i + per)]
            return Float(slice.map { abs(Int($0)) }.max() ?? 0) / Float(Int16.max)
        }
        let top = max(peaks.max() ?? 1, 0.01)
        return peaks.map { $0 / top }
    }
}
