import UIKit

/// A meal as it happens (approved 25 Nov from design/meal-chat-mockup.html): one running card through the chat.
/// Before eating, what to have next in order and what they'd finish on; while eating, what they've had so far (only what
/// they say they've had) and what's next; at the end, what they had and one Add that puts the meal on as one entry, which
/// changes in place when they have more. The 22 Nov dinner, sent as an ordinary chat (eight turns remembered, a card a
/// message), ended at 442 kcal and 4 foods against a hand tally of 1,155 and 10.
///
/// No new schema fields (Claude's format is at its limit): estimate.parts is the tally, estimate.notes the price list of
/// one piece of each dish, plan.suggestions what to have next. The rule is Assistant.mealRules.
enum MealChat {
    // MARK: when it's a meal

    /// "Got to share it all, haven't eaten yet", "what else to eat?": a meal at the table.
    static func starts(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let strong = ["haven't eaten", "havent eaten", "have not eaten", "haven't started", "havent started", "had so far", "eat next", "have next",
                      "what else to eat", "what else should i eat", "what else should i have", "what should i eat first", "what to eat first",
                      "eating now", "what's on the table", "whats on the table"]
        if strong.contains(where: { t.contains($0) }) { return true }
        let sharing = t.range(of: #"\b(share|sharing|shared|split with|split between|splitting with|between us)\b"#, options: .regularExpression) != nil
        let table = t.range(of: #"\b(ordered|order|the food|on the table|eating|dinner|lunch|hotpot|hot pot|yum cha|pizza|bbq|banquet|feast|platter)\b"#, options: .regularExpression) != nil
        return sharing && table
    }

    /// Once an answer in the chat was a meal card, every message after it is part of the meal.
    static func isOn(_ turns: [Assistant.Turn]) -> Bool {
        turns.contains { (t: Assistant.Turn) -> Bool in !t.me && str(t.result?["kind"]) == "meal" }
    }

    /// Their latest message goes to the meal: the chat is one already, or this starts one.
    static func wanted(_ turns: [Assistant.Turn]) -> Bool {
        guard let last = turns.last, last.me else { return false }
        return isOn(Array(turns.dropLast())) || starts(last.text)
    }

    /// The latest meal card.
    static func lastCard(_ turns: [Assistant.Turn]) -> JSON? {
        turns.last { (t: Assistant.Turn) -> Bool in !t.me && str(t.result?["kind"]) == "meal" }?.result
    }

    static func tally(_ r: JSON?) -> [JSON] { list(dict(r?["estimate"])["parts"]) }
    static func next(_ r: JSON?) -> [JSON] { list(dict(r?["plan"])["suggestions"]) }

    // MARK: asking

    /// The meal's message to Claude: the rules and the meal rule, the latest photos of the chat (newest first, up to four),
    /// the day (from before this meal), and the whole chat with the tally, the price list and what was suggested next.
    @MainActor
    static func ask(_ turns: [Assistant.Turn], store: Store) async throws -> JSON {
        guard let last = turns.last, last.me else { throw Gemini.Failure(message: "Nothing to ask.") }
        let before: JSON? = lastCard(Array(turns.dropLast()))
        let leaving: String? = entryId(turns)
        let pics: [UIImage] = photos(turns)
        var parts: [JSON] = [["text": "You are the assistant inside a cheat-day food diary app called Cheat Days.\n\(Assistant.rules)\n\(Assistant.mealRules)", "cache": true]]
        parts += pics.compactMap { Gemini.imagePart($0) }
        let said: String = earlier(turns)
        let day: String = Assistant.context(store, skip: turns.first { $0.me }?.text ?? "", asking: last.text, leaving: leaving)
        let about: String = last.images.isEmpty && !pics.isEmpty ? " (about the photos from earlier)" : ""
        parts.append(["text": "\(day)\(said.isEmpty ? "" : "Recent conversation:\n\(said)\n")They now say: \"\(last.text)\"\(about)\n"])
        let answer = try await Gemini.ask(schema: Assistant.mealFormat, parts: parts, quick: false, job: pics.isEmpty ? "chat" : "photos")
        var out = shaped(answer, before: before, said: last.text, photos: !last.images.isEmpty, base: base(turns, store: store, leaving: leaving))
        if let m = Meals.named(in: last.text) { out["meal"] = m } else if let m = before?["meal"] as? String, !m.isEmpty { out["meal"] = m }
        return out
    }

    /// The photos the meal goes with: every photo in the chat, the newest first, up to four (the receipt stays in view
    /// when the plates come).
    static func photos(_ turns: [Assistant.Turn]) -> [UIImage] {
        Array(turns.reversed().flatMap { (t: Assistant.Turn) -> [UIImage] in t.me ? t.images : [] }.prefix(4))
    }

    /// The whole chat before their latest message. The tally goes on the last card that had one, and the price list and
    /// what was suggested next on the last answer, word for word as tools/ai-test/meal-other-check.js sends it.
    static func earlier(_ turns: [Assistant.Turn]) -> String {
        let before: [Assistant.Turn] = Array(turns.dropLast())
        let lastTally: Int? = before.lastIndex { (t: Assistant.Turn) -> Bool in !t.me && str(t.result?["kind"]) == "meal" && !tally(t.result).isEmpty }
        let lastBot: Int? = before.lastIndex { (t: Assistant.Turn) -> Bool in !t.me }
        var lines: [String] = []
        for (k, t) in before.enumerated() {
            if t.me { lines.append("They: \(t.text)"); continue }
            var line = "You: \(t.text)"
            if str(t.result?["kind"]) == "meal" {
                if k == lastTally {
                    let had = tally(t.result)
                    let each: [String] = had.map { (p: JSON) -> String in
                        "\(str(p["name"])) \(whole(p["grams"])) g \(whole(p["kcal"])) kcal P\(whole(p["protein_g"]))"
                    }
                    line += " [eaten so far, \(Int(totals(had).kcal.rounded())) kcal: \(each.joined(separator: "; "))]"
                }
                if k == lastBot {
                    let notes = str(dict(t.result?["estimate"])["notes"])
                    if !notes.isEmpty { line += " [price list for one piece: \(notes)]" }
                    let n = next(t.result)
                    if !n.isEmpty { line += " [you suggested next: \(n.map { (s: JSON) -> String in "\(str(s["name"])), \(str(s["amount"]))" }.joined(separator: "; "))]" }
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func whole(_ v: Any?) -> Int { Int((num(v) ?? 0).rounded()) }

    // MARK: the sums

    struct Totals: Equatable {
        var kcal = 0.0, p = 0.0, c = 0.0, f = 0.0
    }

    /// The tally's totals, added up here (never asked of Claude).
    static func totals(_ parts: [JSON]) -> Totals {
        var t = Totals()
        for x in parts {
            t.kcal += num(x["kcal"]) ?? 0; t.p += num(x["protein_g"]) ?? 0; t.c += num(x["carbs_g"]) ?? 0; t.f += num(x["fat_g"]) ?? 0
        }
        return t
    }

    /// "Lamb skewers, 5" is 5 of lamb skewers; "Lamb chop, 3 pieces" 3 pieces; "Stinky tofu, ⅓ square" a third of a
    /// square. Nil when the name has no count after its comma ("Noodles, a few forkfuls").
    static func counted(_ name: String) -> (food: String, n: Double, unit: String)? {
        guard let comma = name.lastIndex(of: ",") else { return nil }
        let food = name[..<comma].trimmingCharacters(in: .whitespaces).lowercased()
        let rest = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !food.isEmpty, let r = rest.range(of: #"^(\d+(\.\d+)?\s*/\s*\d+|\d*\s*[½⅓⅔¼¾]|\d+(\.\d+)?)"#, options: .regularExpression) else { return nil }
        let said = String(rest[r]).replacingOccurrences(of: " ", with: "")
        let fractions: [Character: Double] = ["½": 0.5, "⅓": 1 / 3.0, "⅔": 2 / 3.0, "¼": 0.25, "¾": 0.75]
        var n: Double?
        if said.contains("/") {
            let ab = said.split(separator: "/").compactMap { Double($0) }
            if ab.count == 2, ab[1] > 0 { n = ab[0] / ab[1] }
        } else if let last = said.last, let fr = fractions[last] {
            n = (Double(said.dropLast()) ?? 0) + fr
        } else {
            n = Double(said)
        }
        guard let count = n, count > 0 else { return nil }
        let skip: Set<String> = ["of", "more", "small", "big", "large", "x", "about", "extra"]
        let words = rest[r.upperBound...].split(separator: " ").map(String.init).filter { w in w.allSatisfy(\.isLetter) && !skip.contains(w) }
        var unit = words.last ?? ""
        if unit.count > 3, unit.hasSuffix("s") { unit = String(unit.dropLast()) }
        return (food, count, unit)
    }

    /// The food and its amount, apart: "Lamb chop, 3 pieces" is "Lamb chop" and "3 pieces".
    static func split(_ name: String) -> (food: String, amount: String) {
        guard let comma = name.lastIndex(of: ",") else { return (name, "") }
        return (name[..<comma].trimmingCharacters(in: .whitespaces), name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces))
    }

    /// The tally on one line, for when it's folded away: "Lamb skewers 5, Lamb chop 2 pieces, Squid 2".
    static func line(_ parts: [JSON]) -> String {
        parts.map { (p: JSON) -> String in
            let s = split(str(p["name"]))
            return s.amount.isEmpty ? s.food : "\(s.food) \(s.amount)"
        }.joined(separator: ", ")
    }

    /// A piece's calories stay the same through the chat: a food counted the same way on the last card keeps its kcal,
    /// macros and grams per piece, so 2 and then 3 pieces moves the total by one piece and nothing else (Claude's own sums
    /// drift by a few kcal, its carbs and fat by more). A food counted another way (a new unit, no count) is left as given.
    static func held(_ parts: [JSON], before: [JSON]) -> [JSON] {
        var was: [String: (n: Double, unit: String, part: JSON)] = [:]
        for b in before { if let c = counted(str(b["name"])) { was[c.food] = (c.n, c.unit, b) } }
        return parts.map { (p: JSON) -> JSON in
            guard let c = counted(str(p["name"])), let w = was[c.food], w.unit == c.unit, w.n > 0 else { return p }
            var out = p
            let share = c.n / w.n
            for k in ["kcal", "protein_g", "carbs_g", "fat_g", "grams"] {
                if let v = num(w.part[k]) { out[k] = share == 1 ? v : (v * share * 10).rounded() / 10 }
            }
            return out
        }
    }

    /// "They were big skewers": their word on a piece's size, when its price may change.
    static func resized(_ text: String) -> Bool {
        text.lowercased().range(of: #"\b(bigger|biggest|smaller|tiny|huge|thicker|thinner|size|sized|double|massive)\b"#, options: .regularExpression) != nil
    }

    /// The answer as the meal card shows it: kind meal; the tally kept when a question comes back without one, each piece
    /// held to its price unless new photos or their word on its size came; totals added up here; the price list kept
    /// when an answer leaves it out; and what the meters are measured against.
    static func shaped(_ a: JSON, before: JSON?, said: String, photos: Bool, base: JSON) -> JSON {
        var out = a
        var e = dict(a["estimate"])
        var had = list(e["parts"])
        let was = tally(before)
        if had.isEmpty { had = was }
        else if !photos && !resized(said) { had = held(had, before: was) }
        e["parts"] = had
        let t = totals(had)
        e["kcal_total"] = t.kcal.rounded(); e["protein_g"] = t.p; e["carbs_g"] = t.c; e["fat_g"] = t.f
        if str(e["notes"]).isEmpty { e["notes"] = str(dict(before?["estimate"])["notes"]) }
        out["estimate"] = e
        out["plan"] = ["suggestions": next(a)] as JSON
        out["kind"] = "meal"
        out["mealBase"] = base
        return out
    }

    // MARK: what it's measured against

    /// What they said they have left or need, in their own words: "need to hit 107g protein", "have 1334 kcals".
    static func stated(_ text: String) -> (kcal: Double?, protein: Double?) {
        let t = text.lowercased().replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression)
        func first(_ pattern: String) -> Double? {
            guard let r = t.range(of: pattern, options: .regularExpression) else { return nil }
            let digits = t[r].split { !$0.isNumber }.first.map(String.init) ?? ""
            return Double(digits)
        }
        let protein = first(#"\b\d{2,3}\s?(g|grams?)\s+(of\s+)?protein\b"#) ?? first(#"\bprotein\D{0,20}\d{2,3}\s?(g|grams?)\b"#)
        let kcal = first(#"\b\d{3,4}\s?(kcals?|cals?|calories)\b"#)
        return (kcal, protein)
    }

    /// The calories and protein the meters are out of: what they said (the latest they said), else the meal's first card,
    /// else today's left and protein to go, from before this meal.
    @MainActor
    static func base(_ turns: [Assistant.Turn], store: Store, leaving: String?) -> JSON {
        var kcal: Double?, protein: Double?
        for t in turns where t.me {
            let s = stated(t.text)
            if let k = s.kcal { kcal = k }
            if let p = s.protein { protein = p }
        }
        let first = dict(turns.first { (t: Assistant.Turn) -> Bool in !t.me && str(t.result?["kind"]) == "meal" }?.result?["mealBase"])
        let items = store.todayItems.filter { (it: JSON) -> Bool in leaving == nil || str(it["id"]) != leaving }
        let left = max(0, store.budgetToday - items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) })
        let toGo: Double = store.proteinGoal.map { max(0, $0 - store.macros(items).p) } ?? 0
        return ["kcal": kcal ?? num(first["kcal"]) ?? left, "p": protein ?? num(first["p"]) ?? toGo]
    }

    // MARK: the one entry

    /// The entry this chat put on the day, if it has.
    static func entryId(_ turns: [Assistant.Turn]) -> String? {
        turns.compactMap { (t: Assistant.Turn) -> String? in
            let s = str(t.result?["mealEntry"])
            return s.isEmpty ? nil : s
        }.last
    }

    /// The meal as one food: its totals, and what went in.
    static func entry(_ parts: [JSON], name: String) -> (basis: JSON, kcal: Double) {
        let t = totals(parts)
        var b = Assistant.basis(name: name, kcal: t.kcal, grams: nil, p: t.p, c: t.c, f: t.f)
        b["ingredients"] = parts.map { str($0["name"]) }
        return (b, t.kcal)
    }

    /// Whether the entry on the day is this tally already (nothing new to put on).
    static func matches(_ item: JSON?, parts: [JSON]) -> Bool {
        guard let item else { return false }
        return Int(num(item["kcal"]) ?? -1) == Int(totals(parts).kcal.rounded()) && (item["ingredients"] as? [String] ?? []) == parts.map { str($0["name"]) }
    }

    /// The changes that put the meal on as one entry: the one this chat put on before comes off its day (today's or one
    /// already filed) and the meal goes on today in its place, so there's only ever one.
    static func entryOps(_ parts: [JSON], name: String, meal: String, over old: String?, in doc: JSON, today: String, id: String) -> [JSON] {
        var ops: [JSON] = []
        if let old, !old.isEmpty {
            let onDay = list(dict(doc["day"])["items"]).contains { str($0["id"]) == old }
            let filed = list(doc["history"]).first { h in list(h["items"]).contains { str($0["id"]) == old } }
            if onDay { ops.append(["type": "delete", "id": old, "at": nowMs(), "day": str(dict(doc["day"])["date"])]) }
            else if let filed { ops.append(["type": "delete", "id": old, "at": nowMs(), "day": str(filed["date"])]) }
        }
        let e = entry(parts, name: name), k = e.kcal.rounded()
        var item = FoodMath.basisOf(e.basis)
        item["id"] = id
        item["kcal"] = Int(k)
        item["shareLabel"] = Fmt.share(k, of: Store.baseBudget(today, in: doc))
        item["addedAt"] = ISO.now()
        if Meals.all.contains(meal) { item["meal"] = meal }
        ops.append(["type": "add", "item": item, "day": today])
        return ops
    }

    /// Puts the meal on today, or changes the one this chat put on already. Returns the entry's id.
    @MainActor @discardableResult
    static func put(_ parts: [JSON], name: String, meal: String, over old: String?, store: Store) -> String {
        let id = uid()
        for op in entryOps(parts, name: name, meal: meal, over: old, in: store.doc, today: store.today, id: id) { store.perform(op) }
        return id
    }
}
