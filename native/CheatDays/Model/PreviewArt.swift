import AVFoundation
import CoreImage
import UIKit

/// Small pictures for the panels' previews, made with what draws the finished video: StoryArt's looks and
/// EditCompositor's joins.
enum PreviewArt {
    static let tile = CGSize(width: 136, height: 148)
    static let steps = 14
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A clip's frame, small, at a moment of its file.
    static func still(_ c: Clip, at seconds: Double) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: c.source))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 360)
        let time = CMTime(seconds: min(max(0, seconds), max(0, c.length - 0.05)), preferredTimescale: 600)
        return try? await gen.image(at: time).image
    }

    /// The moment a clip's shown by: inside the part kept, past its first instant.
    static func middle(_ c: Clip) -> Double { c.start + c.duration * 0.4 }

    /// The frame in each filter.
    static func looks(_ picture: CGImage, names: [String]) -> [String: CGImage] {
        let source = CIImage(cgImage: picture)
        var out: [String: CGImage] = [:]
        for name in names {
            let made: CIImage = StoryArt.filtered(source, name).cropped(to: source.extent)
            if let img = context.createCGImage(made, from: source.extent) { out[name] = img }
        }
        return out
    }

    /// One clip turning into the next, a step at a time.
    static func join(_ a: CGImage, _ b: CGImage, kind: String, direction: String) -> [CGImage] {
        let frame = CGRect(origin: .zero, size: tile)
        let going: CIImage = EditCompositor.placed(CIImage(cgImage: a), in: frame, fill: "Fill")
        let coming: CIImage = EditCompositor.placed(CIImage(cgImage: b), in: frame, fill: "Fill")
        var out: [CGImage] = []
        for i in 0..<steps {
            let p: CGFloat = CGFloat(i) / CGFloat(steps - 1)
            let made: CIImage
            if kind == "None" {
                made = p < 0.5 ? going : coming
            } else {
                made = EditCompositor.blend(going, coming, kind: kind, direction: direction, p: p, frame: frame)
            }
            if let img = context.createCGImage(made.cropped(to: frame), from: frame) { out.append(img) }
        }
        return out
    }

    /// How far through a preview is at a moment: a beat still at each end, round and round.
    static func progress(at seconds: Double, length: Double = 1.1, rest: Double = 0.6) -> Double {
        let round: Double = length + rest * 2
        let into: Double = seconds - (seconds / round).rounded(.down) * round
        return min(1, max(0, (into - rest) / max(length, 0.01)))
    }
}
