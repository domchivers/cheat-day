import Foundation

/// The clip editor's captions in layers (22 Nov, design/voiceover-caption-layers-mockup.html): the video's own, and
/// each voiceover's. A voiceover captioned switches off the video's own under it, kept on a row of their own, and its
/// captions go on the row below it; each row's eye switches it back.
enum CaptionLayers {
    /// The voiceovers among the sounds (a sound separated from its clip is the video's own talking).
    static func voiceIDs(_ sounds: [EditSound]) -> Set<UUID> {
        var out: Set<UUID> = []
        for s in sounds where s.kind == "voice" { out.insert(s.id) }
        return out
    }

    /// The voiceover a caption's of; nil, the video's own. (One from before layers is told by where its words were said.)
    static func track(_ t: EditText, voices: Set<UUID>) -> UUID? {
        if let v = t.voice { return v }
        for w in t.words ?? [] {
            if let id = w.clip, voices.contains(id) { return id }
        }
        return nil
    }

    /// The video's own captions.
    static func own(_ texts: [EditText], voices: Set<UUID>) -> [EditText] {
        texts.filter { (t: EditText) -> Bool in t.kind == "caption" && track(t, voices: voices) == nil }
    }

    /// A voiceover's captions.
    static func spoken(_ texts: [EditText], by voice: UUID, voices: Set<UUID>) -> [EditText] {
        texts.filter { (t: EditText) -> Bool in t.kind == "caption" && track(t, voices: voices) == voice }
    }

    /// A voiceover's captions as they're to be: marked as its own, none running on past it, in the video's captions'
    /// look when it had none of its own.
    static func stamped(_ caps: [EditText], voice v: EditSound, like: EditText?) -> [EditText] {
        caps.map { (cap: EditText) -> EditText in
            var c = cap
            c.voice = v.id
            c.to = max(c.from + 0.1, min(c.to, v.to))
            if let like { c.takeLook(from: like) }
            return c
        }
    }

    /// The video's own captions under a voiceover switched off, one that runs across either end of it cut there
    /// between words. `only`: just these.
    static func cover(_ texts: [EditText], by v: EditSound, voices: Set<UUID>, only: Set<UUID>? = nil) -> [EditText] {
        var out: [EditText] = []
        for t in texts {
            let mine: Bool = only?.contains(t.id) ?? true
            let over: Double = min(t.to, v.to) - max(t.from, v.from)
            guard mine, t.kind == "caption", t.hidden != true, over > 0.05, track(t, voices: voices) == nil else { out.append(t); continue }
            let words: [EditText.Word] = t.words ?? []
            guard !words.isEmpty else {
                var c = t
                c.hidden = true; c.under = v.id
                out.append(c)
                continue
            }
            // runs of words before it (0), under it (1) and after it (2)
            var runs: [(side: Int, words: [EditText.Word])] = []
            for w in words {
                let side: Int = w.at < v.from - 0.01 ? 0 : (w.at < v.to - 0.01 ? 1 : 2)
                if let last = runs.last, last.side == side { runs[runs.count - 1].words.append(w) } else { runs.append((side: side, words: [w])) }
            }
            for (n, run) in runs.enumerated() {
                var c = t
                if runs.count > 1 {
                    if n > 0 { c.id = UUID(); c.from = run.words[0].at }
                    if n + 1 < runs.count { c.to = runs[n + 1].words[0].at }
                    c.words = run.words
                    c.text = run.words.map { (w: EditText.Word) -> String in w.text }.joined(separator: " ")
                }
                if run.side == 0 { c.to = max(c.from + 0.1, min(c.to, v.from)) }
                if run.side == 2 { c.from = max(c.from, v.to); c.to = max(c.from + 0.1, c.to) }
                if run.side == 1 { c.hidden = true; c.under = v.id }
                out.append(c)
            }
        }
        return out
    }

    /// What a voiceover switched off, on again.
    static func uncover(_ texts: [EditText], from voice: UUID) -> [EditText] {
        texts.map { (t: EditText) -> EditText in
            guard t.under == voice else { return t }
            var c = t
            c.hidden = nil; c.under = nil
            return c
        }
    }

    /// A voiceover (or the clips under it) moved: what it switches off is what's under it now. Not once its row's
    /// been switched back on by its eye.
    static func settled(_ texts: [EditText], sounds: [EditSound]) -> [EditText] {
        let voices = voiceIDs(sounds)
        var out = texts
        for v in sounds where v.kind == "voice" {
            let holds: Bool = out.contains { (t: EditText) -> Bool in t.under == v.id && t.hidden == true }
            if holds { out = cover(uncover(out, from: v.id), by: v, voices: voices) }
        }
        return out
    }

    /// A voiceover taken off: its captions with it, and what it had switched off on again (but under another that's
    /// captioned). `sounds`: as they were, it among them.
    static func removed(_ voice: UUID, texts: [EditText], sounds: [EditSound]) -> [EditText] {
        let voices = voiceIDs(sounds)
        var released: Set<UUID> = []
        for t in texts where t.under == voice { released.insert(t.id) }
        var out = uncover(texts, from: voice).filter { (t: EditText) -> Bool in t.kind != "caption" || track(t, voices: voices) != voice }
        for v in sounds where v.kind == "voice" && v.id != voice {
            if !spoken(out, by: v.id, voices: voices).isEmpty { out = cover(out, by: v, voices: voices, only: released) }
        }
        return out
    }

    /// A voiceover (or a clip's separated sound) moved or trimmed: its captions where their words now play. Those of what's trimmed off are kept on
    /// it and come back as it's drawn out again (22 Nov recording: let go a moment short of "hello", that caption was
    /// gone for good).
    static func trimmed(_ texts: [EditText], clips: [Clip], sounds: [EditSound]) -> (texts: [EditText], sounds: [EditSound]) {
        var all: [EditText] = texts
        for v in sounds {
            for kept in v.cut ?? [] { restore(kept, into: &all) }
        }
        var laid: [EditSound] = sounds
        for k in laid.indices where laid[k].kind == "voice" || laid[k].kind == "clip" {
            let cut: [EditText] = trimmedOff(all, of: laid[k])
            laid[k].cut = cut.isEmpty ? nil : cut
        }
        return (EditOverlays.reanchor(all, clips: clips, sounds: laid), laid)
    }

    /// What of the captions is outside the part of a voiceover that plays.
    private static func trimmedOff(_ texts: [EditText], of v: EditSound) -> [EditText] {
        let low: Double = v.start - 0.01, high: Double = v.fileTime(v.to) + 0.01
        var out: [EditText] = []
        for t in texts where t.kind == "caption" {
            guard let words = t.words, words.allSatisfy({ (w: EditText.Word) -> Bool in w.src != nil }) else { continue }
            let lost: [EditText.Word] = words.filter { (w: EditText.Word) -> Bool in
                guard w.clip == v.id, let at = w.src else { return false }
                return at < low || at > high
            }
            guard !lost.isEmpty else { continue }
            var c: EditText = t
            c.words = lost
            if lost.count < words.count { c.text = joined(lost) }   // (all of it: as it was typed)
            out.append(c)
        }
        return out
    }

    /// Words trimmed off put back in their caption, or their caption back when all of it went.
    @discardableResult
    static func restore(_ kept: EditText, into all: inout [EditText]) -> Bool {
        guard let i = all.firstIndex(where: { (t: EditText) -> Bool in t.id == kept.id }) else { all.append(kept); return true }
        var words: [EditText.Word] = all[i].words ?? []
        var added = false
        for w in kept.words ?? [] {
            let there: Bool = words.contains { (x: EditText.Word) -> Bool in x.src == w.src && x.clip == w.clip }
            if !there { words.append(w); added = true }
        }
        guard added else { return false }
        words.sort { (a: EditText.Word, b: EditText.Word) -> Bool in (a.src ?? 0) < (b.src ?? 0) }
        all[i].words = words
        all[i].text = joined(words)
        return true
    }

    static func joined(_ words: [EditText.Word]) -> String {
        words.map { (w: EditText.Word) -> String in w.text }.joined(separator: " ")
    }

    /// Captions in one layer don't run over the next in it; in different layers they may.
    static func clamped(_ texts: [EditText], voices: Set<UUID>) -> [EditText] {
        var out = texts
        var layers: [UUID?: [Int]] = [:]
        for i in out.indices where out[i].kind == "caption" { layers[track(out[i], voices: voices), default: []].append(i) }
        for (_, layer) in layers {
            let order: [Int] = layer.sorted { (a: Int, b: Int) -> Bool in out[a].from < out[b].from }
            for (a, b) in zip(order, order.dropFirst()) where out[a].to > out[b].from {
                out[a].to = max(out[a].from + 0.1, out[b].from)
            }
        }
        return out
    }

    /// What's drawn, in the preview and the finished video: nothing switched off; and where both layers are on at
    /// once, the video's own just above the voiceover's, so neither's drawn over the other.
    static func placed(_ texts: [EditText], sounds: [EditSound]) -> [EditText] {
        let shown: [EditText] = texts.filter { (t: EditText) -> Bool in t.hidden != true }
        let voices = voiceIDs(sounds)
        guard !voices.isEmpty else { return shown }
        let theirs: [EditText] = shown.filter { (t: EditText) -> Bool in t.kind == "caption" && track(t, voices: voices) != nil }
        guard !theirs.isEmpty else { return shown }
        return shown.map { (t: EditText) -> EditText in
            guard t.kind == "caption", t.byHand != true, track(t, voices: voices) == nil else { return t }
            var c = t
            for o in theirs where min(o.to, t.to) - max(o.from, t.from) > 0.01 && abs(o.y - c.y) < 0.1 {
                // ("1": one line each)
                let oneLine: Bool = o.detail == "1" && t.detail == "1"
                let room: Double = (oneLine ? 0.1 : 0.13) * max(1, max(o.size, t.size))
                c.y = o.y - room >= 0.05 ? o.y - room : o.y + room
            }
            return c
        }
    }

    /// The timeline's rows with the captions put in their layers: the video's own where the captions were (over every
    /// voiceover), those switched off just under them, and each voiceover's just under it. The rest keep their order.
    /// `live`: what's on the rows that isn't a caption; anything else on them is one, perhaps one that's gone.
    static func rows(_ before: [[UUID]], texts: [EditText], sounds: [EditSound], live: Set<UUID>) -> [[UUID]] {
        let voices = voiceIDs(sounds)
        var on: [UUID] = [], off: [UUID] = []
        var said: [UUID: [UUID]] = [:]
        for t in texts where t.kind == "caption" {
            if let v = track(t, voices: voices), voices.contains(v) { said[v, default: []].append(t.id) }
            else if t.hidden == true { off.append(t.id) }
            else { on.append(t.id) }
        }
        let top: Int = before.firstIndex { (row: [UUID]) -> Bool in
            row.contains { (id: UUID) -> Bool in !live.contains(id) || voices.contains(id) }
        } ?? 0

        var out: [[UUID]] = []
        for (r, row) in before.enumerated() {
            if r == top { out.append(on); out.append(off) }
            out.append(row.filter { (id: UUID) -> Bool in live.contains(id) })
            var below: [UUID] = []
            for id in row { below += said[id] ?? [] }
            out.append(below)
        }
        if before.isEmpty { out.append(on); out.append(off) }
        return out.filter { (row: [UUID]) -> Bool in !row.isEmpty }
    }
}
