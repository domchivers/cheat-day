import Foundation

/// Keeping a photo estimate steady over a conversation. Amor Roma's tiramisu went 170 g, 75 g, 120 g and 70 g over four
/// messages about the same two photos, and the 150 g box weight they gave was put aside for a guess from a hand in the
/// photo. Each part keeps the range of grams it could be (the AI writes it in the part's size: "range 60–120 g"); a
/// follow-up can only narrow it, a weight or count they give fixes it, and asking again with nothing new changes nothing.
extension Assistant {
    /// How far either side of a weight they gave the part may later move.
    static let lockedSlack = 0.1

    /// The range written in a part's size ("range 60–120 g; 10 × ~8 g pieces, against the saucer"), or nil.
    static func range(inSize size: String) -> (low: Double, high: Double)? {
        let pattern = #"range\s*(?:of\s*)?(?:about\s*|~\s*)?(\d+(?:\.\d+)?)\s*(?:g\s*)?(?:–|-|—|to)\s*(\d+(?:\.\d+)?)\s*g\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = rx.firstMatch(in: size, range: NSRange(size.startIndex..., in: size)),
              let a = Range(m.range(at: 1), in: size).flatMap({ Double(size[$0]) }),
              let b = Range(m.range(at: 2), in: size).flatMap({ Double(size[$0]) }), a > 0, b >= a else { return nil }
        return (a, b)
    }

    /// A weight or a count in what they said ("box was around 150 g", "I had 10", "6 pieces"): numbers that outrank
    /// anything judged from a photo. A size ("pieces about 1.5 cm") isn't one: it narrows the range, it doesn't fix it.
    static func givesAmount(_ said: String) -> Bool {
        let t = said.lowercased()
        let patterns = [#"\d+(\.\d+)?\s*(g|gm|gms|grams?|kg|kilos?|ml|millilitres?|milliliters?|oz|ounces?)\b"#,
                        #"\d+\s*(pieces?|pcs|bites?|balls?|squares?|slices?|cubes?|of them|out of)\b"#,
                        #"\b(had|ate|eaten|eat|have|having|only|just)\s+(about\s+|around\s+|like\s+)?\d+\b"#]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// Asking again with nothing new ("check again", "are you sure?", "recheck"): the estimate stays as it was.
    static func asksAgainOnly(_ said: String) -> Bool {
        let t = said.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard t.count <= 40, t.range(of: #"\d"#, options: .regularExpression) == nil else { return false }
        return t.range(of: #"^(can you |could you |please |pls |hmm |um )?(re-?check|check( it| that| this)? again|double.?check( it| that| this)?|are you sure|look again|try again|again)( please| pls)?$"#,
                       options: .regularExpression) != nil
    }

    /// A food's size in metres ("pieces about 1.5 m"): almost certainly cm. The size they meant, as a question, or nil.
    static func unitQuestion(_ said: String) -> String? {
        let t = said.lowercased()
        guard let r = t.range(of: #"(\d+(\.\d+)?)\s?(m|metres?|meters?)\b"#, options: .regularExpression) else { return nil }
        let figure = String(t[r]).prefix { $0.isNumber || $0 == "." }
        guard let v = Double(figure), v > 0, v < 10 else { return nil }
        return "Did you mean \(figure) cm?"
    }

    /// The new card's part that is this earlier one: the same name, or one that sounds like it.
    private static func earlier(_ p: JSON, in old: [JSON]) -> JSON? {
        let name = str(p["name"]).lowercased()
        return old.first { str($0["name"]).lowercased() == name }
            ?? old.first { soundsLike(str($0["name"]), Set(FoodTable.words(str(p["name"])))) }
    }

    /// A part at other grams, its numbers scaled with it.
    private static func regrammed(_ p: JSON, to g: Double) -> JSON {
        guard let was = pos(p["grams"]), abs(was - g) >= 0.5 else { return p }
        let f = g / was
        var x = p
        x["grams"] = g.rounded()
        x["kcal"] = ((num(p["kcal"]) ?? 0) * f).rounded()
        for k in ["protein_g", "carbs_g", "fat_g"] { if let v = num(p[k]) { x[k] = v * f } }
        return x
    }

    /// The estimate held to what came before: each part's range kept (narrowed when the new one fits inside it), a
    /// locked part left where their numbers put it, a part that's moved outside its range with nothing new from them put
    /// back at the nearest end, and nothing moved at all when they only asked again. What was held, in words for the reply.
    static func held(_ e: JSON, before: JSON?, said: String) -> (estimate: JSON, notes: [String]) {
        let old = CheatDays.list(before?["parts"])
        let amount = givesAmount(said), again = asksAgainOnly(said)
        let saidWords = Set(FoodTable.words(said).filter { $0.count >= 4 })
        var notes: [String] = [], changed = false
        let parts = CheatDays.list(e["parts"]).map { p0 -> JSON in
            var p = p0
            let g = pos(p["grams"]) ?? 0
            let fresh = range(inSize: str(p["size"]))
            let was = earlier(p, in: old)
            let wasG = was.flatMap { pos($0["grams"]) }
            let wasRange: (low: Double, high: Double)? = was.flatMap { w in
                guard let lo = pos(w["low"]), let hi = pos(w["high"]) else { return nil }
                return (lo, hi)
            }
            let locked = was?["locked"] as? Bool == true
            func keep(_ r: (low: Double, high: Double), locked l: Bool) { p["low"] = r.low.rounded(); p["high"] = r.high.rounded(); p["locked"] = l ? true : nil }
            let label = str(p["name"]).split(separator: ",").first.map { $0.lowercased() } ?? "it"

            // their weight or count: the part is fixed there, give or take a little, whatever the photo looked like
            if amount, g > 0, wasG.map({ abs($0 - g) >= 1 }) ?? !Set(FoodTable.words(str(p["name"]))).isDisjoint(with: saidWords) {
                keep((g * (1 - lockedSlack), g * (1 + lockedSlack)), locked: true)
                return p
            }
            guard let wasG else {   // new to this chat: the range it came with
                if let fresh { keep(fresh, locked: false) }
                return p
            }
            // nothing new from them: as it was
            if again || (locked && !amount) {
                if abs(wasG - g) >= 1 {
                    p = regrammed(p, to: wasG); changed = true
                    notes.append(locked ? "I've kept the \(label) at \(Fmt.int(wasG)) g from the numbers you gave: they're more reliable than anything I can judge from the photo."
                                        : "Nothing new came in, so the \(label) stays at \(Fmt.int(wasG)) g.")
                }
                if let w = was { for k in ["low", "high", "locked", "size"] { p[k] = w[k] } }
                return p
            }
            // a new look: it can narrow the range, never leave it
            if let r = wasRange {
                var now = r
                if let fresh, fresh.low <= r.high, fresh.high >= r.low { now = (max(r.low, fresh.low), min(r.high, fresh.high)) }
                keep(now, locked: false)
                if !amount, g < r.low - 0.5 || g > r.high + 0.5 {
                    let to = min(max(g, r.low), r.high)
                    p = regrammed(p, to: to); changed = true
                    p["low"] = min(now.low, to.rounded()); p["high"] = max(now.high, to.rounded())
                    notes.append("That's outside the \(Fmt.int(r.low))–\(Fmt.int(r.high)) g I gave before, so I've kept the \(label) at \(Fmt.int(to)) g. Tell me its weight or how many pieces and I'll use that.")
                }
            } else if let fresh { keep(fresh, locked: false) }
            return p
        }
        var out = e
        out["parts"] = parts
        if changed {
            func sum(_ k: String) -> Double { parts.reduce(0) { $0 + (num($1[k]) ?? 0) } }
            out["kcal_total"] = sum("kcal").rounded(); out["protein_g"] = sum("protein_g"); out["carbs_g"] = sum("carbs_g"); out["fat_g"] = sum("fat_g")
            out["portion_g"] = sum("grams").rounded()
        }
        return (out, notes)
    }
}
