import AVFoundation
import CoreImage
import UIKit

/// The edit's frame and what fills it (Stage A2, 19 Nov): its shape, and a clip of another shape filled into it
/// (cropped), or shown whole on a blurred copy of itself, or on black.
struct EditLook: Codable, Equatable {
    var shape = "Original"   // "Original" (the first clip's), "9:16", "4:5", "1:1"
    var fill = "Fill"        // "Fill", "Blur", "Black"
    static let shapes = ["Original", "9:16", "4:5", "1:1"]
    static let fills = ["Fill", "Blur", "Black"]
    /// Width over height, or nil for the first clip's own.
    var ratio: CGFloat? {
        switch shape {
        case "9:16": return 9.0 / 16.0
        case "4:5": return 0.8
        case "1:1": return 1
        default: return nil
        }
    }
}

/// How one clip turns into the next (Stage A2; design/editor-all-tools-mockup.html, 3): the kind, and how long, seconds.
struct ClipTransition: Codable, Equatable {
    var kind: String
    var length: Double = 0.5
    static let kinds = ["Crossfade", "Slide", "Zoom", "Fade to black", "Whip"]
}

/// One clip's picture in a stretch of the video: the track it's on, which way up it goes, and its look.
struct EditLayer {
    var track: CMPersistentTrackID
    var orientation: CGImagePropertyOrientation
    var look: String
    /// Its zoom and drift (Stage D), timed from `begins`, when it starts in the video.
    var moves: [MoveKey] = []
    var begins = 0.0
}

/// A stretch of the video: one clip, or two while one turns into the next.
final class EditInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [EditLayer]          // going, then coming
    let transition: String?
    let fill: String
    /// Text, stickers and captions over the whole edit (Stage B): each drawn while it shows.
    let overlays: [OverlayPiece]
    /// Clips and photos over it (Stage D).
    let pips: [PipLayer]

    init(_ range: CMTimeRange, layers: [EditLayer], transition: String?, fill: String, overlays: [OverlayPiece] = [], pips: [PipLayer] = []) {
        timeRange = range
        self.layers = layers
        self.transition = transition
        self.fill = fill
        self.overlays = overlays
        self.pips = pips
        // an overlay's track only while it's over this stretch
        let over = pips.filter { $0.from < range.end.seconds && $0.to > range.start.seconds }.map { NSNumber(value: $0.track) }
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.track) } + over
    }
}

/// Draws each frame of an edit with Core Image: every clip the right way up, through its look, into the frame
/// (filled, or whole on a blurred copy), and the transitions between them.
final class EditCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "edit-compositor", qos: .userInitiated)

    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let ins = request.videoCompositionInstruction as? EditInstruction, let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "EditCompositor", code: 1)); return
            }
            let size = request.renderContext.size
            let frame = CGRect(origin: .zero, size: size)
            var pics: [CIImage] = []
            for l in ins.layers {
                guard let px = request.sourceFrame(byTrackID: l.track) else { continue }
                var img = CIImage(cvPixelBuffer: px).oriented(l.orientation)
                img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                if l.look != "Normal" {
                    let e = img.extent
                    img = StoryArt.filtered(img.clampedToExtent(), l.look, frame: e).cropped(to: e)
                }
                var put = Self.placed(img, in: frame, fill: ins.fill)
                if !l.moves.isEmpty {
                    // zoomed about the middle and drifted, as its keyframes have it now
                    let m = MoveKey.value(l.moves, at: request.compositionTime.seconds - l.begins, base: MoveKey(at: 0))
                    let zoom = CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
                        .concatenating(CGAffineTransform(scaleX: m.size, y: m.size))
                        .concatenating(CGAffineTransform(translationX: frame.midX + (m.x - 0.5) * frame.width, y: frame.midY - (m.y - 0.5) * frame.height))
                    put = put.transformed(by: zoom).cropped(to: frame)
                }
                pics.append(put)
            }
            let black = CIImage(color: .black).cropped(to: frame)
            var shown = pics.first ?? black
            if pics.count == 2, let kind = ins.transition {
                let r = ins.timeRange
                let p = min(1, max(0, (request.compositionTime - r.start).seconds / max(r.duration.seconds, 0.001)))
                shown = Self.blend(pics[0], pics[1], kind: kind, p: CGFloat(p), frame: frame)
            }
            let t = request.compositionTime.seconds
            // a clip or photo over it, where and how big its keyframes have it, see-through as set
            for p in ins.pips where t >= p.from - 0.0001 && t < p.to {
                guard let px = request.sourceFrame(byTrackID: p.track) else { continue }
                var img = CIImage(cvPixelBuffer: px).oriented(p.orientation)
                img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                let m = MoveKey.value(p.keys, at: t - p.from, base: p.base)
                let k = CGFloat(m.size) * size.width / max(img.extent.width, 1)
                img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
                img = img.transformed(by: CGAffineTransform(translationX: m.x * size.width - img.extent.width / 2, y: (1 - m.y) * size.height - img.extent.height / 2))
                if m.opacity < 0.99 {
                    img = img.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: CIImage(color: .clear).cropped(to: img.extent),
                                                                                  kCIInputTimeKey: 1 - max(0, m.opacity)])
                }
                shown = img.composited(over: shown)
            }
            // what's over it now, each centred where it was put (Core Image counts up from the bottom)
            for o in ins.overlays where t >= o.from - 0.0001 && t < o.to {
                let e = o.image.extent
                let at = CGAffineTransform(translationX: o.x * size.width - e.width / 2 - e.minX, y: (1 - o.y) * size.height - e.height / 2 - e.minY)
                shown = o.image.transformed(by: at).composited(over: shown)
            }
            context.render(shown.composited(over: black).cropped(to: frame), to: out)
            request.finish(withComposedVideoFrame: out)
        }
    }

    /// Which way up a track's frames go, from its transform (as the camera wrote it).
    static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
        if near(t.a, 0), near(t.b, 1), near(t.c, -1), near(t.d, 0) { return .right }
        if near(t.a, 0), near(t.b, -1), near(t.c, 1), near(t.d, 0) { return .left }
        if near(t.a, -1), near(t.d, -1) { return .down }
        return .up
    }

    /// A picture in the frame: filled (cropped to it), or whole on a blurred, dimmed copy of itself, or on black.
    static func placed(_ img: CIImage, in frame: CGRect, fill: String) -> CIImage {
        let e = img.extent
        guard e.width > 1, e.height > 1 else { return img }
        let cover = max(frame.width / e.width, frame.height / e.height), fit = min(frame.width / e.width, frame.height / e.height)
        func put(_ i: CIImage, _ k: CGFloat) -> CIImage {
            let s = i.transformed(by: CGAffineTransform(scaleX: k, y: k))
            return s.transformed(by: CGAffineTransform(translationX: frame.midX - s.extent.midX, y: frame.midY - s.extent.midY))
        }
        if fill == "Fill" || cover - fit < 0.01 { return put(img, cover).cropped(to: frame) }
        let front = put(img, fit)
        var back = CIImage(color: .black).cropped(to: frame)
        if fill == "Blur" {
            // made small, blurred there and drawn back up: a sixty-fourth of the work (as Stories.compress does it)
            let small = img.transformed(by: CGAffineTransform(scaleX: cover / 8, y: cover / 8))
            let soft = small.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: small.extent)
            let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.28)).cropped(to: frame)
            back = dim.composited(over: put(soft, 8).cropped(to: frame)).composited(over: back)
        }
        return front.composited(over: back).cropped(to: frame)
    }

    /// One clip turning into the next, `p` of the way through.
    static func blend(_ a: CIImage, _ b: CIImage, kind: String, p: CGFloat, frame: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: frame)
        let eased = p * p * (3 - 2 * p)
        func dissolve(_ x: CIImage, _ y: CIImage, _ t: CGFloat) -> CIImage {
            x.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: y, kCIInputTimeKey: t]).cropped(to: frame)
        }
        func slid(_ k: CGFloat) -> CIImage {
            let w = frame.width
            let going = a.transformed(by: CGAffineTransform(translationX: -w * k, y: 0))
            let coming = b.transformed(by: CGAffineTransform(translationX: w * (1 - k), y: 0))
            return coming.composited(over: going).composited(over: black).cropped(to: frame)
        }
        switch kind {
        case "Slide":
            return slid(eased)
        case "Whip":
            // fast in the middle, blurred along the way it moves
            let k = eased * eased * (3 - 2 * eased)
            let r = sin(Double(p) * Double.pi) * 70
            return slid(k).clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: r, kCIInputAngleKey: 0]).cropped(to: frame)
        case "Zoom":
            let z = 1 + 0.5 * eased
            let grown = a.transformed(by: CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
                .concatenating(CGAffineTransform(scaleX: z, y: z))
                .concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY))).cropped(to: frame)
            return dissolve(grown, b, eased)
        case "Fade to black":
            return p < 0.5 ? dissolve(a, black, p * 2) : dissolve(black, b, p * 2 - 1)
        default:
            return dissolve(a, b, p)
        }
    }
}

/// Where something is at a moment (Stage D): its middle as fractions of the frame, its size (a clip's zoom, an
/// overlay's width as a fraction of the frame's), and how see-through. `at` is seconds from when it starts.
struct MoveKey: Codable, Equatable {
    var at: Double
    var x = 0.5
    var y = 0.5
    var size = 1.0
    var opacity = 1.0

    /// Between its keyframes at `t`, eased; `base` with none.
    static func value(_ keys: [MoveKey], at t: Double, base: MoveKey) -> MoveKey {
        let k = keys.sorted { $0.at < $1.at }
        guard let first = k.first, let last = k.last else { return base }
        if t <= first.at { return first }
        if t >= last.at { return last }
        guard let i = k.firstIndex(where: { $0.at > t }), i > 0 else { return last }
        let a = k[i - 1], b = k[i]
        let raw = (t - a.at) / max(b.at - a.at, 0.001), e = raw * raw * (3 - 2 * raw)
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * e }
        return MoveKey(at: t, x: mix(a.x, b.x), y: mix(a.y, b.y), size: mix(a.size, b.size), opacity: mix(a.opacity, b.opacity))
    }
}

/// A second clip or photo over the edit (Stage D), as the compositor lays it on.
struct PipLayer {
    var track: CMPersistentTrackID
    var orientation: CGImagePropertyOrientation
    var from: Double
    var to: Double
    var base: MoveKey
    var keys: [MoveKey]
}
