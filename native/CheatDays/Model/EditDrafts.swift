import CryptoKit
import Foundation

/// Edits saved for later (19 Nov; design/edit-sound-drafts-mockup.html), kept on the phone as Instagram keeps its
/// drafts: each in a folder of its own with copies of its clips' files, so it still opens once the originals are gone
/// from the phone's temporary space. Shown at the top of Make an edit, newest first.
enum EditDrafts {
    struct Draft: Identifiable, Codable {
        var id: String
        var clips: [Clip]
        var soundOf: UUID?
        var saved: Date
        /// The frame's shape and fill (Stage A2; older drafts have none: the first clip's, filled).
        var look: EditLook?
        var length: Double { ClipJoin.total(clips) }
    }

    private static let root: URL = {
        let f = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("edits", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()
    private static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    /// Every draft, newest first, its clips' files pointed at their copies in its folder.
    static func all() -> [Draft] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let found: [Draft] = dirs.compactMap { dir in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("draft.json")),
                  var draft = try? JSONDecoder().decode(Draft.self, from: d) else { return nil }
            draft.clips = draft.clips.map { var c = $0; c.source = dir.appendingPathComponent(c.source.lastPathComponent)
                if let f = c.forward { c.forward?.source = dir.appendingPathComponent(f.source.lastPathComponent) }
                return c }
            return draft.clips.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) } ? draft : nil
        }
        return found.sorted { $0.saved > $1.saved }
    }

    /// Saved (as a new draft, or over the one it was opened from): its clips' files copied in where they aren't already.
    @discardableResult
    static func save(id: String?, clips: [Clip], soundOf: UUID?, look: EditLook? = nil, tidy: Bool = true) -> String {
        let id = id ?? UUID().uuidString.lowercased()
        let dir = folder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var kept: [Clip] = []
        var copied: [URL: URL] = [:]   // a file used by two clips (a split, a copy) copied once
        func keep(_ u: URL) -> URL {
            guard u.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL else { return u }
            if let done = copied[u] { return done }
            // named after where it came from, so saving again as the edit goes (auto-save) doesn't copy it again
            let to = dir.appendingPathComponent(name(for: u))
            if FileManager.default.fileExists(atPath: to.path) || (try? FileManager.default.copyItem(at: u, to: to)) != nil { copied[u] = to; return to }
            return u
        }
        for var c in clips {
            c.source = keep(c.source)
            // a reversed clip's file the right way round too, to turn it back
            if let f = c.forward { c.forward?.source = keep(f.source) }
            kept.append(c)
        }
        // only the file names go in: the folder moves with the app's own place on the phone
        let stored = kept.map { var c = $0; c.source = URL(fileURLWithPath: c.source.lastPathComponent)
            if let f = c.forward { c.forward?.source = URL(fileURLWithPath: f.source.lastPathComponent) }
            return c }
        if let d = try? JSONEncoder().encode(Draft(id: id, clips: stored, soundOf: soundOf, saved: Date(), look: look)) {
            try? d.write(to: dir.appendingPathComponent("draft.json"), options: .atomic)
        }
        // files no clip uses any more (one deleted from the edit) let go; not while it's auto-saved (Discard may go back to them)
        guard tidy else { return id }
        let used = Set(kept.map { $0.source.lastPathComponent } + kept.compactMap { $0.forward?.source.lastPathComponent } + ["draft.json"])
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where !used.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
        return id
    }

    /// One after another, off the main thread: auto-saves, and Save or Discard after them, in the order asked.
    static let queue = DispatchQueue(label: "edit-drafts", qos: .utility)

    private static func name(for source: URL) -> String {
        let hash = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return hash + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension)
    }

    static func delete(_ id: String) { try? FileManager.default.removeItem(at: folder(id)) }
}
