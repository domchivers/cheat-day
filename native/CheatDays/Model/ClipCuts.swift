import Foundation

/// The video's own captions as its clips are trimmed (22 Nov audit: the words outside every clip were dropped for
/// good): what's trimmed off is kept beside the edit and comes back as a clip's drawn out again, as a voiceover's does.
enum ClipCuts {
    /// Where a word said in a clip is now: the clip it was said in, or another of the same file (a split's other half).
    static func clip(for w: EditText.Word, in clips: [Clip]) -> Int? {
        guard let src = w.src else { return nil }
        func inside(_ c: Clip) -> Bool {
            // (played backwards, a clip keeps its id: its file's moments aren't the words' any more)
            if let file = w.file, let f = c.forward, f.source.lastPathComponent == file { return false }
            return src >= c.start - 0.01 && src < c.end
        }
        if let i = clips.firstIndex(where: { (c: Clip) -> Bool in c.id == w.clip && inside(c) }) { return i }
        guard let file = w.file else { return nil }
        return clips.firstIndex { (c: Clip) -> Bool in c.source.lastPathComponent == file && inside(c) }
    }

    /// The captions with these clips, and what's off the ends of them: every word that was kept back in, then those
    /// with nowhere to play kept again.
    static func trimmed(_ texts: [EditText], kept: [EditText], clips: [Clip], sounds: [EditSound]) -> (texts: [EditText], kept: [EditText]) {
        let soundIDs: Set<UUID> = Set(sounds.map { (s: EditSound) -> UUID in s.id })
        var all: [EditText] = texts
        var back: Set<UUID> = []
        for old in kept {
            var k: EditText = old
            // what switched it off has gone: it's on
            if let v = k.under, !soundIDs.contains(v) { k.under = nil; k.hidden = nil }
            if CaptionLayers.restore(k, into: &all) { back.insert(k.id) }
        }
        var out: [EditText] = []
        for t in all where t.kind == "caption" {
            guard let words = t.words, !words.isEmpty, words.allSatisfy({ (w: EditText.Word) -> Bool in w.src != nil }) else { continue }
            let lost: [EditText.Word] = words.filter { (w: EditText.Word) -> Bool in
                if let id = w.clip, soundIDs.contains(id) { return false }   // (a sound keeps its own: EditSound.cut)
                // (one tied to no file or clip can't come back)
                guard w.clip != nil || w.file != nil else { return false }
                return clip(for: w, in: clips) == nil
            }
            guard !lost.isEmpty else { continue }
            var c: EditText = t
            c.words = lost
            if lost.count < words.count { c.text = CaptionLayers.joined(lost) }
            out.append(c)
        }
        var placed: [EditText] = EditOverlays.reanchor(all, clips: clips, sounds: sounds)
        // (put back by the moment in its file: said in the order it plays)
        for i in placed.indices where back.contains(placed[i].id) {
            if let words = placed[i].words { placed[i].text = CaptionLayers.joined(words) }
        }
        return (placed, out)
    }

    /// The words' files by the names those files have now: a draft keeps its clips' files under names of its own,
    /// and a reopened draft's split clips lost their captions on the next change.
    static func renamed(_ texts: [EditText], names: [String: String]) -> [EditText] {
        texts.map { (t: EditText) -> EditText in
            guard let words = t.words else { return t }
            var out: EditText = t
            out.words = words.map { (w: EditText.Word) -> EditText.Word in
                guard let file = w.file, let name = names[file] else { return w }
                var x: EditText.Word = w
                x.file = name
                return x
            }
            return out
        }
    }

    /// A draft from before its words' files were renamed with it: told by the clip each was said in.
    static func linked(_ texts: [EditText], clips: [Clip]) -> [EditText] {
        var known: Set<String> = []
        var byClip: [UUID: String] = [:]
        for c in clips {
            known.insert(c.source.lastPathComponent)
            if let f = c.forward { known.insert(f.source.lastPathComponent) } else { byClip[c.id] = c.source.lastPathComponent }
        }
        return texts.map { (t: EditText) -> EditText in
            guard let words = t.words else { return t }
            var out: EditText = t
            out.words = words.map { (w: EditText.Word) -> EditText.Word in
                guard let file = w.file, !known.contains(file), let id = w.clip, let name = byClip[id] else { return w }
                var x: EditText.Word = w
                x.file = name
                return x
            }
            return out
        }
    }
}
