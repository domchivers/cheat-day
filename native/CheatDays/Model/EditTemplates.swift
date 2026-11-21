import Foundation

/// Templates as slots (21 Nov, design/templates-mockup.html): a ready-made video with places for clips, each with its
/// length in the song's beats and its words, taken from what's been logged (each meal and its calories, each lift and
/// its sets) so nothing on it is a made-up title. Clips picked drop into the slots and are cut to fit, on the beat.
struct EditTemplate: Identifiable, Equatable {
    let id: String, name: String, about: String, icon: String
    let song: String
    let join: String?
    let look: String
    /// Two colours for its card in the gallery, as hex.
    let tint: (String, String)

    static func == (a: EditTemplate, b: EditTemplate) -> Bool { a.id == b.id }

    /// One place for a clip: its words, and how long it lasts in beats.
    struct Slot: Equatable {
        var name: String
        var detail = ""
        var beats = 4
    }

    /// What it's made from: the day's food, a week of it, a workout, a recipe, the weigh-ins.
    struct Log {
        var today: String
        var items: [JSON] = []
        var history: [(date: String, items: [JSON])] = []
        var workouts: [JSON] = []           // newest last
        var weights: [(day: String, kg: Double)] = []   // oldest first
    }

    static let all: [EditTemplate] = [
        EditTemplate(id: "day", name: "Day of eating", about: "Each meal labelled with its calories, from today's log", icon: "sun.max",
                     song: "be-chillin", join: "Push", look: "Pop", tint: ("#FF9A3C", "#C2412D")),
        EditTemplate(id: "cheat", name: "Cheat day", about: "Fast cuts to the beat, today's total at the end", icon: "flame",
                     song: "backbeat", join: "Whip", look: "Vivid", tint: ("#8E7CFF", "#3B2F8F")),
        EditTemplate(id: "gym", name: "Gym session", about: "Each lift named with its sets and weight, from your workout", icon: "dumbbell",
                     song: "beat-one", join: "Whip", look: "Vivid", tint: ("#2FC4B2", "#1D5F8A")),
        EditTemplate(id: "recipe", name: "Recipe", about: "A saved recipe's steps, its macros at the end", icon: "fork.knife",
                     song: "city-sunshine", join: "Dissolve", look: "Warm", tint: ("#FFD26A", "#B07A1F")),
        EditTemplate(id: "before", name: "Before and after", about: "Then and now, your weights and dates on each", icon: "square.split.2x1",
                     song: "inspiration", join: "Black", look: "Normal", tint: ("#5CD18F", "#1F6E45")),
        EditTemplate(id: "week", name: "What I eat in a week", about: "A day a clip, each day's total", icon: "calendar",
                     song: "slice-of-life", join: "Slide over", look: "Warm", tint: ("#FF6B8A", "#8A1F3B")),
    ]

    /// The slots, their words from the log (and `recipe`, a saved meal as AttachPicker gives it, for the recipe one).
    /// Nothing logged: slots named for what goes in them, with no numbers.
    func slots(_ log: Log, recipe: JSON? = nil) -> [Slot] {
        switch id {
        case "day":
            var out: [Slot] = []
            for meal in Meals.all {
                let had = log.items.filter { Meals.of($0) == meal }
                guard !had.isEmpty else { continue }
                out.append(Slot(name: Self.single(meal), detail: Self.foods(had)))
            }
            return out.isEmpty ? ["Breakfast", "Lunch", "Snack", "Dinner"].map { Slot(name: $0) } : out
        case "cheat":
            let top = log.items.sorted { (num($0["kcal"]) ?? 0) > (num($1["kcal"]) ?? 0) }.prefix(5)
            guard !top.isEmpty else { return (1...5).map { _ in Slot(name: "", beats: 2) } + [Slot(name: "Today", beats: 4)] }
            let total = log.items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
            return top.map { Slot(name: str($0["name"]), detail: Self.kcal(num($0["kcal"]) ?? 0), beats: 2) }
                + [Slot(name: "Today", detail: Self.kcal(total), beats: 4)]
        case "gym":
            let lifts = list(log.workouts.last(where: { !list($0["lifts"]).isEmpty })?["lifts"])
            guard !lifts.isEmpty else { return (1...4).map { Slot(name: "Lift \($0)") } }
            return lifts.prefix(8).map { l in
                let name = str(l["exercise"]).isEmpty ? str(l["name"]) : str(l["exercise"])
                let sets = Int(num(l["sets"]) ?? 0), reps = Int(num(l["reps"]) ?? 0), kg = num(l["kg"]) ?? 0
                var d = sets > 0 && reps > 0 ? "\(sets) × \(reps)" : ""
                if kg > 0 { d += (d.isEmpty ? "" : " · ") + Fmt.int(kg) + " kg" }
                return Slot(name: name, detail: d)
            }
        case "recipe":
            guard let recipe else { return (1...4).map { Slot(name: "Step \($0)") } }
            var out = EditOverlays.steps(of: recipe).prefix(6).enumerated().map { Slot(name: "Step \($0.offset + 1)", detail: $0.element) }
            if out.isEmpty { out = [Slot(name: str(recipe["name"]))] }
            let m = recipe["macros"] as? JSON ?? [:], p = Int(num(m["p"]) ?? 0)
            out.append(Slot(name: str(recipe["name"]), detail: Self.kcal(num(recipe["kcal"]) ?? 0) + (p > 0 ? " · \(p) g protein" : "")))
            return out
        case "before":
            guard let first = log.weights.first, let last = log.weights.last, log.weights.count > 1 else {
                return [Slot(name: "Before", beats: 8), Slot(name: "Now", beats: 8)]
            }
            return [Slot(name: "Before", detail: Fmt.one(first.kg) + " kg · " + Self.day(first.day), beats: 8),
                    Slot(name: "Now", detail: Fmt.one(last.kg) + " kg · " + Self.day(last.day), beats: 8)]
        default:   // a week
            let days = ([(date: log.today, items: log.items)] + log.history)
                .filter { !$0.items.isEmpty && $0.date > DayKey.shift(log.today, days: -7) }
                .sorted { $0.date < $1.date }
            guard !days.isEmpty else { return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map { Slot(name: $0) } }
            return days.map { d in
                Slot(name: DayKey.date(d.date).formatted(.dateTime.weekday(.wide)),
                     detail: Self.kcal(d.items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }))
            }
        }
    }

    private static func single(_ meal: String) -> String { meal == "Snacks" ? "Snack" : meal }
    static func kcal(_ k: Double) -> String { "\(Int(k.rounded())) kcal" }
    private static func day(_ d: String) -> String { DayKey.date(d).formatted(.dateTime.day().month(.abbreviated)) }
    /// A meal's foods, the biggest two by name, and its calories: "Oats, Berries · 420 kcal".
    private static func foods(_ items: [JSON]) -> String {
        let names = items.sorted { (num($0["kcal"]) ?? 0) > (num($1["kcal"]) ?? 0) }.prefix(2).map { str($0["name"]) }.filter { !$0.isEmpty }
        let k = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return (names.isEmpty ? "" : names.joined(separator: ", ") + (items.count > 2 ? " +\(items.count - 2)" : "") + " · ") + kcal(k)
    }

    // MARK: laying the clips into the slots

    /// The beats as far as `count` of them: the song's own, carried on at its pace past its end; no beat found,
    /// two a second.
    static func grid(_ beats: [Double], count: Int) -> [Double] {
        var g = beats.filter { $0 >= 0 }.sorted()
        let gaps = zip(g, g.dropFirst()).map { $1 - $0 }.filter { $0 > 0.15 }.sorted()
        let step = gaps.isEmpty ? 0.5 : gaps[gaps.count / 2]
        if g.isEmpty { g = [0] }
        while g.count <= count { g.append(g.last! + step) }
        return g
    }

    /// The clips cut to their slots: slot k ends on the beat its beats add up to, each turned into the next by
    /// `join` (its overlap counted, so the cut you see lands on the beat), all in `look`. A clip starts where it
    /// starts already (Which part moves that), as far back as it must to last its slot; one too short plays whole.
    static func lay(_ clips: [Clip], slots: [Slot], beats: [Double], join: String?, look: String) -> [Clip] {
        let n = min(clips.count, slots.count)
        guard n > 0 else { return [] }
        let need = slots.prefix(n).reduce(0) { $0 + max(1, $1.beats) }
        var g = grid(beats, count: need)
        // the video starts at 0: the first slot runs from the start to its beat
        if g[0] > 0.001 { g.insert(0, at: 0) }
        var ends: [Double] = [], k = 0
        for s in slots.prefix(n) { k += max(1, s.beats); ends.append(g[min(k, g.count - 1)]) }
        let shown = ends.enumerated().map { $0.element - ($0.offset == 0 ? 0 : ends[$0.offset - 1]) }
        let fade = join == nil ? 0 : 0.4
        // each clip lasts what it shows plus its overlap with the next (which depends on both: settled in a few goes)
        var span = shown, over = Array(repeating: 0.0, count: n)
        for _ in 0..<6 {
            for i in 0..<n { over[i] = i + 1 < n ? min(fade, span[i] / 2, span[i + 1] / 2) : 0 }
            for i in 0..<n { span[i] = shown[i] + over[i] }
        }
        var out: [Clip] = []
        for i in 0..<n {
            var c = clips[i]
            let rate = max(c.speed, 0.01), want = span[i] * rate
            if c.length <= want + 0.001 {
                c.start = 0; c.end = c.length
            } else {
                c.start = min(max(0, c.start), c.length - want)
                c.end = c.start + want
            }
            if let ss = c.soundStart { c.soundStart = min(max(ss, c.start), c.end) }
            if let se = c.soundEnd { c.soundEnd = min(max(se, c.start), c.end) }
            let from = c.start, to = c.end
            c.keys = c.keys.filter { $0.at >= from && $0.at <= to }
            c.look = look
            c.transition = i + 1 < n ? join.map { ClipTransition(kind: $0, length: 0.4) } : nil
            out.append(c)
        }
        return out
    }

    /// Each slot's words over its clip, near the top, as long as the clip shows (kind "label", part "template").
    static func labels(_ clips: [Clip], slots: [Slot]) -> [EditText] {
        let starts = ClipJoin.starts(clips)
        var out: [EditText] = []
        for i in clips.indices where i < slots.count {
            let s = slots[i]
            guard !s.name.isEmpty || !s.detail.isEmpty else { continue }
            let end = i + 1 < clips.count ? starts[i + 1] : starts[i] + clips[i].span
            var t = EditText(kind: "label", text: s.name, detail: s.detail, x: 0.5, y: 0.15, from: starts[i], to: max(starts[i] + 0.3, end))
            t.part = "template"
            out.append(t)
        }
        return out
    }
}
