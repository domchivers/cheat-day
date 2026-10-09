import UIKit

/// The assistant's brain: what it knows about the day, the answer shapes it can give, and turning answers into changes.
/// Same jobs as the website's assistant: log a plate, plan the rest of the day, fix today's list, a recipe, a lighter version, or just answer.
enum Assistant {
    struct Turn: Identifiable {
        let id = UUID()
        let me: Bool
        let text: String
        var result: JSON?
        var images: [UIImage] = []
    }

    private static func obj(_ props: JSON, nullable: Bool = false, desc: String = "") -> JSON {
        var o: JSON = ["type": "object", "properties": props, "required": Array(props.keys)]
        if nullable { o["nullable"] = true }
        if !desc.isEmpty { o["description"] = desc }
        return o
    }
    private static let n: JSON = ["type": "number"]
    private static let s: JSON = ["type": "string"]
    private static let nn: JSON = ["type": "number", "nullable": true]
    private static let ns: JSON = ["type": "string", "nullable": true]
    private static func arr(_ items: JSON, desc: String = "") -> JSON { desc.isEmpty ? ["type": "array", "items": items] : ["type": "array", "items": items, "description": desc] }

    static let schema: JSON = obj([
        "reply": ["type": "string", "description": "What you'd say back, warm and short (one to three sentences). Always filled."] as JSON,
        "kind": ["type": "string", "enum": ["answer", "estimate", "plan", "edit", "recipe", "lighter"]] as JSON,
        "estimate": obj([
            "name": s, "portion_g": n, "unit": ["type": "string", "enum": ["g", "ml"]] as JSON,
            "kcal_total": n, "protein_g": n, "carbs_g": n, "fat_g": n, "notes": s,
            "parts": arr(obj(["name": s, "grams": n, "kcal": n]), desc: "each component, including oil, butter and sauces as their own parts")
        ], nullable: true, desc: "kind=estimate: a food or plate as one portion"),
        "plan": obj(["suggestions": arr(obj(["name": s, "amount": s, "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n, "why": s]))],
                    nullable: true, desc: "kind=plan: 3 to 5 things for the rest of today"),
        "edit": obj(["actions": arr(obj([
            "action": ["type": "string", "enum": ["add", "remove", "update", "workout"]] as JSON,
            "target": ns, "name": ns, "kcal": nn, "protein_g": nn, "carbs_g": nn, "fat_g": nn,
            "minutes": nn, "effort": ns, "activity": ns
        ]))], nullable: true, desc: "kind=edit: changes to today's list or a workout to log"),
        "recipe": obj([
            "name": s, "portions": n, "ingredients": arr(obj(["name": s, "grams": n, "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n])),
            "steps": arr(s), "notes": s
        ], nullable: true, desc: "kind=recipe: a dish to cook and save as a meal"),
        "lighter": obj(["name": s, "tips": arr(s), "kcal_per_serving": n, "protein_g": n, "carbs_g": n, "fat_g": n],
                       nullable: true, desc: "kind=lighter: a lighter way to have something")
    ])

    @MainActor
    static func context(_ store: Store) -> String {
        let items = store.todayItems
        let eaten = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, m = store.macros(items)
        let list = items.map { "\"\(str($0["name"]))\" \(Int(num($0["kcal"]) ?? 0)) kcal" }.joined(separator: ", ")
        let past = (0..<3).compactMap { i -> String? in
            let d = DayKey.shift(store.today, days: -(i + 1)); guard let p = store.pastDay(d) else { return nil }
            return "\(d): \(Int(p.kcal))/\(Int(p.budget)) kcal (\(p.items.prefix(6).map { str($0["name"]) }.joined(separator: ", ")))"
        }.joined(separator: "; ")
        let meals = Swift.Array(CheatDays.list(store.doc["meals"]).prefix(10)).map { str($0["name"]) }.joined(separator: ", ")
        let wk = store.todayWorkouts.map { "\(str($0["name"])) \(Int(num($0["minutes"]) ?? 0)) min" }.joined(separator: ", ")
        let notes = str(store.doc["notes"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefs = dict(store.doc["prefs"])
        let loves = (prefs["loves"] as? [String] ?? []).joined(separator: ", "), avoid = (prefs["avoid"] as? [String] ?? []).joined(separator: ", ")
        var c = notes.isEmpty ? "" : "About this person, in their own words (respect it in every suggestion): \(notes)\n"
        c += "They live in \(Plan.country). Today: budget \(Int(store.budgetToday)) kcal, eaten \(Int(eaten)) kcal (\(list.isEmpty ? "nothing yet" : list)), \(Int(store.budgetToday - eaten)) kcal left. "
        c += "Protein so far \(Int(m.p)) g\(store.proteinGoal.map { " of \(Int($0)) g" } ?? ""), carbs \(Int(m.c)) g, fat \(Int(m.f)) g. Workouts today: \(wk.isEmpty ? "none" : wk). Weight \(Fmt.one(store.latestWeight?.kg ?? store.weightKg)) kg.\n"
        c += "Recent days: \(past.isEmpty ? "none yet" : past).\n"
        c += "Things they often have: \(store.quickEntries.prefix(8).map(\.name).joined(separator: ", ")). Their saved meals: \(meals.isEmpty ? "none" : meals).\n"
        if !loves.isEmpty || !avoid.isEmpty { c += "Foods they love: \(loves.isEmpty ? "not said" : loves). Never suggest: \(avoid.isEmpty ? "nothing" : avoid).\n" }
        if let next = store.nextCheat { c += "Their next cheat day is \(next.date == store.today ? "today" : next.date), with \(Int(next.kcal)) kcal.\n" }
        return c
    }

    static let rules = """
    Decide what they want and fill exactly one of estimate / plan / edit / recipe / lighter (leave the others null), or kind=answer for a plain question:
    - estimate: a food or plate to log, as one portion with honest kcal and macros, broken into parts (each component with its cooked grams; oil, butter and sauce as separate parts).
    - plan: 3 to 5 things for the rest of today that fit the calories left, close the protein gap as far as sensible, and leave room for one treat.
    - edit: they're correcting today's list ("I only had 2 eggs", "remove the toast", "add a banana"): target is the name of the item on today's list to change or remove; for add and update give name and the new kcal and macros. Or logging exercise: action workout with activity (Walk, Run, Cycle, Swim, Gym weights, HIIT, Yoga / stretch, Football, Tennis / padel, Hike, Rowing, Elliptical, Dance, Boxing, Climbing), minutes and effort (easy, moderate, hard).
    - recipe: a dish to cook with realistic ingredient amounts, kcal and macros per ingredient (standard reference values, so they add up), and short method steps. Respect any calorie limit they give.
    - lighter: a lighter way to have something, with tips and the lighter serving's numbers.
    Hard rules:
    - If they give numbers themselves (calories, grams, protein), use exactly those numbers.
    - Only talk about foods actually in the conversation, their photos, their day or their meals. Never invent placeholders.
    - When several products are in the photos, give each its own numbers before recommending.
    - If you can't tell what something is, say so and ask rather than guessing.
    - Keep reply short, friendly and never preachy. It's a cheat-day app: treats are part of the plan.
    """

    @MainActor
    static func ask(_ turns: [Turn], store: Store) async throws -> JSON {
        guard let last = turns.last, last.me else { throw Gemini.Failure(message: "Nothing to ask.") }
        let earlier = turns.dropLast().suffix(8).map { t -> String in
            if t.me { return "They: \(t.text)" }
            var line = "You: \(t.text)"
            if let r = t.result, let e = r["estimate"] as? JSON { line += " [you worked out: \(str(e["name"])), \(Int(num(e["kcal_total"]) ?? 0)) kcal]" }
            if let r = t.result, let rc = r["recipe"] as? JSON { line += " [recipe \(str(rc["name"])): \(CheatDays.list(rc["ingredients"]).map { "\(str($0["name"])) \(Int(num($0["grams"]) ?? 0)) g" }.joined(separator: ", "))]" }
            return line
        }.joined(separator: "\n")
        // photos come along from the last message that had some, when this one has none
        let pics = last.images.isEmpty ? (turns.dropLast().last { $0.me && !$0.images.isEmpty }?.images ?? []) : last.images
        var parts: [JSON] = pics.prefix(4).compactMap { Gemini.imagePart($0) }
        parts.append(["text": "You are the assistant inside a cheat-day food diary app called Cheat Days. \(context(store))\(earlier.isEmpty ? "" : "Recent conversation:\n\(earlier)\n")They now say: \"\(last.text)\"\(last.images.isEmpty && !pics.isEmpty ? " (about the photos from earlier)" : "")\n\n\(rules)"])
        return try await Gemini.ask(schema: schema, parts: parts, quick: false)
    }

    /// What an estimate, a suggestion or a lighter serving adds to the day as.
    static func basis(name: String, kcal: Double, grams: Double?, unit: String = "g", p: Double, c: Double, f: Double) -> JSON {
        var b: JSON = ["name": name, "source": "claude", "unit": unit, "unitLabel": "portion", "kcalPerServing": kcal.rounded(), "pServ": p, "cServ": c, "fServ": f]
        if let g = grams, g > 0 { b["servingSize"] = g; b["kcalPer100"] = (kcal / g * 1000).rounded() / 10; b["p100"] = p / g * 100; b["c100"] = c / g * 100; b["f100"] = f / g * 100 }
        return b
    }

    /// Carry out an edit: returns what was done, in words.
    @MainActor
    static func apply(_ edit: JSON, meal: String, store: Store) -> [String] {
        var done: [String] = []
        for a in CheatDays.list(edit["actions"]) {
            let target = str(a["target"]).lowercased(), name = str(a["name"])
            let match = store.todayItems.last { !target.isEmpty && str($0["name"]).lowercased().contains(target) }
                ?? store.todayItems.last { !target.isEmpty && target.contains(str($0["name"]).lowercased()) }
            switch str(a["action"]) {
            case "add":
                guard let k = num(a["kcal"]), !name.isEmpty else { continue }
                store.add(basis(name: name, kcal: k, grams: nil, p: num(a["protein_g"]) ?? 0, c: num(a["carbs_g"]) ?? 0, f: num(a["fat_g"]) ?? 0), kcal: k, meal: meal)
                done.append("Added \(name)")
            case "remove":
                guard let it = match else { done.append("Couldn't find \(target) to remove"); continue }
                store.delete(str(it["id"])); done.append("Removed \(str(it["name"]))")
            case "update":
                guard let it = match, let k = num(a["kcal"]) else { done.append("Couldn't find \(target) to change"); continue }
                store.edit(str(it["id"]), kcal: k, meal: Meals.of(it)); done.append("\(str(it["name"])) is now \(Int(k)) kcal")
            case "workout":
                let type = str(a["activity"]).isEmpty ? "Walk" : str(a["activity"]), mins = num(a["minutes"]) ?? 30
                store.logActivity(type: type, name: type, minutes: mins, effort: str(a["effort"]).isEmpty ? "moderate" : str(a["effort"]))
                done.append("Logged \(type), \(Int(mins)) min")
            default: break
            }
        }
        return done
    }

    /// A chat as kept in the record (text and results, never photos), like the website's saveChat.
    static func record(id: String, turns: [Turn]) -> JSON {
        let first = turns.first { $0.me }?.text ?? "Chat"
        return ["id": id, "title": String(first.prefix(60)), "when": ISO.now(),
                "turns": turns.suffix(40).map { t -> JSON in
                    var j: JSON = ["role": t.me ? "me" : "bot", "text": t.text + (t.images.isEmpty ? "" : " (\(t.images.count) photo\(t.images.count == 1 ? "" : "s"))")]
                    if let r = t.result { j["result"] = r; j["kind"] = r["kind"] ?? "answer" }
                    return j
                }]
    }

    static func turns(from chat: JSON) -> [Turn] {
        CheatDays.list(chat["turns"]).map { Turn(me: str($0["role"]) == "me", text: str($0["text"]), result: $0["result"] as? JSON) }
    }

    static func applyChatOp(_ op: JSON, to d: inout JSON) {
        switch str(op["type"]) {
        case "chat":
            let c = dict(op["chat"]), id = str(c["id"])
            guard !id.isEmpty, dict(d["tombs"])["chat:\(id)"] == nil else { return }
            var chats = CheatDays.list(d["chats"]).filter { str($0["id"]) != id }
            chats.insert(c, at: 0)
            d["chats"] = Swift.Array(chats.prefix(30))
        case "deleteChat":
            let id = str(op["id"])
            d["chats"] = CheatDays.list(d["chats"]).filter { str($0["id"]) != id }
            var tombs = dict(d["tombs"]); tombs["chat:\(id)"] = op["at"] ?? nowMs(); d["tombs"] = tombs
        default: break
        }
    }
}
