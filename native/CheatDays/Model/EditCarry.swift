import Foundation

/// What's over the clips, put with them as the clips change: the editor's own, and what a template keeps of the edit,
/// so what plays as it's filled has all that Make it will leave in.
struct EditCarry {
    var clips: [Clip] = []
    var texts: [EditText] = []
    var sounds: [EditSound] = []
    var pips: [EditPip] = []
    var cut: [EditText] = []
    var recipe: JSON?
    var plan = EditOverlays.RecipePlan()

    /// Moved to these clips: captions with their words, everything else as far as the clip it starts over.
    func moved(to new: [Clip]) -> EditCarry {
        var out: EditCarry = self
        out.clips = new
        guard !clips.isEmpty, !new.isEmpty else { return out }
        let was: [Double] = ClipJoin.starts(clips)
        let starts: [Double] = ClipJoin.starts(new)
        var at: [UUID: Double] = [:]
        for (i, c) in new.enumerated() { at[c.id] = starts[i] }
        let old: [Clip] = clips
        // how far the clip under a moment has moved (nothing for one taken out)
        let shift: (Double) -> Double = { (t: Double) -> Double in
            guard let i = was.lastIndex(where: { (s: Double) -> Bool in s <= t + 0.001 }), let n = at[old[i].id] else { return 0 }
            return n - was[i]
        }
        // captions go with their words (21 Nov): each word tied to the clip and moment it was said in, then put
        // where that now plays; trimmed-out words go
        var words: [EditText] = EditOverlays.anchor(texts, clips: old)
        for k in words.indices where words[k].part != "recipe" {
            let t: EditText = words[k]
            if t.kind == "caption", let said = t.words, !said.isEmpty,
               said.allSatisfy({ (w: EditText.Word) -> Bool in w.src != nil }) { continue }
            let d: Double = shift(t.from)
            guard abs(d) > 0.0005 else { continue }
            words[k].from = max(0, t.from + d)
            words[k].to = max(words[k].from + 0.1, t.to + d)
            if let said = t.words {
                words[k].words = said.map { (w: EditText.Word) -> EditText.Word in EditText.Word(text: w.text, at: max(0, w.at + d)) }
            }
        }
        for k in sounds.indices where sounds[k].kind != "song" {
            let d: Double = shift(sounds[k].from)
            if abs(d) > 0.0005 { out.sounds[k].from = max(0, sounds[k].from + d) }
        }
        for k in pips.indices {
            let d: Double = shift(pips[k].from)
            if abs(d) > 0.0005 { out.pips[k].from = max(0, pips[k].from + d) }
        }
        // music that runs to the end of the edit still does
        let long: Double = ClipJoin.total(new)
        for k in out.sounds.indices where out.sounds[k].toEnd == true { out.sounds[k].length = max(0.3, long - out.sounds[k].from) }
        // (22 Nov audit: the words outside every clip were dropped for good: kept, and back in as it's drawn out again)
        let trimmed: (texts: [EditText], kept: [EditText]) = ClipCuts.trimmed(words, kept: cut, clips: new, sounds: out.sounds)
        out.texts = trimmed.texts
        out.cut = trimmed.kept
        return out
    }

    /// What a template leaves in, on its clips: all but the last template's words and the music it takes the place of.
    func kept(on new: [Clip]) -> EditCarry {
        var before: EditCarry = self
        before.texts = texts.filter { (t: EditText) -> Bool in t.part != "template" }
        before.sounds = sounds.filter { (s: EditSound) -> Bool in s.kind != "song" }
        var out: EditCarry = before.moved(to: new)
        out.texts = CaptionLayers.settled(out.texts, sounds: out.sounds)
        if let recipe {
            out.texts.removeAll { (t: EditText) -> Bool in
                t.part == "recipe" || (t.part == nil && (t.kind == "step" || t.kind == "macros"))
            }
            out.texts += EditOverlays.reel(recipe, clips: new, plan: plan)
        }
        return out
    }
}
