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
        var length: Double { clips.reduce(0) { $0 + $1.duration } }
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
            draft.clips = draft.clips.map { var c = $0; c.source = dir.appendingPathComponent(c.source.lastPathComponent); return c }
            return draft.clips.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) } ? draft : nil
        }
        return found.sorted { $0.saved > $1.saved }
    }

    /// Saved (as a new draft, or over the one it was opened from): its clips' files copied in where they aren't already.
    @discardableResult
    static func save(id: String?, clips: [Clip], soundOf: UUID?) -> String {
        let id = id ?? UUID().uuidString.lowercased()
        let dir = folder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var kept: [Clip] = []
        var copied: [URL: URL] = [:]   // a file used by two clips (a split, a copy) copied once
        for var c in clips {
            if c.source.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL {
                if let done = copied[c.source] { c.source = done }
                else {
                    let to = dir.appendingPathComponent(UUID().uuidString + "." + (c.source.pathExtension.isEmpty ? "mov" : c.source.pathExtension))
                    if (try? FileManager.default.copyItem(at: c.source, to: to)) != nil { copied[c.source] = to; c.source = to }
                }
            }
            kept.append(c)
        }
        // only the file names go in: the folder moves with the app's own place on the phone
        let stored = kept.map { var c = $0; c.source = URL(fileURLWithPath: c.source.lastPathComponent); return c }
        if let d = try? JSONEncoder().encode(Draft(id: id, clips: stored, soundOf: soundOf, saved: Date())) {
            try? d.write(to: dir.appendingPathComponent("draft.json"), options: .atomic)
        }
        // files no clip uses any more (one deleted from the edit) let go
        let used = Set(kept.map { $0.source.lastPathComponent } + ["draft.json"])
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where !used.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
        return id
    }

    static func delete(_ id: String) { try? FileManager.default.removeItem(at: folder(id)) }
}
