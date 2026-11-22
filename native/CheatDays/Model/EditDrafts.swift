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
        /// Its text, stickers and captions, and what the post's to carry (Stage B).
        var texts: [EditText]?
        var attached: Data?
        /// Its voiceovers and sound effects (Stage C).
        var sounds: [EditSound]?
        /// The clips and photos over it (Stage D).
        var pips: [EditPip]?
        /// The video's own captions of what's trimmed off its clips (ClipCuts).
        var cut: [EditText]?
        var attachedJSON: JSON? { attached.flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON } }
        var length: Double { ClipJoin.total(clips) }

        /// It couldn't be read at all.
        var unreadable: Bool { clips.isEmpty }

        /// What's missing from it, to say; nil when it's all there.
        var missing: String? {
            if unreadable { return "Its file can't be read, so it can't be opened." }
            let lostClips: Int = clips.filter { (c: Clip) -> Bool in !EditDrafts.there(c.source) }.count
            let lostSounds: Int = (sounds ?? []).filter { (s: EditSound) -> Bool in s.file.map { !EditDrafts.there($0) } ?? false }.count
            let lostPips: Int = (pips ?? []).filter { (p: EditPip) -> Bool in !EditDrafts.there(p.source) }.count
            var bits: [String] = []
            if lostClips > 0 { bits.append("\(lostClips) clip\(lostClips == 1 ? "" : "s")") }
            if lostSounds > 0 { bits.append("\(lostSounds) sound\(lostSounds == 1 ? "" : "s")") }
            if lostPips > 0 { bits.append("\(lostPips) overlay\(lostPips == 1 ? "" : "s")") }
            return bits.isEmpty ? nil : "It's missing " + bits.joined(separator: ", ") + "."
        }

        /// It without what's missing.
        var withoutMissing: Draft {
            var d: Draft = self
            d.clips = clips.filter { (c: Clip) -> Bool in EditDrafts.there(c.source) }
            d.sounds = sounds?.filter { (s: EditSound) -> Bool in s.file.map { EditDrafts.there($0) } ?? true }
            d.pips = pips?.filter { (p: EditPip) -> Bool in EditDrafts.there(p.source) }
            return d
        }
    }

    static func there(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

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
            let file: URL = dir.appendingPathComponent("draft.json")
            guard there(file) else { return nil }
            // (22 Nov audit: one that wouldn't read, or had lost a file, just vanished: it shows, marked)
            guard let d = try? Data(contentsOf: file), var draft = try? JSONDecoder().decode(Draft.self, from: d) else {
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let saved: Date = (attributes?[.modificationDate] as? Date) ?? .distantPast
                return Draft(id: dir.lastPathComponent, clips: [], soundOf: nil, saved: saved)
            }
            draft.clips = draft.clips.map { var c = $0; c.source = dir.appendingPathComponent(c.source.lastPathComponent)
                if let f = c.forward { c.forward?.source = dir.appendingPathComponent(f.source.lastPathComponent) }
                if let u = c.clean { c.clean = dir.appendingPathComponent(u.lastPathComponent) }
                return c }
            draft.sounds = draft.sounds?.map { var x = $0; if let u = x.file { x.file = dir.appendingPathComponent(u.lastPathComponent) }; return x }
            draft.pips = draft.pips?.map { var p = $0; p.source = dir.appendingPathComponent(p.source.lastPathComponent); return p }
            // (only an extra: without it the clip plays its own)
            for i in draft.clips.indices {
                if let u = draft.clips[i].clean, !there(u) { draft.clips[i].clean = nil }
                if let f = draft.clips[i].forward, !there(f.source) { draft.clips[i].forward = nil }
            }
            if let t = draft.texts { draft.texts = ClipCuts.linked(t, clips: draft.clips) }
            if let t = draft.cut { draft.cut = ClipCuts.linked(t, clips: draft.clips) }
            return draft
        }
        return found.sorted { $0.saved > $1.saved }
    }

    /// Saved (as a new draft, or over the one it was opened from): its clips' files copied in where they aren't already.
    /// False when it couldn't be saved whole; the draft that was there is left as it was then.
    @discardableResult
    static func save(id: String?, clips: [Clip], soundOf: UUID?, look: EditLook? = nil, texts: [EditText]? = nil, attached: Data? = nil,
                     sounds: [EditSound]? = nil, pips: [EditPip]? = nil, cut: [EditText]? = nil, tidy: Bool = true) -> Bool {
        let id = id ?? UUID().uuidString.lowercased()
        let dir = folder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var kept: [Clip] = []
        var copied: [URL: URL] = [:]   // a file used by two clips (a split, a copy) copied once
        var names: [String: String] = [:]   // each file's name here, by the name it had
        var whole = true
        func keep(_ u: URL) -> URL {
            guard u.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL else { return u }
            if let done = copied[u] { return done }
            // named after where it came from, so saving again as the edit goes (auto-save) doesn't copy it again
            let to = dir.appendingPathComponent(name(for: u))
            if there(to) || (try? FileManager.default.copyItem(at: u, to: to)) != nil {
                copied[u] = to
                names[u.lastPathComponent] = to.lastPathComponent
                return to
            }
            whole = false
            return u
        }
        for var c in clips {
            c.source = keep(c.source)
            // a reversed clip's file the right way round too, to turn it back
            if let f = c.forward { c.forward?.source = keep(f.source) }
            if let u = c.clean { c.clean = keep(u) }
            kept.append(c)
        }
        // only the file names go in: the folder moves with the app's own place on the phone
        let stored = kept.map { var c = $0; c.source = URL(fileURLWithPath: c.source.lastPathComponent)
            if let f = c.forward { c.forward?.source = URL(fileURLWithPath: f.source.lastPathComponent) }
            if let u = c.clean { c.clean = URL(fileURLWithPath: u.lastPathComponent) }
            return c }
        // a voiceover's recording kept with it, by name
        let takes: [EditSound]? = sounds.map { all in all.map { var x = $0; if let u = x.file { x.file = URL(fileURLWithPath: keep(u).lastPathComponent) }; return x } }
        let over: [EditPip]? = pips.map { all in all.map { var p = $0; p.source = URL(fileURLWithPath: keep(p.source).lastPathComponent); return p } }
        // (a file that wouldn't copy: a draft pointing at nothing isn't written over a good one)
        guard whole else { return false }
        let said: [EditText]? = texts.map { (all: [EditText]) -> [EditText] in ClipCuts.renamed(all, names: names) }
        let kept0: [EditText]? = cut.map { (all: [EditText]) -> [EditText] in ClipCuts.renamed(all, names: names) }
        let laid: [EditSound]? = takes.map { (all: [EditSound]) -> [EditSound] in
            all.map { (s: EditSound) -> EditSound in
                var x: EditSound = s
                if let c = s.cut { x.cut = ClipCuts.renamed(c, names: names) }
                return x
            }
        }
        var draft = Draft(id: id, clips: stored, soundOf: soundOf, saved: Date(), look: look, texts: said, attached: attached, sounds: laid, pips: over)
        draft.cut = kept0
        do {
            try JSONEncoder().encode(draft).write(to: dir.appendingPathComponent("draft.json"), options: .atomic)
        } catch {
            return false
        }
        // files no clip uses any more (one deleted from the edit) let go; not while it's auto-saved (Discard may go back to them)
        guard tidy else { return true }
        var used: Set<String> = ["draft.json"]
        for c in kept {
            used.insert(c.source.lastPathComponent)
            if let f = c.forward { used.insert(f.source.lastPathComponent) }
            if let u = c.clean { used.insert(u.lastPathComponent) }
        }
        for x in takes ?? [] { if let u = x.file { used.insert(u.lastPathComponent) } }
        for p in over ?? [] { used.insert(p.source.lastPathComponent) }
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where !used.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
        return true
    }

    /// One after another, off the main thread: auto-saves, and Save or Discard after them, in the order asked.
    static let queue = DispatchQueue(label: "edit-drafts", qos: .utility)

    private static func name(for source: URL) -> String {
        let hash = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return hash + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension)
    }

    static func delete(_ id: String) { try? FileManager.default.removeItem(at: folder(id)) }

    /// A shared edit's draft let go, unless it's been saved again since it was shared (opened again while it went up).
    static func delete(_ id: String, sharedAt: Date) {
        let file: URL = folder(id).appendingPathComponent("draft.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        if let saved = attributes?[.modificationDate] as? Date, saved > sharedAt { return }
        delete(id)
    }
}
