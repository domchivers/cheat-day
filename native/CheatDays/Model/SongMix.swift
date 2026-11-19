import AVFoundation

/// A post's song, mixed into its video's own sound when it's posted (19 Nov). Before this the two were separate
/// players started side by side, a song and a clip that drifted, cut in at different moments and each had a say
/// in muting. Mixed, it's one file: one player, one speaker, and the song and the clip always in step. Posts from
/// before carry on with the two players; a mixed one says so with extra.mixed, and keeps the clip's own sound on
/// its own beside it (extra.sound) so the song can be changed later without the old one still in it.
struct SongMix {
    let file: URL      // the song, on the phone
    let from: Double   // where in it the part starts
    let span: Double   // how long that part is
    let song: Float, clip: Float

    /// The song fetched to mix: its longer clip from the part chosen, or its usual 30 seconds. Nil if it couldn't be got.
    static func make(_ s: Song, song: Float, clip: Float) async -> SongMix? {
        let long = Music.long[s.id] != nil
        guard let remote = long ? s.longURL : s.url else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        // the copy on the phone when it's been heard (MediaCache), copied so `done` can't take it away
        if let here = MediaCache.local(remote) {
            guard (try? FileManager.default.copyItem(at: here, to: file)) != nil else { return nil }
        } else {
            guard let (tmp, _) = try? await URLSession.shared.download(from: remote),
                  (try? FileManager.default.moveItem(at: tmp, to: file)) != nil else { return nil }
        }
        let from = long ? s.from : 0
        let length = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
        let span = min(Song.part, length - from)
        guard span.isFinite, span > 1 else { try? FileManager.default.removeItem(at: file); return nil }
        return SongMix(file: file, from: from, span: span, song: song, clip: clip)
    }

    func done() { try? FileManager.default.removeItem(at: file) }
}

/// The mix couldn't be made: the video goes up as before, its song played beside it.
struct MixFailed: Error {}

extension Stories {
    /// The clip's own sound alone, trimmed as its posted video is (at most 30 seconds): kept beside a mixed video.
    static func soundOnly(_ url: URL, range: ClosedRange<Double>?) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let a = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let full = (try? await asset.load(.duration).seconds) ?? 15
        let start = range?.lowerBound ?? 0, end = min(range?.upperBound ?? full, start + 30)
        let comp = AVMutableComposition()
        guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let span = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        guard (try? t.insertTimeRange(span, of: a, at: .zero)) != nil,
              let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        export.outputURL = out; export.outputFileType = .m4a
        await export.export()
        defer { try? FileManager.default.removeItem(at: out) }
        return export.status == .completed ? try? Data(contentsOf: out) : nil
    }

    /// A mixed video taken back to the clip alone, to edit: its picture as it is, and its own sound from beside it
    /// (none if it had none). Made without working the picture out again, so it's quick.
    static func unmixed(_ video: URL, sound: URL?) async -> URL? {
        let v = AVURLAsset(url: video)
        guard let track = try? await v.loadTracks(withMediaType: .video).first,
              let length = try? await v.load(.duration) else { return nil }
        let comp = AVMutableComposition()
        guard let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? t.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)) != nil else { return nil }
        t.preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        if let sound {
            let s = AVURLAsset(url: sound)
            if let a = try? await s.loadTracks(withMediaType: .audio).first, let own = try? await s.load(.duration),
               let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? at.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(own, length)), of: a, at: .zero)
            }
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        export.outputURL = out; export.outputFileType = .mov
        await export.export()
        return export.status == .completed ? out : nil
    }
}

extension Music {
    /// The post's song is in its video's own sound (see SongMix).
    static func mixed(_ post: JSON) -> Bool { dict(post["extra"])["mixed"] as? Bool == true }
}
