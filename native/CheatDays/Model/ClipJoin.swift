import AVFoundation
import UIKit

/// One clip in a video made of several (19 Nov; design/multi-clip-editor-mockup.html): the part of its file kept, and
/// its own sound. A photo is a clip too, made into a short silent video first (ClipJoin.still).
struct Clip: Identifiable, Equatable, Codable {
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
    /// How long its sound fades in and out, seconds (0: none). As CapCut and Edits have it (19 Nov): a length, not on or off.
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// Volume keyframes, as CapCut's diamonds: the volume at moments of the file's own time, eased between; none: `volume` throughout.
    var keys: [VolumeKey] = []
    /// How fast it plays, 0.25 to 4 (Stage A1): its sound kept in pitch.
    var speed: Double = 1
    /// How it turns into the next clip (Stage A2); nil: a straight cut.
    var transition: ClipTransition?
    /// Its look: a filter and any Adjust, written as StoryArt writes them ("Warm;b=20").
    var look = "Normal"
    /// Played backwards (Stage A2): the file it was made from, to go forwards again.
    var forward: Forward?
    /// Its sound made clearer (Stage C, Clarity): played instead of its own, at the same times.
    var clean: URL?
    /// Its zoom and drift over time (Stage D): seconds from its start in the video; none, still.
    var moves: [MoveKey] = []

    /// The part of its file kept, seconds of the file.
    var duration: Double { max(0, end - start) }
    /// How long it lasts in the video: what's kept, at its speed.
    var span: Double { duration / max(speed, 0.01) }
    var heardStart: Double { max(start, soundStart ?? start) }
    var heardEnd: Double { min(end, soundEnd ?? end) }

    /// Its sound's level at a moment of the file's own time: the keyframes (or its volume), then the fades.
    func level(at t: Double) -> Float {
        var v = volume
        let k = keys.sorted { $0.at < $1.at }
        if let first = k.first, let last = k.last {
            if t <= first.at { v = first.volume }
            else if t >= last.at { v = last.volume }
            else if let i = k.firstIndex(where: { $0.at > t }) {
                let a = k[i - 1], b = k[i], f = Float((t - a.at) / max(b.at - a.at, 0.001))
                v = a.volume + (b.volume - a.volume) * f
            }
        }
        if fadeIn > 0.01, t - heardStart < fadeIn { v *= Float(max(0, t - heardStart) / fadeIn) }
        if fadeOut > 0.01, heardEnd - t < fadeOut { v *= Float(max(0, heardEnd - t) / fadeOut) }
        return max(0, min(1, v))
    }

    /// The moments its level changes slope (fade ends, keyframes), inside its sound: where the join's ramps meet.
    var turns: [Double] {
        var at = [heardStart, heardEnd]
        if fadeIn > 0.01 { at.append(heardStart + fadeIn) }
        if fadeOut > 0.01 { at.append(heardEnd - fadeOut) }
        at += keys.map(\.at)
        return Array(Set(at.map { min(heardEnd, max(heardStart, $0)) })).sorted()
    }
}

/// A reversed clip's way back: the file it was turned round from, and where the part turned round ended in it
/// (a moment of the reversed file is that end, less the moment).
struct Forward: Codable, Equatable {
    var source: URL
    var length: Double
    var end: Double
    var soundOn: Bool
}

/// A clip's volume at one moment (CapCut's keyframe diamond).
struct VolumeKey: Equatable, Codable {
    var at: Double      // the clip file's own seconds
    var volume: Float
}

enum ClipJoin {
    /// The longest a joined post can be (Stories.compress keeps that much).
    static let longest = Stories.longest
    static let photoSeconds = 3.0
    private static func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    /// How long clip `i` and the next play over each other as one turns into the other (never more than half of either).
    static func overlap(_ clips: [Clip], after i: Int) -> Double {
        guard i >= 0, i + 1 < clips.count, let tr = clips[i].transition else { return 0 }
        return max(0, min(tr.length, clips[i].span / 2, clips[i + 1].span / 2))
    }

    /// Where each clip starts in the video.
    static func starts(_ clips: [Clip]) -> [Double] {
        var out: [Double] = [], at = 0.0
        for i in clips.indices { out.append(at); at += clips[i].span - overlap(clips, after: i) }
        return out
    }

    /// How long the video is.
    static func total(_ clips: [Clip]) -> Double {
        guard let last = clips.indices.last else { return 0 }
        return starts(clips)[last] + clips[last].span
    }

    /// A file picked, as a clip: all of it kept.
    static func clip(_ url: URL, still: Bool = false) async -> Clip? {
        let asset = AVURLAsset(url: url)
        // the picture's own length, not the file's: the sound often runs a little longer, and a clip kept to the
        // file's end then asked for picture that isn't there, so none of it went in and it came out black (19 Nov)
        guard let v = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await v.load(.timeRange), case let d = range.end.seconds, d.isFinite, d > 0.1 else { return nil }
        return Clip(source: url, length: d, start: max(0, range.start.seconds), end: d, still: still, soundOn: !still)
    }

    /// One clip in two at `at` seconds into it (its own kept part), or nil if that's too near an end.
    static func split(_ c: Clip, at: Double) -> (Clip, Clip)? {
        let cut = c.start + at
        guard cut - c.start > 0.3, c.end - cut > 0.3 else { return nil }
        var a = c, b = c
        a.end = cut; a.fadeOut = 0; a.transition = nil
        // each half keeps its own part of the movement, the second's timed from its own start
        a.moves = c.moves.filter { $0.at <= a.span + 0.001 }
        b.moves = c.moves.filter { $0.at >= a.span - 0.001 }.map { var m = $0; m.at -= a.span; return m }
        b.id = UUID(); b.start = cut; b.fadeIn = 0
        // each half keeps the keyframes inside it
        a.keys = c.keys.filter { $0.at <= cut }; b.keys = c.keys.filter { $0.at >= cut }
        // the sound kept stays where it was in time, cut with the picture (a half with none of it left is silent)
        a.soundEnd = min(c.soundEnd ?? cut, cut)
        b.soundStart = max(c.soundStart ?? cut, cut)
        return (a, b)
    }

    /// The clips as one: a composition to play straight away (the editor's preview) and to export. The clips go on two
    /// tracks in turn, so one can play over the next while it turns into it (Stage A2); EditCompositor draws each frame:
    /// every clip the right way up, through its look, into the frame the shape `look` asks (the first clip's otherwise),
    /// filled or whole on a blurred copy. Each clip's sound at its own level with its fades, dipping across a
    /// transition; `soundOf`: one clip's sound for the whole of it instead, round again if it's shorter. `swap`: a
    /// smaller copy of a file to play instead (a 4K clip's, for the preview).
    static func compose(_ clips: [Clip], soundOf: UUID? = nil, look: EditLook = EditLook(), swap: [URL: URL] = [:], overlays: [OverlayPiece] = [],
                        sounds: [EditSound] = [], pips: [EditPip] = []) async -> (AVMutableComposition, AVMutableVideoComposition, AVMutableAudioMix)? {
        let comp = AVMutableComposition()
        guard let v0 = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let v1 = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a0 = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a1 = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let videos = [v0, v1], tracks = [a0, a1]
        let levels = [AVMutableAudioMixInputParameters(track: a0), AVMutableAudioMixInputParameters(track: a1)]
        // the frame: the shape asked for, 1080 across; or the first clip's shape, the right way up, at most 1080 across
        var frame = CGSize(width: 1080, height: 1920)
        if let r = look.ratio {
            frame = CGSize(width: 1080, height: (1080 / r / 2).rounded() * 2)
        } else if let first = clips.first, let v = try? await AVURLAsset(url: first.source).loadTracks(withMediaType: .video).first,
                  let n = try? await v.load(.naturalSize), let tf = try? await v.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: n).applying(tf)
            let w = abs(r.width), h = abs(r.height)
            if w > 0, h > 0 { let k = min(1, 1080 / w); frame = CGSize(width: (w * k / 2).rounded() * 2, height: (h * k / 2).rounded() * 2) }
        }
        // Everything timed in whole 600ths of a second, so the stretches meet exactly: a gap or an overlap of a
        // rounding between two and the video won't play.
        func tick(_ x: Double) -> Int64 { Int64((x * 600).rounded()) }
        func tt(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 600) }
        struct Piece { var at: Int64; var lasts: Int64; var layer: EditLayer; var into: String?; var out: Int64 }
        var pieces: [Piece] = []
        var cursor: Int64 = 0
        // While a voiceover plays, everything else dips to under a third (CapCut's ducking), easing down and back
        // up over a fifth of a second either side. The takes' times are merged where they touch.
        var dips: [(Double, Double)] = []
        for v in sounds.filter({ $0.kind == "voice" }).sorted(by: { $0.from < $1.from }) {
            if let lastDip = dips.last, v.from <= lastDip.1 + 0.4 { dips[dips.count - 1].1 = max(lastDip.1, v.to) } else { dips.append((v.from, v.to)) }
        }
        let ease = 0.2, low: Float = 0.3
        func dip(_ v: Double) -> Float {
            var k: Float = 1
            for (a, b) in dips {
                if v >= a && v <= b { k = min(k, low) }
                else if v > a - ease && v < a { k = min(k, 1 - (1 - low) * Float((v - (a - ease)) / ease)) }
                else if v > b && v < b + ease { k = min(k, low + (1 - low) * Float((v - b) / ease)) }
            }
            return k
        }
        for (i, c) in clips.enumerated() where c.duration > 0.05 {
            let asset = AVURLAsset(url: swap[c.source] ?? c.source)
            guard let v = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            // only what picture there is (a clip kept past its picture's end went in not at all, and showed black)
            let has = (try? await v.load(.timeRange)) ?? CMTimeRange(start: .zero, end: t(c.end))
            let shown = max(c.start, has.start.seconds), until = min(c.end, has.end.seconds)
            let from = tick(shown), dur = tick(until) - tick(shown)
            guard dur > 30 else { continue }
            let rate = max(c.speed, 0.01), lasts = max(1, Int64((Double(dur) / rate).rounded()))
            let track = pieces.count % 2
            guard (try? videos[track].insertTimeRange(CMTimeRange(start: tt(from), duration: tt(dur)), of: v, at: tt(cursor))) != nil else { continue }
            if lasts != dur { videos[track].scaleTimeRange(CMTimeRange(start: tt(cursor), duration: tt(dur)), toDuration: tt(lasts)) }
            let tf = (try? await v.load(.preferredTransform)) ?? .identity
            // how long it plays over the next, as the editor works it out (from what's in the video of each)
            var out: Int64 = 0
            if let tr = c.transition, i + 1 < clips.count {
                out = min(tick(tr.length), lasts / 2, tick(clips[i + 1].span / 2))
                out = max(0, out)
            }
            let layer = EditLayer(track: videos[track].trackID, orientation: EditCompositor.orientation(tf), look: c.look,
                                  moves: c.moves, begins: Double(cursor) / 600)
            pieces.append(Piece(at: cursor, lasts: lasts, layer: layer, into: out > 0 ? c.transition?.kind : nil, out: out))
            // its own sound, unless one clip's sound plays over everything; across a transition it fades out as the
            // next fades in
            let heardFrom = c.clean.map { AVURLAsset(url: $0) } ?? asset
            if soundOf == nil, c.soundOn, !c.still, c.heardEnd - c.heardStart > 0.05,
               let a = try? await heardFrom.loadTracks(withMediaType: .audio).first {
                var heard = c
                let before = pieces.count >= 2 ? pieces[pieces.count - 2].out : 0
                if before > 0 { heard.fadeIn = max(heard.fadeIn, Double(before) / 600 * rate) }
                if out > 0 { heard.fadeOut = max(heard.fadeOut, Double(out) / 600 * rate) }
                let at0 = Double(cursor) / 600 + (heard.heardStart - shown) / rate, span = min(heard.heardEnd, until) - heard.heardStart
                if span > 0.05, (try? tracks[track].insertTimeRange(CMTimeRange(start: t(heard.heardStart), duration: t(span)), of: a, at: t(at0))) != nil {
                    if abs(rate - 1) > 0.001 { tracks[track].scaleTimeRange(CMTimeRange(start: t(at0), duration: t(span)), toDuration: t(span / rate)) }
                    // its level through it, from its keyframes and fades and the dips under a voiceover: a straight
                    // ramp between each moment it turns (in its file's time; the video's is at0 on, at its speed)
                    let video = { (p: Double) -> Double in at0 + (p - heard.heardStart) / rate }
                    let file = { (v: Double) -> Double in heard.heardStart + (v - at0) * rate }
                    let edges = dips.flatMap { [file($0.0 - ease), file($0.0), file($0.1), file($0.1 + ease)] }
                        .filter { $0 > heard.heardStart && $0 < heard.heardStart + span }
                    let marks = Array(Set(heard.turns.filter { $0 <= heard.heardStart + span } + edges)).sorted()
                    let level = { (p: Double) -> Float in heard.level(at: p) * dip(video(p)) }
                    levels[track].setVolume(level(heard.heardStart), at: t(at0))
                    for (p, q) in zip(marks, marks.dropFirst()) where q - p > 0.01 {
                        levels[track].setVolumeRamp(fromStartVolume: level(p), toEndVolume: level(q),
                                                    timeRange: CMTimeRange(start: t(video(p)), duration: t((q - p) / rate)))
                    }
                }
            }
            cursor += lasts - out
        }
        guard let last = pieces.last else { return nil }
        let end = last.at + last.lasts
        // one clip's sound for all of it
        if let id = soundOf, let c = clips.first(where: { $0.id == id }), !c.still,
           let a = try? await AVURLAsset(url: c.source).loadTracks(withMediaType: .audio).first {
            let span = c.heardEnd - c.heardStart, total = Double(end) / 600
            var put = 0.0
            while span > 0.2, put < total - 0.01 {
                let piece = min(span, total - put)
                try? a0.insertTimeRange(CMTimeRange(start: t(c.heardStart), duration: t(piece)), of: a, at: t(put))
                put += piece
            }
            levels[0].setVolume(c.volume, at: .zero)
            for (a, b) in dips {
                levels[0].setVolumeRamp(fromStartVolume: c.volume, toEndVolume: c.volume * low, timeRange: CMTimeRange(start: t(max(0, a - ease)), duration: t(ease)))
                levels[0].setVolumeRamp(fromStartVolume: c.volume * low, toEndVolume: c.volume, timeRange: CMTimeRange(start: t(b), duration: t(ease)))
            }
        }
        // voiceovers and sound effects, each on a track of its own, at its own level
        var laid: [AVMutableAudioMixInputParameters] = []
        for snd in sounds {
            guard let url = snd.url, let a = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
                  let range = try? await a.load(.timeRange),
                  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let take = min(snd.length, range.end.seconds - snd.start, Double(end) / 600 - snd.from)
            guard take > 0.05, (try? track.insertTimeRange(CMTimeRange(start: t(snd.start), duration: t(take)), of: a, at: t(snd.from))) != nil else {
                comp.removeTrack(track); continue
            }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(snd.volume, at: .zero)
            laid.append(p)
        }
        // clips and photos over it, each on a track of its own, no sound of their own
        var over: [PipLayer] = []
        for p in pips {
            guard let v = try? await AVURLAsset(url: p.source).loadTracks(withMediaType: .video).first,
                  let range = try? await v.load(.timeRange),
                  let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let take = min(p.length, range.end.seconds - p.start, Double(end) / 600 - p.from)
            guard take > 0.1, (try? track.insertTimeRange(CMTimeRange(start: t(p.start), duration: t(take)), of: v, at: t(p.from))) != nil else {
                comp.removeTrack(track); continue
            }
            let tf = (try? await v.load(.preferredTransform)) ?? .identity
            over.append(PipLayer(track: track.trackID, orientation: EditCompositor.orientation(tf), from: p.from, to: p.from + take,
                                 base: MoveKey(at: 0, x: p.x, y: p.y, size: p.size, opacity: p.opacity), keys: p.keys))
        }
        // the stretches: each clip on its own, then it and the next together while one turns into the other
        var instructions: [EditInstruction] = []
        var from: Int64 = 0
        for (k, p) in pieces.enumerated() {
            let soloEnd = p.at + p.lasts - p.out
            if soloEnd > from {
                instructions.append(EditInstruction(CMTimeRange(start: tt(from), end: tt(soloEnd)), layers: [p.layer], transition: nil, fill: look.fill, overlays: overlays, pips: over))
                from = soloEnd
            }
            if p.out > 0, k + 1 < pieces.count {
                let both = p.at + p.lasts
                instructions.append(EditInstruction(CMTimeRange(start: tt(from), end: tt(both)), layers: [p.layer, pieces[k + 1].layer],
                                                    transition: p.into, fill: look.fill, overlays: overlays, pips: over))
                from = both
            }
        }
        // the last stretch to the very end of the composition (its sound may run a hair longer than its picture)
        let compEnd = max(end, tick(comp.duration.seconds))
        if let lastIns = instructions.popLast() {
            instructions.append(EditInstruction(CMTimeRange(start: lastIns.timeRange.start, end: tt(compEnd)), layers: lastIns.layers,
                                                transition: lastIns.transition, fill: look.fill, overlays: overlays, pips: over))
        }
        // tracks with nothing on them taken out (an empty sound track can stop the export)
        var mixes: [AVMutableAudioMixInputParameters] = []
        for (k, track) in tracks.enumerated() { if track.segments.isEmpty { comp.removeTrack(track) } else { mixes.append(levels[k]) } }
        if v1.segments.isEmpty { comp.removeTrack(v1) }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = EditCompositor.self
        vc.renderSize = frame
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = instructions
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixes + laid
        return (comp, vc, mix)
    }

    /// The clips as one video file on the phone, for the editor to take on as it takes a single video. `progress`
    /// hears how far it's got (0 to 1); cancelling the task that asked stops it.
    static func join(_ clips: [Clip], soundOf: UUID? = nil, look: EditLook = EditLook(), overlays: [OverlayPiece] = [], sounds: [EditSound] = [], pips: [EditPip] = [],
                     progress: @escaping @MainActor (Float) -> Void = { _ in }) async -> URL? {
        guard let (comp, vc, mix) = await compose(clips, soundOf: soundOf, look: look, overlays: overlays, sounds: sounds, pips: pips),
              let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        export.outputURL = out; export.outputFileType = .mov
        export.videoComposition = vc; export.audioMix = mix
        export.audioTimePitchAlgorithm = .spectral   // a clip at another speed keeps its voice
        let watch = Task {
            while !Task.isCancelled {
                await progress(export.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withTaskCancellationHandler {
            await export.export()
        } onCancel: {
            export.cancelExport()
        }
        watch.cancel()
        return export.status == .completed ? out : nil
    }

    /// A clip turned round (Stage A2): the part of it kept, played backwards, as a file of its own with no sound.
    /// Read a little at a time from the end, each piece's frames written last first.
    static func reversed(_ c: Clip) async -> URL? {
        let asset = AVURLAsset(url: c.source)
        guard let v = try? await asset.loadTracks(withMediaType: .video).first,
              let n = try? await v.load(.naturalSize), n.width > 0, n.height > 0 else { return nil }
        let tf = (try? await v.load(.preferredTransform)) ?? .identity
        let fps = Double((try? await v.load(.nominalFrameRate)) ?? 30)
        let step = 1 / max(fps, 1)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                          AVVideoWidthKey: n.width, AVVideoHeightKey: n.height])
        input.transform = tf
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        // a big picture a quarter second at a time (each held frame is several megabytes), others half a second
        let piece = n.width * n.height > 2_100_000 ? 0.25 : 0.5
        var top = c.end, last = -1.0
        while top > c.start + 0.001 {
            let bottom = max(c.start, top - piece)
            guard let reader = try? AVAssetReader(asset: asset) else { break }
            reader.timeRange = CMTimeRange(start: t(bottom), end: t(top))
            let output = AVAssetReaderTrackOutput(track: v, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            guard reader.canAdd(output) else { break }
            reader.add(output)
            guard reader.startReading() else { break }
            var frames: [(Double, CVPixelBuffer)] = []
            while let sb = output.copyNextSampleBuffer() {
                let at = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                if at >= bottom - 0.0001, at < top - 0.0001, let px = CMSampleBufferGetImageBuffer(sb) { frames.append((at, px)) }
            }
            reader.cancelReading()
            for (at, px) in frames.sorted(by: { $0.0 > $1.0 }) {
                var when = max(0, c.end - at - step)
                if when <= last { when = last + 0.001 }
                while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
                if !adaptor.append(px, withPresentationTime: t(when)) { break }
                last = when
            }
            top = bottom
            if Task.isCancelled { break }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: t(max(last + step, 0.1)))
        await writer.finishWriting()
        if Task.isCancelled { try? FileManager.default.removeItem(at: out); return nil }
        return writer.status == .completed ? out : nil
    }

    /// A smaller copy of a big (4K) video for the editor to play while it's edited (Stage A2): the finished video is
    /// made from the file itself. Nil when it's small enough already.
    static func proxy(_ url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let v = try? await asset.loadTracks(withMediaType: .video).first, let n = try? await v.load(.naturalSize),
              max(n.width, n.height) > 1920,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-" + UUID().uuidString + ".mov")
        export.outputURL = out; export.outputFileType = .mov
        await export.export()
        return export.status == .completed ? out : nil
    }

    /// A photo as a short silent video (photoSeconds), at most 1080 across, so it can sit among clips.
    static func still(_ image: UIImage, seconds: Double = photoSeconds) async -> URL? {
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
        for time in [CMTime.zero, t(seconds - 1.0 / 30)] {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(px, withPresentationTime: time)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: t(seconds))
        await writer.finishWriting()
        return writer.status == .completed ? out : nil
    }

    /// The frame at a moment of a clip's file, exactly (a freeze holds it).
    static func frame(_ c: Clip, at seconds: Double) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: c.source))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        guard let img = try? await gen.image(at: t(seconds)).image else { return nil }
        return UIImage(cgImage: img)
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

extension Clip {
    private enum CodingKeys: String, CodingKey {
        case id, source, length, start, end, still, soundOn, volume, soundStart, soundEnd, fadeIn, fadeOut, keys, speed, transition, look, forward, clean, moves
    }
    /// Read from a draft, a field it was saved without (added in a later build) taking its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try c.decode(URL.self, forKey: .source), length: try c.decode(Double.self, forKey: .length),
                  start: try c.decode(Double.self, forKey: .start), end: try c.decode(Double.self, forKey: .end))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        still = try c.decodeIfPresent(Bool.self, forKey: .still) ?? false
        soundOn = try c.decodeIfPresent(Bool.self, forKey: .soundOn) ?? true
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        soundStart = try c.decodeIfPresent(Double.self, forKey: .soundStart)
        soundEnd = try c.decodeIfPresent(Double.self, forKey: .soundEnd)
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        keys = try c.decodeIfPresent([VolumeKey].self, forKey: .keys) ?? []
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        transition = try c.decodeIfPresent(ClipTransition.self, forKey: .transition)
        look = try c.decodeIfPresent(String.self, forKey: .look) ?? "Normal"
        forward = try c.decodeIfPresent(Forward.self, forKey: .forward)
        clean = try c.decodeIfPresent(URL.self, forKey: .clean)
        moves = try c.decodeIfPresent([MoveKey].self, forKey: .moves) ?? []
    }
}
