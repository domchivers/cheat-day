import UIKit

/// The assistant's brain: what it knows about the day, the answer shapes it can give, and turning answers into changes.
/// Same jobs as the website's assistant: log a plate, plan the rest of the day, fix today's list, a recipe, a lighter version, or just answer.
/// The conversation on screen, kept outside the view: leave the assistant (or the app) while it's thinking and the
/// answer still lands, and opening it again within a while carries on where you were.
@Observable @MainActor
final class AssistantLive {
    static let shared = AssistantLive()
    var turns: [Assistant.Turn] = []
    var chatId = uid()
    var busy = false
    var problem: String?
    var used = Date()

    func open(fresh: Bool) {
        if busy { return }
        if fresh || Date().timeIntervalSince(used) > 20 * 60 { turns = []; chatId = uid(); problem = nil }
        used = Date()
    }
}

enum Assistant {
    struct Turn: Identifiable {
        let id = UUID()
        let me: Bool
        let text: String
        var result: JSON?
        var images: [UIImage] = []
    }

    private static func obj(_ props: JSON, desc: String = "") -> JSON {
        var o: JSON = ["type": "object", "properties": props, "required": Array(props.keys)]
        if !desc.isEmpty { o["description"] = desc }
        return o
    }
    private static let n: JSON = ["type": "number"]
    private static let s: JSON = ["type": "string"]
    /// Where a food's numbers came from: a label in the chat (or their own numbers) is never swapped for a database's.
    /// A branded product with no label to hand is looked up on the web; until then its numbers stay the AI's, never a generic food's.
    private static let from: JSON = ["type": "string", "enum": ["label", "them", "brand", "estimate"],
                                     "description": "label: worked out from a nutrition label in the photos or chat; them: numbers they gave; brand: a specific packaged product (brand and name) with no label to hand, your best guess; estimate: otherwise"]
    private static func arr(_ items: JSON, desc: String = "") -> JSON { desc.isEmpty ? ["type": "array", "items": items] : ["type": "array", "items": items, "description": desc] }

    /// No nulls anywhere: with them Claude refuses the schema ("compiled grammar is too large"). Every answer is
    /// required, the unused ones empty (an unused number 0, an unused word ""): with only reply and kind required,
    /// Claude sent an empty recipe and no estimate for "174 g, no skin", so there was nothing to add.
    static let schema: JSON = full
    private static let full: JSON = obj([
        "reply": ["type": "string", "description": "What you'd say back, warm and short (one to three sentences). Always filled."] as JSON,
        "kind": ["type": "string", "enum": ["answer", "estimate", "plan", "edit", "recipe", "lighter"]] as JSON,
        "estimate": obj([
            "name": s, "portion_g": n, "unit": ["type": "string", "enum": ["g", "ml"]] as JSON,
            "kcal_total": n, "protein_g": n, "carbs_g": n, "fat_g": n, "notes": s,
            "parts": arr(obj(["name": s, "usda_name": ["type": "string", "description": "the closest USDA FoodData Central SR Legacy description, e.g. 'Chicken, broilers or fryers, breast, meat only, cooked, roasted'"] as JSON,
                              "grams": ["type": "number", "description": "as eaten (cooked weight)"] as JSON, "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n,
                              "numbers_from": from,
                              "servings": ["type": "number", "description": "for a brand part: how many of its items or pack servings they had (1 stick = 1); 0 when they gave a weight"] as JSON]),
                          desc: "each component, including oil, butter and sauces as their own parts")
        ], desc: "kind=estimate: a food or plate as one portion"),
        "plan": obj(["suggestions": arr(obj(["name": s, "amount": s, "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n, "why": s]))],
                    desc: "kind=plan: 3 to 5 things for the rest of today"),
        "edit": obj(["actions": arr(obj([
            "action": ["type": "string", "enum": ["add", "remove", "update", "workout"]] as JSON,
            "target": s, "name": s, "grams": ["type": "number", "description": "for add and update: the amount in grams (ml for drinks)"] as JSON,
            "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n, "numbers_from": from,
            "minutes": n, "effort": s, "activity": s
        ]))], desc: "kind=edit: changes to today's list or a workout to log"),
        "recipe": obj([
            "name": s, "portions": n, "ingredients": arr(obj(["name": s, "grams": n, "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n])),
            "steps": arr(s), "notes": s
        ], desc: "kind=recipe: a dish to cook and save as a meal"),
        "lighter": obj(["name": s, "tips": arr(s), "kcal_per_serving": n, "protein_g": n, "carbs_g": n, "fat_g": n],
                       desc: "kind=lighter: a lighter way to have something")
    ])

    /// A day's foods by meal, each with its amount and kcal: "Breakfast: "Protein Yogurt Bowl" 295 g 425 kcal; Dinner: …".
    /// Every item, so yesterday's dinner is there to find (it was the first six names only, and dinner fell off the end).
    static func byMeal(_ items: [JSON]) -> String {
        Meals.all.compactMap { m -> String? in
            let its = items.filter { Meals.of($0) == m }
            guard !its.isEmpty else { return nil }
            return "\(m): " + its.map { it in
                let k = num(it["kcal"]) ?? 0, a = FoodMath.amountText(it, kcal: k)
                return "\"\(str(it["name"]))\"\(a.isEmpty ? "" : " \(a)") \(Int(k)) kcal"
            }.joined(separator: ", ")
        }.joined(separator: "; ")
    }

    /// What they said in other chats over the last 3 days, and what was worked out, so "that chicken" can be found.
    /// Skip is the current chat's first message (it's in the conversation already).
    @MainActor
    static func earlierChats(_ store: Store, skip: String) -> String {
        let since = Date().addingTimeInterval(-3 * 86400)
        return CheatDays.list(store.doc["chats"]).filter { c in
            (ISO.date(str(c["when"])) ?? .distantPast) >= since && CheatDays.list(c["turns"]).first { str($0["role"]) == "me" }.map { str($0["text"]) } != skip
        }.prefix(4).map { c -> String in
            let when = ISO.date(str(c["when"])).map { $0.formatted(.dateTime.weekday(.wide).hour().minute()) } ?? ""
            let lines = CheatDays.list(c["turns"]).compactMap { t -> String? in
                if str(t["role"]) == "me" { return "they said \"\(str(t["text"]).prefix(160))\"" }
                guard let e = dict(t["result"])["estimate"] as? JSON else { return nil }
                // the grams too, so a new amount of the same food can be scaled from it
                let g = num(e["portion_g"]) ?? 0
                return "you worked out \(str(e["name"])), \(g > 0 ? "\(Int(g)) g, " : "")\(Int(num(e["kcal_total"]) ?? 0)) kcal"
            }.suffix(8)
            return "\(when): " + lines.joined(separator: "; ")
        }.joined(separator: "\n")
    }

    @MainActor
    static func context(_ store: Store, skip: String = "") -> String {
        let items = store.todayItems
        let eaten = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, m = store.macros(items)
        let list = byMeal(items)
        let past = (0..<3).compactMap { i -> String? in
            let d = DayKey.shift(store.today, days: -(i + 1)); guard let p = store.pastDay(d) else { return nil }
            let name = i == 0 ? "Yesterday" : DayKey.date(d).formatted(.dateTime.weekday(.wide))
            return "\(name) (\(d)), \(Int(p.kcal))/\(Int(p.budget)) kcal: \(p.items.isEmpty ? "nothing logged" : byMeal(p.items))"
        }.joined(separator: "\n")
        let chats = earlierChats(store, skip: skip)
        let meals = Swift.Array(CheatDays.list(store.doc["meals"]).prefix(10)).map { str($0["name"]) }.joined(separator: ", ")
        let wk = store.todayWorkouts.map { "\(str($0["name"])) \(Int(num($0["minutes"]) ?? 0)) min" }.joined(separator: ", ")
        let notes = str(store.doc["notes"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefs = dict(store.doc["prefs"])
        let loves = (prefs["loves"] as? [String] ?? []).joined(separator: ", "), avoid = (prefs["avoid"] as? [String] ?? []).joined(separator: ", ")
        var c = notes.isEmpty ? "" : "About this person, in their own words (respect it in every suggestion): \(notes)\n"
        c += "They live in \(Plan.country): use the usual portion sizes there (how big a chicken thigh, a steak, a slice of bread or a glass of wine typically is). Today: budget \(Int(store.budgetToday)) kcal, eaten \(Int(eaten)) kcal (\(list.isEmpty ? "nothing yet" : list)), \(Int(store.budgetToday - eaten)) kcal left. "
        c += "Protein so far \(Int(m.p)) g\(store.proteinGoal.map { " of \(Int($0)) g" } ?? ""), carbs \(Int(m.c)) g, fat \(Int(m.f)) g. Workouts today: \(wk.isEmpty ? "none" : wk). Weight \(Fmt.one(store.latestWeight?.kg ?? store.weightKg)) kg.\n"
        c += "Recent days, by meal (when they mention a past meal, find it here by the meal they name: yesterday's dinner is under Yesterday, Dinner):\n\(past.isEmpty ? "none yet" : past)\n"
        if !chats.isEmpty { c += "Their other chats with you in the last 3 days (when they mention food from before, it may be here):\n\(chats)\n" }
        c += "Things they often have: \(store.quickEntries.prefix(8).map(\.name).joined(separator: ", ")). Their saved meals: \(meals.isEmpty ? "none" : meals).\n"
        if !loves.isEmpty || !avoid.isEmpty { c += "Foods they love: \(loves.isEmpty ? "not said" : loves). Never suggest: \(avoid.isEmpty ? "nothing" : avoid).\n" }
        c += store.habitsContext
        if let next = store.nextCheat { c += "Their next cheat day is \(next.date == store.today ? "today" : next.date), with \(Int(next.kcal)) kcal.\n" }
        return c
    }

    static let rules = """
    Decide what they want and fill exactly one of estimate / plan / edit / recipe / lighter (leave the others empty), or kind=answer for a plain question:
    - estimate: a food or plate to log, as one portion with honest kcal and macros, broken into parts (each component with its cooked grams; oil, butter and sauce as separate parts).
    - plan: 3 to 5 things for the rest of today that fit the calories left, close the protein gap as far as sensible, and leave room for one treat.
    - edit: they're correcting today's list ("I only had 2 eggs", "remove the toast", "add a banana"), or naming several separate foods at once ("110g cabbage, 170g cucumber": one add each): target is the name of the item on today's list to change or remove; for add and update give the plain food name, its grams and the new kcal and macros. Or logging exercise: action workout with activity (Walk, Run, Cycle, Swim, Gym weights, HIIT, Yoga / stretch, Football, Tennis / padel, Hike, Rowing, Elliptical, Dance, Boxing, Climbing), minutes and effort (easy, moderate, hard).
    - recipe: a dish to cook with realistic ingredient amounts, kcal and macros per ingredient (standard reference values, so they add up), and short method steps. Respect any calorie limit they give.
    - lighter: a lighter way to have something, with tips and the lighter serving's numbers.
    - "How much X can I have" (for some calories, or what's left): an estimate of that amount, so they can add it with one tap.
    Hard rules:
    - The kind you pick must come with its filled object (kind=edit with edit.actions, kind=estimate with estimate, and so on): the app shows the buttons from it. Never mention a button the object doesn't make.
    - If they give numbers themselves (calories, grams, protein), use exactly those numbers.
    - A nutrition label in the photos or chat beats any food table: work from its per 100 g figures (a raw label eaten cooked: divide by the cooked weight left, about 0.75 for roasted meat) and set numbers_from to label. Keep using it for later amounts of the same food.
    - More of a food they've logged before or you worked out in another chat ("that chicken from dinner yesterday"): scale it from those numbers (per gram) and set numbers_from to them.
    - A specific packaged product they name or show (a brand's ice block, bar, biscuit, drink) is one part, never split into ingredients. With no label in sight (a wrapper, the front of a pack): numbers_from brand, servings how many they had, its full brand and product name as the part's name, so the app can look its label up. Mention they can photograph the nutrition panel or scan the box's barcode for exact numbers.
    - Name foods the way they did ("Aldi brushed potato", not the food table's "Coliban potato"); the table is for the numbers.
    - Keep the cooking they said, and put it in each part's name so it's checked against the right food: "pan fried, no oil" is "Potato, pan fried, no oil", never boiled.
    - Calories must fit the macros: kcal ≈ 4 × protein + 4 × carbs + 9 × fat (a little over for fibre or alcohol). Check every part before answering.
    - \(Sanity.amounts) Meat and fish by weight, not "1 thigh": say the grams you assumed.
    - For edit: never say a change is done, added or logged. Say it's ready and to tap Make these changes.
    - Only talk about foods actually in the conversation, their photos, their day or their meals. Never invent placeholders.
    - Log only what their latest message (or its photos) names. Foods from earlier in the chat or already on today's list are dealt with: never add them again or fold them into a new estimate. "1/2 tsp sesame oil" is just the oil.
    - When several products are in the photos, give each its own numbers before recommending.
    - If you can't tell what something is, say so and ask rather than guessing.
    - Keep reply short, friendly and never preachy. It's a cheat-day app: treats are part of the plan.
    """

    /// Words that mean a bigger job (worth the careful model): recipes, plans, comparisons, lighter versions.
    private static let bigJobs = ["recipe", "plan", "cook", "make me", "week", "cheat day", "lighter", "compare", "swap", "instead", "meal prep", "ideas", "suggest"]

    /// A plain "what's in this / log this" message, with no photo: the quick model answers it.
    static func isSimple(_ text: String, hasPhotos: Bool) -> Bool {
        guard !hasPhotos else { return false }
        let t = text.lowercased()
        return t.count <= 140 && !bigJobs.contains(where: { t.contains($0) })
    }

    /// Ask, then check an estimate's parts against the food list and database afterwards (`ground` false: the caller does it later).
    @MainActor
    static func ask(_ turns: [Turn], store: Store, ground groundNow: Bool = true) async throws -> JSON {
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
        parts.append(["text": "You are the assistant inside a cheat-day food diary app called Cheat Days. \(context(store, skip: turns.first { $0.me }?.text ?? ""))\(earlier.isEmpty ? "" : "Recent conversation:\n\(earlier)\n")They now say: \"\(last.text)\"\(last.images.isEmpty && !pics.isEmpty ? " (about the photos from earlier)" : "")\n\(foodData(last.text))\n\(rules)"])
        // Claude for everything (Apple's on-device model made up foods: "1/2 tsp sesame oil" came back as roasted cauliflower).
        // Simple logs and questions go to the quick model; photos, recipes and plans to the careful one.
        let simple = isSimple(last.text, hasPhotos: !pics.isEmpty)
        var answer = try await Gemini.ask(schema: schema, parts: parts, quick: simple, job: simple ? "logs" : pics.isEmpty ? "chat" : "photos")
        // "Tap Make these changes" with no changes to tap: the reply said edit but left the edit out. Asked once more.
        if missingCard(answer) { answer = (try? await Gemini.ask(schema: schema, parts: parts, quick: simple, job: simple ? "logs" : pics.isEmpty ? "chat" : "photos")) ?? answer }
        if missingCard(answer) { answer["kind"] = "answer"; answer["reply"] = withoutButtons(str(answer["reply"])) }
        // "Add to lunch": the buttons add to the meal they named, not the one the screen was opened for
        if let m = Meals.named(in: last.text) { answer["meal"] = m }
        if groundNow, str(answer["kind"]) == "estimate", let e = answer["estimate"] as? JSON { answer["estimate"] = await ground(e) }
        // a recipe's ingredients checked like the recipe screen's
        if str(answer["kind"]) == "recipe", var rc = answer["recipe"] as? JSON {
            rc["ingredients"] = FoodReference.checked(CheatDays.list(rc["ingredients"])).items
            answer["recipe"] = rc
        }
        if groundNow, let target = calorieTarget(last.text) { answer = fitToCalories(answer, target: target) }
        return saneEdit(await groundEdit(answer))
    }

    /// The real numbers for the foods their message names, looked up before Claude answers so it works from them
    /// instead of remembering (it said 30 kcal per 100 g of watermelon; the tables say 31).
    static func foodData(_ text: String) -> String {
        let found = FoodTable.current.named(in: text)
        guard !found.isEmpty else { return "" }
        let lines = found.map { x in
            "- \"\(x.said)\": \(x.food.name): \(Fmt.one(x.food.kcal)) kcal, protein \(Fmt.one(x.food.p)) g, carbs \(Fmt.one(x.food.c)) g, fat \(Fmt.one(x.food.f)) g"
        }.joined(separator: "\n")
        return "Food data for what they named, per 100 g, from the official food tables for \(Plan.country):\n\(lines)\nWhen one of these is the food they mean, use its numbers exactly (in answers too) and work amounts out from them; never a remembered value. Ignore any that's a different food from what they mean (raw versus cooked, a different dish).\n"
    }

    /// The answer's kind names a card (estimate, plan, edit, recipe, lighter) that isn't there, or has nothing in it.
    static func missingCard(_ answer: JSON) -> Bool {
        let kind = str(answer["kind"])
        guard ["estimate", "plan", "edit", "recipe", "lighter"].contains(kind) else { return false }
        guard let card = answer[kind] as? JSON else { return true }
        switch kind {
        case "estimate": return (num(card["kcal_total"]) ?? 0) <= 0 && CheatDays.list(card["parts"]).isEmpty
        case "plan": return CheatDays.list(card["suggestions"]).isEmpty
        case "edit": return CheatDays.list(card["actions"]).isEmpty
        case "recipe": return CheatDays.list(card["ingredients"]).isEmpty
        default: return str(card["name"]).isEmpty
        }
    }

    /// A reply whose card never came: the sentences sending them to a button go, since there's no button.
    static func withoutButtons(_ reply: String) -> String {
        let sentences = reply.replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let kept = sentences.filter { $0.range(of: #"\btap\b"#, options: [.regularExpression, .caseInsensitive]) == nil }
        return kept.isEmpty || kept.count == sentences.count ? reply : kept.joined(separator: " ")
    }

    /// "How much watermelon for my last 88 calories?": the calories they named, when they didn't name an amount too.
    static func calorieTarget(_ text: String) -> Double? {
        let t = text.lowercased()
        guard t.range(of: #"\d\s*(g|grams?|ml|kg)\b"#, options: .regularExpression) == nil,
              let r = t.range(of: #"(\d+(\.\d+)?)\s*(kcal|cals?|calories)\b"#, options: .regularExpression) else { return nil }
        return Double(t[r].prefix { $0.isNumber || $0 == "." })
    }

    /// A one-food estimate whose checked numbers moved off the calories they asked for (265 g of watermelon is 82 kcal,
    /// not 88): the grams change instead, so the answer is the amount that really gives those calories.
    static func fitToCalories(_ answer: JSON, target: Double) -> JSON {
        guard str(answer["kind"]) == "estimate", var e = answer["estimate"] as? JSON, target > 0 else { return answer }
        var parts = CheatDays.list(e["parts"])
        guard parts.count == 1, str(parts[0]["src"]) != "ai", let g = pos(parts[0]["grams"]), let k = pos(parts[0]["kcal"]),
              abs(k - target) >= 2 else { return answer }
        let f = target / k, newG = (g * f).rounded()
        parts[0]["grams"] = newG; parts[0]["kcal"] = target
        for m in ["protein_g", "carbs_g", "fat_g"] { parts[0][m] = (num(parts[0][m]) ?? 0) * f }
        e["parts"] = parts; e["portion_g"] = newG; e["kcal_total"] = target
        for m in ["protein_g", "carbs_g", "fat_g"] { e[m] = parts[0][m] }
        var out = answer
        out["estimate"] = e
        let old = String(Int(g.rounded())), reply = str(answer["reply"])
        out["reply"] = reply.range(of: "\\b\(old)\\b", options: .regularExpression) != nil
            ? reply.replacingOccurrences(of: "\\b\(old)\\b", with: String(Int(newG)), options: .regularExpression)
            : "That's about \(Int(newG)) g for \(Int(target)) kcal."
        return out
    }

    /// Foods added through an edit checked like an estimate's parts: each one with grams against the food data.
    @MainActor
    static func groundEdit(_ answer: JSON) async -> JSON {
        guard str(answer["kind"]) == "edit", var edit = answer["edit"] as? JSON else { return answer }
        var acts = CheatDays.list(edit["actions"])
        for i in acts.indices where ["add", "update"].contains(str(acts[i]["action"])) {
            let a = acts[i], name = str(a["name"]).isEmpty ? str(a["target"]) : str(a["name"])
            guard let g = pos(a["grams"]), let k = num(a["kcal"]) else { continue }
            let part: JSON = ["name": name, "grams": g, "kcal": k, "protein_g": a["protein_g"] ?? 0, "carbs_g": a["carbs_g"] ?? 0, "fat_g": a["fat_g"] ?? 0,
                              "numbers_from": a["numbers_from"] ?? ""]
            let checked = await ground(["name": name, "kcal_total": k, "parts": [part]])
            guard let p = CheatDays.list(checked["parts"]).first, !["ai", "label", "them"].contains(str(p["src"])) else { continue }
            if str(p["src"]) == "web" { acts[i]["grams"] = p["grams"] }
            acts[i]["kcal"] = num(p["kcal"]); acts[i]["protein_g"] = num(p["protein_g"]); acts[i]["carbs_g"] = num(p["carbs_g"]); acts[i]["fat_g"] = num(p["fat_g"])
            acts[i]["src"] = p["src"]
        }
        edit["actions"] = acts
        var out = answer
        out["edit"] = edit
        return out
    }

    /// A food-list or database number replaces the AI's only when it's in the same ballpark; a wildly different one means a wrong match.
    /// Except when the AI's own number is next to nothing (under 10 kcal per 100 g, like "2 kcal for 105 g of cabbage"): that's
    /// the AI being wrong, so the database wins.
    /// Now also by the kind of food (Sanity): when the two are far apart the one that fits wins, and a near-zero
    /// database value (a per-gram number read as per 100 g) never replaces a real food.
    static func plausible(_ db: Double?, aiKcal: Double, grams: Double, name: String = "") -> Bool {
        Sanity.prefersDatabase(db, aiKcal: aiKcal, grams: grams, name: name)
    }

    /// One part with checked numbers per 100 g.
    static func checked(_ part: JSON, kcal100: Double, p100: Double?, c100: Double?, f100: Double?, source: String) -> JSON {
        var x = part
        let g = num(part["grams"]) ?? 0
        x["kcal"] = (g * kcal100 / 100).rounded()
        if let p100 { x["protein_g"] = g * p100 / 100; x["carbs_g"] = g * (c100 ?? 0) / 100; x["fat_g"] = g * (f100 ?? 0) / 100 }
        x["src"] = source
        return x
    }

    /// A brand part from the label found online: so many of its servings, or its weight at the label's rate.
    static func fromLabel(_ part: JSON, _ label: JSON) -> JSON {
        guard let serving = pos(label["serving_g"]), let kcal = pos(label["kcal"]) else { return part }
        let n = pos(part["servings"]), grams = n.map { serving * $0 } ?? (pos(part["grams"]) ?? serving), f = grams / serving
        var x = part
        x["grams"] = grams.rounded(); x["kcal"] = (kcal * f).rounded()
        for m in ["protein_g", "carbs_g", "fat_g"] { x[m] = (num(label[m]) ?? 0) * f }
        x["src"] = "web"; x["source"] = label["source"] ?? ""
        return x
    }

    /// The plate's totals from its parts, once any part has been checked.
    static func totals(_ e: JSON, parts: [JSON]) -> JSON {
        guard parts.contains(where: { str($0["src"]) != "ai" }) else { var out = e; out["parts"] = parts; return out }
        func sum(_ k: String) -> Double { parts.reduce(0) { $0 + (num($1[k]) ?? 0) } }
        var out = e
        out["parts"] = parts; out["aiKcal"] = e["kcal_total"] ?? 0
        out["kcal_total"] = sum("kcal").rounded(); out["protein_g"] = sum("protein_g"); out["carbs_g"] = sum("carbs_g"); out["fat_g"] = sum("fat_g")
        out["portion_g"] = sum("grams").rounded()
        return out
    }

    /// Check each part: the app's own food list first, then the food database through the server (if it's set up).
    @MainActor
    static func ground(_ e: JSON) async -> JSON {
        var parts = CheatDays.list(e["parts"]).filter { (num($0["grams"]) ?? 0) > 0 }.map { p -> JSON in var x = p; x["src"] = "ai"; return x }
        guard !parts.isEmpty else { return e }
        var ask: [Int] = []
        for i in parts.indices {
            let x = parts[i], g = num(x["grams"]) ?? 0
            // numbers from their label or their own words win: the Portuguese chicken's label (163 kcal per 100 g cooked)
            // was swapped for a generic roast chicken's 190
            if ["label", "them"].contains(str(x["numbers_from"])) { parts[i]["src"] = x["numbers_from"]; continue }
            // a branded product: its own label from the web, or the AI's guess (44 kcal for a Monarc mango stick, label 43;
            // generic frozen yogurt made it 57)
            if str(x["numbers_from"]) == "brand" {
                if let found = await Gemini.lookUpLabel(str(x["name"])) { parts[i] = fromLabel(x, found) }
                continue
            }
            if let e = FoodReference.match(str(x["name"])) {   // a species or cut we've checked: before any list or database
                parts[i] = checked(x, kcal100: e.kcal, p100: e.p, c100: e.c, f100: e.f, source: "reference")
            } else if let f = FoodTable.current.find(str(x["name"])), plausible(f.kcal, aiKcal: num(x["kcal"]) ?? 0, grams: g, name: str(x["name"])) {
                // the official numbers for their country (AFCD, CoFID or USDA SR Legacy) before the app's list or the US database
                parts[i] = checked(x, kcal100: f.kcal, p100: f.p, c100: f.c, f100: f.f, source: FoodTable.current.src)
            } else if let row = FoodsDB.search(str(x["name"]), limit: 1).first, plausible(num(row["kcalPer100"]), aiKcal: num(x["kcal"]) ?? 0, grams: g, name: str(x["name"])) {
                parts[i] = checked(x, kcal100: num(row["kcalPer100"]) ?? 0, p100: num(row["p100"]), c100: num(row["c100"]), f100: num(row["f100"]), source: "list")
            } else { ask.append(i) }
        }
        if !ask.isEmpty {
            let names = ask.map { str(parts[$0]["usda_name"]).isEmpty ? str(parts[$0]["name"]) : str(parts[$0]["usda_name"]) }
            for start in stride(from: 0, to: ask.count, by: 10) {   // the function takes 10 at a time
                let batch = Array(ask[start..<min(start + 10, ask.count)]), asked = Array(names[start..<min(start + 10, ask.count)])
                guard let res = try? await Supabase.shared.call("/functions/v1/food", body: ["foods": asked], timeout: 8), res.1 == 200,
                      let j = (try? JSONSerialization.jsonObject(with: res.0)) as? JSON, let found = j["results"] as? [Any] else { continue }
                for (k, i) in batch.enumerated() where k < found.count {
                    guard let r = found[k] as? JSON, FoodReference.sameFood(asked: asked[k], got: str(r["name"])) else { continue }
                    let x = parts[i]
                    if plausible(num(r["kcal100"]), aiKcal: num(x["kcal"]) ?? 0, grams: num(x["grams"]) ?? 0, name: str(x["name"])) {
                        parts[i] = checked(x, kcal100: num(r["kcal100"]) ?? 0, p100: num(r["p100"]), c100: num(r["c100"]), f100: num(r["f100"]), source: "usda")
                    }
                }
            }
        }
        return sane(totals(e, parts: parts))
    }

    /// Every part through Sanity: calories that don't fit the macros are fixed from them, odd values are flagged on
    /// the card (and the totals added up again).
    static func sane(_ e: JSON) -> JSON {
        var parts = CheatDays.list(e["parts"]), flags: [String] = [], fixed = false
        for i in parts.indices {
            let x = parts[i], k = num(x["kcal"]) ?? 0
            let r = Sanity.check(name: str(x["name"]), grams: num(x["grams"]), kcal: k, p: num(x["protein_g"]), c: num(x["carbs_g"]), f: num(x["fat_g"]))
            if r.kcal != k { parts[i]["kcal"] = r.kcal; fixed = true }
            flags += r.flags
        }
        var out = e
        if fixed {
            func sum(_ k: String) -> Double { parts.reduce(0) { $0 + (num($1[k]) ?? 0) } }
            out["parts"] = parts; out["kcal_total"] = sum("kcal").rounded()
        }
        if parts.isEmpty {   // a plate with no parts: the plate itself
            let r = Sanity.check(name: str(e["name"]), grams: num(e["portion_g"]), kcal: num(e["kcal_total"]) ?? 0,
                                 p: num(e["protein_g"]), c: num(e["carbs_g"]), f: num(e["fat_g"]))
            out["kcal_total"] = r.kcal; flags += r.flags
        }
        out["flags"] = flags
        return out
    }

    /// Changes to today's list checked the same way, and the reply never says they're done before they are.
    static func saneEdit(_ answer: JSON) -> JSON {
        // "Logging it now": an estimate isn't on the list until Add is tapped either
        if str(answer["kind"]) == "estimate", saysDone(str(answer["reply"])) {
            var out = answer
            out["reply"] = "Here's my estimate: check it below and tap Add to put it on today's list."
            return out
        }
        guard str(answer["kind"]) == "edit", var edit = answer["edit"] as? JSON else { return answer }
        var acts = CheatDays.list(edit["actions"]), flags: [String] = []
        for i in acts.indices where ["add", "update"].contains(str(acts[i]["action"])) {
            let a = acts[i]
            guard let k = num(a["kcal"]) else { continue }
            let r = Sanity.check(name: str(a["name"]).isEmpty ? str(a["target"]) : str(a["name"]), grams: nil, kcal: k,
                                 p: num(a["protein_g"]), c: num(a["carbs_g"]), f: num(a["fat_g"]))
            acts[i]["kcal"] = r.kcal; flags += r.flags
        }
        edit["actions"] = acts; edit["flags"] = flags
        var out = answer
        out["edit"] = edit
        if saysDone(str(answer["reply"])) { out["reply"] = "Ready to change: check it below and tap Make these changes to confirm." }
        return out
    }

    private static func saysDone(_ reply: String) -> Bool {
        reply.range(of: #"\b(added|adding|logged|logging|removed|updated|changed|done)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
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
                let type = str(a["activity"]).isEmpty ? "Walk" : str(a["activity"]), mins = pos(a["minutes"]) ?? 30
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
