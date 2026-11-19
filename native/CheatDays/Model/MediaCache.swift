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
    // all under the lock
    private static var running: [String: URLSessionDownloadTask] = [:]
    private static var ahead: Set<String> = []       // of those running or waiting, the ones fetched ahead
    private static var waiting: [URL] = []
    private static var trimmed = false
    /// At most this many at once, so the one being watched keeps most of the connection (TikTok's player kit, BytePlus,
    /// preloads two at a time and cancels them on a swipe).
    private static let most = 2

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

    /// Where to play it from: the copy here, or the internet, with a copy fetched for next time once it's had a
    /// moment to get going.
    static func source(_ remote: URL) -> URL {
        if let f = local(remote) { return f }
        warm(remote, ahead: true)
        return remote
    }

    /// Fetched to the phone in the background, if it isn't here or on its way already. `ahead`: for a post not
    /// reached yet, it waits a moment and its turn, and can be called off (`only`).
    static func warm(_ remote: URL?, ahead isAhead: Bool = false) {
        guard let remote, remote.scheme?.hasPrefix("http") == true, local(remote) == nil else { return }
        let key = remote.absoluteString
        lock.lock()
        let first = !trimmed
        trimmed = true
        let known = running[key] != nil || waiting.contains(remote)
        if !known {
            waiting.append(remote)
            if isAhead { ahead.insert(key) }
        } else if !isAhead, ahead.contains(key) {
            // wanted now after all: no longer one that can be called off, and first in line
            ahead.remove(key)
            if let i = waiting.firstIndex(of: remote) { waiting.remove(at: i); waiting.insert(remote, at: 0) }
        }
        lock.unlock()
        if first { trim() }
        guard !known || !isAhead else { return }
        // what's being watched starts loading first; these wait a moment behind it
        if isAhead { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { pump() } } else { pump() }
    }

    /// Of the ones fetched ahead, only these are still wanted: the rest are called off (scrolled past).
    static func only(_ keep: [URL?]) {
        let wanted = Set(keep.compactMap { $0?.absoluteString })
        lock.lock()
        let gone = ahead.subtracting(wanted)
        waiting.removeAll { gone.contains($0.absoluteString) }
        let stop = gone.compactMap { running[$0] }
        for k in gone { running[k] = nil }
        ahead.subtract(gone)
        lock.unlock()
        stop.forEach { $0.cancel() }
        pump()
    }

    private static func pump() {
        lock.lock()
        var start: [(URL, URLSessionDownloadTask)] = []
        while running.count < most, !waiting.isEmpty {
            let remote = waiting.removeFirst(), key = remote.absoluteString, to = file(remote)
            let task = URLSession.shared.downloadTask(with: remote) { tmp, resp, _ in
                // only a whole, good answer is kept (moved into place in one step, so a half one is never played)
                if let tmp, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    try? FileManager.default.moveItem(at: tmp, to: to)
                }
                lock.lock(); running[key] = nil; ahead.remove(key); lock.unlock()
                pump()
            }
            running[key] = task
            start.append((remote, task))
        }
        lock.unlock()
        start.forEach { $0.1.resume() }
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
    /// The file the player plays: its longer clip when it has one.
    var file: URL? { Music.long[id] != nil ? longURL : url }
    /// Fetched to the phone ahead of being played (see MediaCache).
    func warm() { MediaCache.warm(file, ahead: true) }
}

extension Feed {
    /// A post's video and song fetched to the phone ahead of being shown (see MediaCache). A song mixed into its
    /// video comes with the video.
    static func warm(_ p: JSON) {
        MediaCache.warm(video(p), ahead: true)
        if let s = Music.of(p), !Music.mixed(p) { s.warm() }
    }
    /// This post and the two after it in the list, as it comes up: by the time those are reached they're here.
    /// `swiped`: a pager with one post at a time (reels), where anything fetched ahead for posts left behind is
    /// called off; the feed shows several at once and lets them finish.
    static func warmAhead(_ id: String, in list: [JSON], swiped: Bool = false) {
        guard let i = list.firstIndex(where: { str($0["id"]) == id }) else { return }
        let next = Array(list[i..<min(list.count, i + 3)])
        for p in next { warm(p) }
        if swiped { MediaCache.only(next.flatMap { [video($0), Music.of($0)?.file] }) }
    }
}
