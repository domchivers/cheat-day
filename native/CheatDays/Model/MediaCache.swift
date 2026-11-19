import Foundation

/// Songs and videos kept on the phone once fetched (19 Nov). Each was streamed from the internet every time it came
/// on screen, so a song started a moment after its post settled and a video sat on its first frame while it
/// loaded; Instagram has the next few ready before they're reached. Played from here when they're here, and
/// fetched ahead (`warm`) as their posts come near. The newest 300 MB are kept.
enum MediaCache {
    private static let folder: URL = {
        let f = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()
    private static let limit = 300 * 1024 * 1024
    private static let lock = NSLock()
    private static var fetching: Set<String> = []
    private static var trimmed = false

    private static func file(_ remote: URL) -> URL {
        // a stable name from the address (Swift's own hash changes every launch), with its own ending kept
        var h: UInt64 = 1469598103934665603
        for b in remote.absoluteString.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let ext = remote.pathExtension.isEmpty ? "bin" : remote.pathExtension
        return folder.appendingPathComponent(String(h, radix: 36) + "." + ext)
    }

    /// The copy on the phone, if it's here.
    static func local(_ remote: URL) -> URL? {
        let f = file(remote)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Where to play it from: the copy here, or the internet while a copy's fetched for next time.
    static func source(_ remote: URL) -> URL {
        if let f = local(remote) { return f }
        warm(remote)
        return remote
    }

    /// Fetched to the phone in the background, if it isn't here or on its way already.
    static func warm(_ remote: URL?) {
        guard let remote, remote.scheme?.hasPrefix("http") == true, local(remote) == nil else { return }
        let key = remote.absoluteString
        lock.lock()
        let fresh = fetching.insert(key).inserted
        let first = !trimmed
        trimmed = true
        lock.unlock()
        guard fresh else { return }
        if first { trim() }
        let to = file(remote)
        URLSession.shared.downloadTask(with: remote) { tmp, resp, _ in
            // only a whole, good answer is kept (moved into place in one step, so a half one is never played)
            if let tmp, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                try? FileManager.default.moveItem(at: tmp, to: to)
            }
            lock.lock(); fetching.remove(key); lock.unlock()
        }.resume()
    }

    /// The oldest let go of once there's more than the limit, once a launch, away from the screen.
    private static func trim() {
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            let rows = all.map { u -> (URL, Date, Int) in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return (u, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
            }.sorted { $0.1 > $1.1 }
            var total = 0
            for r in rows {
                total += r.2
                if total > limit { try? FileManager.default.removeItem(at: r.0) }
            }
        }
    }
}

extension Song {
    /// Fetched to the phone ahead of being played (see MediaCache): the file the player will play.
    func warm() { MediaCache.warm(Music.long[id] != nil ? longURL : url) }
}

extension Feed {
    /// A post's video and song fetched to the phone ahead of being shown (see MediaCache). A song mixed into its
    /// video comes with the video.
    static func warm(_ p: JSON) {
        MediaCache.warm(video(p))
        if let s = Music.of(p), !Music.mixed(p) { s.warm() }
    }
    /// This post and the two after it in the list, as it comes up: by the time those are reached they're here.
    static func warmAhead(_ id: String, in list: [JSON]) {
        guard let i = list.firstIndex(where: { str($0["id"]) == id }) else { return }
        for p in list[i..<min(list.count, i + 3)] { warm(p) }
    }
}
