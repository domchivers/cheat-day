import AVFoundation
import UIKit

/// A template's song and its beats: the same for what plays as it's filled and for what's made.
struct TemplateMusic {
    var song: EditSound
    /// The beats, seconds into the part that plays.
    var beats: [Double]

    static func load(_ t: EditTemplate) async -> TemplateMusic? {
        guard let s = Music.all.first(where: { (x: Song) -> Bool in x.id == t.song }) else { return nil }
        guard let mix = await SongMix.make(s, song: 1, clip: 1) else { return nil }
        let found: [Double] = await Beats.find(mix.file, from: mix.from, length: mix.span)
        var made = EditSound(kind: "song", name: s.title, file: mix.file, from: 0, start: mix.from, length: mix.span,
                             full: mix.from + mix.span, beats: found)
        made.loopFrom = mix.from
        made.toEnd = true
        made.fadeOut = min(1.2, mix.span / 4)
        return TemplateMusic(song: made, beats: found.map { (b: Double) -> Double in b - mix.from })
    }
}

/// A template as it's filled so far, cut as Make it will cut it (design/templates-pro-mockup.html: the video plays as
/// it's filled, so it has to be the one that's made).
struct TemplateCut: Equatable {
    var clips: [Clip] = []
    var words: [EditText] = []
    var sounds: [EditSound] = []
    var pips: [EditPip] = []
    /// The captions' words with nowhere to play in it, kept.
    var cutWords: [EditText] = []
    /// Which slot each clip is.
    var slots: [Int] = []
    var total = 0.0

    /// The filled slots' clips, each starting where it was chosen to, one used twice a copy of its own.
    static func picked(library: [Clip], filled: [UUID?], moments: [Int: Double]) -> (clips: [Clip], slots: [Int]) {
        var out: [Clip] = [], at: [Int] = []
        var seen: Set<UUID> = []
        // (a copy made by the template before this one can be among them)
        var taken: Set<UUID> = Set(library.map { (x: Clip) -> UUID in x.id })
        for (i, id) in filled.enumerated() {
            guard let id, var c = library.first(where: { (x: Clip) -> Bool in x.id == id }) else { continue }
            if !seen.insert(id).inserted {
                var other: UUID = copy(of: id, slot: i)
                while taken.contains(other) { other = copy(of: other, slot: i) }
                taken.insert(other)
                c.id = other
            }
            if let start = moments[i] {
                c.start = min(max(0, start), max(0, c.length - 0.05))
                c.end = c.length
                // (the sound's trim was of the part it played before)
                c.soundStart = nil
                c.soundEnd = nil
            }
            out.append(c)
            at.append(i)
        }
        return (out, at)
    }

    /// The edit's clips into the slots to start with, in order: fewer clips than slots, the longer ones again at moments
    /// further along them, as many as they've two seconds for (23 Nov: one long clip filled one slot, and Make it
    /// made two seconds of video).
    static func spread(library: [Clip], slots count: Int) -> (filled: [UUID?], moments: [Int: Double]) {
        var filled: [UUID?] = Array(repeating: nil, count: max(0, count))
        var moments: [Int: Double] = [:]
        let clips: [Clip] = Array(library.prefix(max(0, count)))
        guard !clips.isEmpty else { return (filled, moments) }
        var times: [Int] = Array(repeating: 1, count: clips.count)
        var spare: Int = count - clips.count
        while spare > 0 {
            var best: Int?
            var longest: Double = 0
            for (i, c) in clips.enumerated() where !c.still {
                guard c.duration >= Double(times[i] + 1) * 2 else { continue }
                let each: Double = c.duration / Double(times[i])
                if each > longest {
                    longest = each
                    best = i
                }
            }
            guard let best else { break }
            times[best] += 1
            spare -= 1
        }
        var slot = 0
        for (i, c) in clips.enumerated() {
            for k in 0..<times[i] {
                filled[slot] = c.id
                if times[i] > 1 { moments[slot] = c.start + c.duration * Double(k) / Double(times[i]) }
                slot += 1
            }
        }
        return (filled, moments)
    }

    /// The same id for the same copy each time it's cut again, so the preview isn't started again for it.
    static func copy(of id: UUID, slot: Int) -> UUID {
        var bytes: uuid_t = id.uuid
        bytes.15 = bytes.15 &+ UInt8(truncatingIfNeeded: slot + 1)
        bytes.14 = bytes.14 ^ 0xA5
        return UUID(uuid: bytes)
    }

    static func make(_ t: EditTemplate, library: [Clip], filled: [UUID?], moments: [Int: Double],
                     slots: [EditTemplate.Slot], music: TemplateMusic?, carry: EditCarry? = nil) -> TemplateCut {
        let chosen: (clips: [Clip], slots: [Int]) = picked(library: library, filled: filled, moments: moments)
        var clips: [Clip] = [], kept: [EditTemplate.Slot] = [], at: [Int] = []
        for (n, i) in chosen.slots.enumerated() where slots.indices.contains(i) {
            clips.append(chosen.clips[n])
            kept.append(slots[i])
            at.append(i)
        }
        guard !clips.isEmpty else { return TemplateCut() }

        var out = TemplateCut()
        out.clips = EditTemplate.lay(clips, slots: kept, beats: music?.beats ?? [], join: t.join, look: t.look)
        out.slots = at
        out.total = ClipJoin.total(out.clips)
        var over: [EditText] = []
        if let carry {
            let stays: EditCarry = carry.kept(on: out.clips)
            over = stays.texts
            out.sounds = stays.sounds
            out.pips = stays.pips
            out.cutWords = stays.cut
        }
        if var song = music?.song {
            song.length = max(0.5, out.total)
            out.sounds.append(song)
        }
        var words: [EditText] = EditTemplate.labels(out.clips, slots: kept)
        for i in words.indices { words[i].id = label(i) }
        out.words = over + words
        return out
    }

    /// The preview's labels keep their ids as they're cut again.
    private static func label(_ i: Int) -> UUID {
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        bytes.0 = 0x7E
        bytes.15 = UInt8(truncatingIfNeeded: i)
        return UUID(uuid: bytes)
    }

    /// Where a slot's clip starts in it; nil for an empty slot.
    func start(of slot: Int) -> Double? {
        guard let n = slots.firstIndex(of: slot) else { return nil }
        let starts: [Double] = ClipJoin.starts(clips)
        return starts.indices.contains(n) ? starts[n] : nil
    }

    /// How long a slot shows: till the next one starts.
    func shows(_ slot: Int) -> Double? {
        guard let n = slots.firstIndex(of: slot) else { return nil }
        let starts: [Double] = ClipJoin.starts(clips)
        guard starts.indices.contains(n) else { return nil }
        let next: Double = n + 1 < starts.count ? starts[n + 1] : total
        return next - starts[n]
    }

    /// A slot's clip as it's cut.
    func clip(of slot: Int) -> Clip? {
        guard let n = slots.firstIndex(of: slot), clips.indices.contains(n) else { return nil }
        return clips[n]
    }
}

/// The templates' cards, going round their slots.
enum TemplateReel {
    static let rate = 10.0      // pictures a second

    /// How long a template runs, about: half a second a beat.
    static func length(_ slots: [EditTemplate.Slot]) -> Double {
        Double(slots.reduce(0) { (sum: Int, s: EditTemplate.Slot) -> Int in sum + max(1, s.beats) }) * 0.5
    }

    /// The slot showing at a moment, how far into it, and how far through the whole.
    static func at(_ seconds: Double, slots: [EditTemplate.Slot]) -> (slot: Int, into: Double, through: Double) {
        let whole: Double = length(slots)
        guard whole > 0 else { return (0, 0, 0) }
        let t: Double = seconds - (seconds / whole).rounded(.down) * whole
        var start = 0.0
        for (i, s) in slots.enumerated() {
            let lasts: Double = Double(max(1, s.beats)) * 0.5
            if t < start + lasts { return (i, t - start, t / whole) }
            start += lasts
        }
        return (slots.count - 1, 0, 1)
    }

}
