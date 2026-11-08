import Foundation

/// Choosing from a restaurant in the Assistant chat ("854 left, want Gami for dinner, what should I get?"): Claude finds
/// the restaurant's menu and what it publishes, and the app puts one of its dishes together with food from home (protein
/// powder, milk, yoghurt, ice cream) to reach what's left. The combos are worked out here, so their sums always add up.
enum Takeaway {
    /// One menu item. tier: "full" (the restaurant gives calories and protein), "energy" (kJ or kcal only: protein
    /// estimated, carbs and fat fitted to their energy), "none" (nothing published: all estimated).
    struct Item: Hashable { var name: String; var kind: String; var tier: String; var kcal, p, c, f: Double }

    /// A food from home, per 100 g (100 ml for milk), and the amounts it can come in.
    struct Home: Hashable {
        enum Kind: String { case powder, milk, yoghurt, dessert }
        var name: String; var kind: Kind; var unit: String; var kcal100, p100, c100, f100: Double; var label: Bool
        var amounts: [Double]
    }

    /// One way to have it: a menu item and how much of each home food (0 for none).
    struct Combo { var item: Item; var home: [(Home, Double)]
        var kcal: Double { item.kcal + home.reduce(0.0) { $0 + $1.0.kcal100 * $1.1 / 100 } }
        var p: Double { item.p + home.reduce(0.0) { $0 + $1.0.p100 * $1.1 / 100 } }
        var c: Double { item.c + home.reduce(0.0) { $0 + $1.0.c100 * $1.1 / 100 } }
        var f: Double { item.f + home.reduce(0.0) { $0 + $1.0.f100 * $1.1 / 100 } }
        func grams(_ k: Home.Kind) -> Double { home.filter { $0.0.kind == k }.reduce(0.0) { $0 + $1.1 } }
        /// More restaurant food and dessert, less plain powder.
        var enjoyment: Double {
            func weight(_ k: Home.Kind) -> Double {
                switch k { case .dessert: return 1; case .yoghurt: return 0.5; case .powder: return -0.5; case .milk: return 0 }
            }
            return item.kcal + home.reduce(0.0) { s, h in s + h.0.kcal100 * h.1 / 100 * weight(h.0.kind) }
        }
    }

    struct Picks { var combos: [(Combo, String)]; var low: [Item]; var sides: [Item]; var tried: Int; var meets: Bool }

    // MARK: numbers

    /// The kJ in a delivery app's item name: "Chicken Burger (2280 kJ)" is 2280.
    static func kj(in name: String) -> Double? {
        guard let m = name.range(of: #"(\d[\d,]*)\s*kj"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Double(name[m].filter(\.isNumber))
    }
    static func kcal(fromKJ kj: Double) -> Double { (kj / 4.184).rounded() }

    /// Carbs and fat scaled (never protein, which comes from the main ingredient and is the surest part) so that
    /// 4 P + 4 C + 9 F is the restaurant's own energy.
    static func fitted(kcal: Double, p: Double, c: Double, f: Double) -> (p: Double, c: Double, f: Double) {
        let p = min(p, kcal / 4), rest = kcal - 4 * p, had = 4 * c + 9 * f
        guard rest > 0 else { return (p, 0, 0) }
        if had <= 0 { return (p, rest / 2 / 4, rest / 2 / 9) }
        return (p, c * rest / had, f * rest / had)
    }

    /// Under 3 g protein per 100 kcal: eats the budget without moving protein (tteokbokki, fried rice, japchae).
    static func lowProtein(_ i: Item) -> Bool { i.kcal > 0 && i.p / i.kcal * 100 < 3 }

    /// The menu as Claude sent it, tidied: kJ from the name when that's where it is, kcal from kJ, an energy-only
    /// item's carbs and fat fitted to that energy, and "(2280 kJ)" taken out of the name.
    static func items(_ menu: JSON) -> [Item] {
        list(menu["items"]).compactMap { x in
            var name = str(x["name"]).trimmingCharacters(in: .whitespaces)
            var kj = num(x["kj"]) ?? 0
            if kj <= 0, let k = Self.kj(in: name) { kj = k }
            name = name.replacingOccurrences(of: #"\s*[(\[]?\s*\d[\d,]*\s*kj\s*[)\]]?"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
            var tier = str(x["published"]); if !["full", "energy", "none"].contains(tier) { tier = "none" }
            if kj > 0, tier == "none" { tier = "energy" }
            var k = num(x["kcal"]) ?? 0
            if kj > 0 && (tier == "energy" || k <= 0) { k = kcal(fromKJ: kj) }
            guard !name.isEmpty, k > 0 else { return nil }
            var p = max(0, num(x["protein_g"]) ?? 0), c = max(0, num(x["carbs_g"]) ?? 0), f = max(0, num(x["fat_g"]) ?? 0)
            if tier == "energy" { (p, c, f) = fitted(kcal: k, p: p, c: c, f: f) }
            let kind = ["main", "side", "drink", "dessert"].contains(str(x["kind"])) ? str(x["kind"]) : "main"
            return Item(name: name, kind: kind, tier: tier, kcal: k, p: p, c: c, f: f)
        }
    }

    // MARK: home foods

    /// What a home food is, from its name; nil for foods that aren't added to a takeaway (rice, chicken, bread).
    static func kind(_ name: String) -> Home.Kind? {
        let n = name.lowercased()
        if ["protein powder", "whey", "casein", "isolate", "powder"].contains(where: { n.contains($0) }) && !n.contains("cocoa") { return .powder }
        if ["ice cream", "gelato", "frozen yog", "froyo"].contains(where: { n.contains($0) }) { return .dessert }
        if ["yoghurt", "yogurt", "skyr", "quark"].contains(where: { n.contains($0) }) { return .yoghurt }
        if n.range(of: #"\bmilk\b"#, options: .regularExpression) != nil, !["milk choc", "milk chocolate", "coconut milk", "condensed", "powder"].contains(where: { n.contains($0) }) { return .milk }
        return nil
    }

    static func home(name: String, kcal100: Double, p100: Double, c100: Double, f100: Double, serving: Double?, label: Bool) -> Home? {
        guard let k = kind(name), kcal100 > 0 else { return nil }
        let amounts: [Double]
        switch k {
        case .powder: let s = serving.flatMap { $0 >= 10 && $0 <= 60 ? $0 : nil } ?? 30; amounts = [0, s / 2, s * 0.75, s, s * 1.5].map { ($0 * 2).rounded() / 2 }   // ½, ¾, 1, 1½ scoops
        case .milk: amounts = [0, 100, 150, 200, 250, 300]
        case .yoghurt: amounts = [0, 100, 150, 200]
        case .dessert: amounts = [0] + stride(from: 40.0, through: 120, by: 5).map { $0 }
        }
        return Home(name: name, kind: k, unit: k == .milk ? "ml" : "g", kcal100: kcal100, p100: p100, c100: c100, f100: f100, label: label, amounts: amounts)
    }

    /// Foods from home: scanned labels first, then what's been logged in the last two weeks with its per 100 g numbers;
    /// one of each kind (the most recent), so the combos stay simple.
    @MainActor static func homeFoods(_ store: Store, scans: [PantryItem]) -> [Home] {
        var out: [Home] = []
        func take(_ h: Home?) { if let h, !out.contains(where: { $0.kind == h.kind }) { out.append(h) } }
        for s in scans { take(home(name: s.name, kcal100: s.kcal100, p100: s.p100 ?? 0, c100: s.c100 ?? 0, f100: s.f100 ?? 0, serving: nil, label: true)) }
        let since = DayKey.shift(store.today, days: -14)
        let days = [store.todayItems] + list(store.doc["history"]).filter { str($0["date"]) >= since }.sorted { str($0["date"]) > str($1["date"]) }.map { list($0["items"]) }
        for items in days {
            for it in items.reversed() {
                // packaged foods only: a "Protein Yogurt Bowl" they made isn't a yoghurt from the fridge
                guard let k100 = FoodMath.kcalPer100(it), let p = num(it["p100"]), p > 0,
                      ["barcode", "label", "manual"].contains(str(it["source"])) || !str(it["brand"]).isEmpty else { continue }
                let src = str(it["source"])
                take(home(name: str(it["name"]), kcal100: k100, p100: p, c100: num(it["c100"]) ?? 0, f100: num(it["f100"]) ?? 0,
                          serving: pos(it["servingSize"]).flatMap { $0 == 100 ? nil : $0 }, label: ["barcode", "label", "manual"].contains(src)))
            }
        }
        return out
    }

    // MARK: the plan

    /// Every menu dish with every mix of the home foods, and the best three: the best fit (protein reached, calories
    /// within 10 over, then the most enjoyable among those close to the calories), the most protein, and the most
    /// restaurant food, each with a different dish. Low-protein dishes and sides that can't fit with a dish are listed
    /// apart. Asked-for dishes are used even when they don't fit, and say how far over.
    static func plan(menu: [Item], home: [Home], kcal: Double, protein: Double, want: [String] = [], avoid: [String] = [], place: String = "the menu") -> Picks {
        let avoid = avoid.map { $0.lowercased() }.filter { !$0.isEmpty }
        // "no milk": the milk goes, not the Milk Chocolate protein powder. A kind of home food is matched by its kind
        let kinds: [String: Home.Kind] = ["milk": .milk, "powder": .powder, "protein powder": .powder, "shake": .powder, "yoghurt": .yoghurt, "yogurt": .yoghurt, "ice cream": .dessert, "dessert": .dessert]
        func avoided(_ h: Home) -> Bool {
            avoid.contains { a in
                if let k = kinds.first(where: { a.contains($0.key) }) { return k.value == h.kind }
                return h.name.lowercased().contains(a)
            }
        }
        let menu = menu.filter { i in !avoid.contains { i.name.lowercased().contains($0) } }, home = home.filter { !avoided($0) }
        // dishes they asked for: "a shake and ice cream" in the same message are the foods from home, not a menu milkshake
        // and "the chicken burger" is the burger, not every chicken dish: all its words, else any of them
        func matching(_ all: Bool) -> [Item] {
            menu.filter { i in
                i.kind == "main" && want.contains { w in
                    let ws = words(w), n = i.name.lowercased()
                    return !ws.isEmpty && (all ? ws.allSatisfy { n.contains($0) } : ws.contains { n.contains($0) })
                }
            }
        }
        let wanted = want.isEmpty ? [] : matching(true).isEmpty ? matching(false) : matching(true)
        let mains = menu.filter { $0.kind == "main" && !lowProtein($0) }
        let fitting = mains.filter { $0.kcal <= kcal + 10 }
        // nothing fits what's left (196 kcal at 10 pm): the three smallest dishes, each saying how far over
        let tooBig = wanted.isEmpty && fitting.isEmpty
        let pool = !wanted.isEmpty ? wanted : tooBig ? Array(mains.sorted { $0.kcal < $1.kcal }.prefix(3)) : fitting
        let over = !wanted.isEmpty || tooBig
        let low = menu.filter { $0.kind == "main" && lowProtein($0) }.sorted { $0.kcal < $1.kcal }
        let cheapest = mains.map(\.kcal).min() ?? 0
        let sides = menu.filter { $0.kind == "side" && $0.kcal + cheapest > kcal + 10 }.sorted { $0.kcal < $1.kcal }

        // every mix of the home foods' amounts
        var mixes: [[(Home, Double)]] = [[]]
        for h in home { mixes = mixes.flatMap { m in h.amounts.map { a in m + [(h, a)] } } }
        mixes = mixes.map { $0.filter { $0.1 > 0 } }
            .filter { m in !(m.contains { $0.0.kind == .milk } && !m.contains { $0.0.kind == .powder }) }   // milk only in a shake
            .filter { m in m.filter { $0.0.kind != .milk }.count <= 2 }   // a shake and one more at most, not shake, yoghurt and ice cream
        var tried = 0, best: [Combo] = []
        for item in pool {
            let all = mixes.map { Combo(item: item, home: $0) }; tried += all.count
            let fits = over ? all : all.filter { $0.kcal <= kcal + 10 }
            if let b = pick(fits, kcal: kcal, protein: protein, over: over) { best.append(b) }
        }
        guard !best.isEmpty else { return Picks(combos: [], low: low, sides: sides, tried: tried, meets: false) }
        let first = pick(best, kcal: kcal, protein: protein, over: over)!
        var out: [(Combo, String)] = [(first, "Best fit")]
        var rest = best.filter { $0.item != first.item }
        if let m = rest.filter({ $0.kcal <= kcal + 10 }).max(by: { $0.p < $1.p }), m.p > first.p + 2 { out.append((m, "Most protein")); rest.removeAll { $0.item == m.item } }
        while out.count < 3, let n = pick(rest, kcal: kcal, protein: protein, over: over) {
            let note = n.item.kcal > first.item.kcal + 20 ? "More from " + place : n.grams(.dessert) > 0 && first.grams(.dessert) == 0 ? "With dessert" : ""
            out.append((n, note)); rest.removeAll { $0.item == n.item }
        }
        return Picks(combos: out, low: Array(low.prefix(4)), sides: Array(sides.prefix(4)), tried: tried, meets: first.p >= protein - 0.5)
    }

    /// The best of some combos: those reaching the protein, close to the calories (within 60 under), the most enjoyable;
    /// else the closest to the calories; with none reaching the protein, the most protein. Over the calories only when
    /// a dish was asked for, and then the least over.
    static func pick(_ cs: [Combo], kcal: Double, protein: Double, over: Bool) -> Combo? {
        let meets = cs.filter { $0.p >= protein - 0.5 }
        if over, !meets.isEmpty, meets.allSatisfy({ $0.kcal > kcal + 10 }) { return meets.min { ($0.kcal, -$0.enjoyment) < ($1.kcal, -$1.enjoyment) } }
        let fit = meets.filter { $0.kcal <= kcal + 10 }
        if !fit.isEmpty {
            let close = fit.filter { kcal - $0.kcal <= 60 }
            if !close.isEmpty { return close.max { ($0.enjoyment, -abs(kcal - $0.kcal)) < ($1.enjoyment, -abs(kcal - $1.kcal)) } }
            return fit.min { abs(kcal - $0.kcal) < abs(kcal - $1.kcal) }
        }
        return cs.max { ($0.p, -$0.kcal) < ($1.p, -$1.kcal) }
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 && !["want", "some", "with", "have", "like", "this", "that", "these", "those", "just"].contains($0) }
            .map { $0.hasSuffix("s") && $0.count > 4 ? String($0.dropLast()) : $0 }
    }

    // MARK: the card

    /// A combo for the card and the chat record: its lines (a dish, a shake of powder and milk, a yoghurt, a dessert),
    /// each with the foods it adds, and the totals added up from them.
    static func json(_ c: Combo, note: String, restaurant: String, kcal: Double) -> JSON {
        func food(_ h: Home, _ a: Double) -> JSON {
            ["name": h.name, "grams": a, "unit": h.unit, "kcal": (h.kcal100 * a / 100).rounded(), "p": h.p100 * a / 100, "c": h.c100 * a / 100, "f": h.f100 * a / 100]
        }
        // "30 g powder + 150 ml milk": the shake's parts by what they are, their full names on the foods it adds
        func amount(_ h: Home, _ a: Double) -> String { "\(Fmt.one(a)) \(h.unit) \(h.kind == .powder ? "powder" : h.kind == .milk ? "milk" : h.name)" }
        let i = c.item
        var lines: [JSON] = [["name": i.name, "detail": "", "tag": i.tier, "kcal": i.kcal.rounded(), "p": i.p,
                              "add": [["name": "\(restaurant) \(i.name)", "grams": 0, "unit": "g", "kcal": i.kcal.rounded(), "p": i.p, "c": i.c, "f": i.f] as JSON]]]
        let powder = c.home.first { $0.0.kind == .powder }, milk = c.home.first { $0.0.kind == .milk }
        if let powder {
            let parts = [powder] + (milk.map { [$0] } ?? [])
            lines.append(["name": milk == nil ? "Protein shake, water" : "Protein shake", "detail": parts.map { amount($0.0, $0.1) }.joined(separator: " + "),
                          "tag": parts.allSatisfy { $0.0.label } ? "label" : "log", "kcal": parts.reduce(0.0) { $0 + $1.0.kcal100 * $1.1 / 100 }.rounded(),
                          "p": parts.reduce(0.0) { $0 + $1.0.p100 * $1.1 / 100 }, "add": parts.map { food($0.0, $0.1) }])
        }
        for (h, a) in c.home where h.kind == .yoghurt || h.kind == .dessert {
            lines.append(["name": h.name, "detail": "\(Fmt.one(a)) \(h.unit)", "tag": h.label ? "label" : "log",
                          "kcal": (h.kcal100 * a / 100).rounded(), "p": h.p100 * a / 100, "add": [food(h, a)]])
        }
        // "Chicken Burger, shake and ice cream"
        var bits = [i.name.components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? i.name]
        if let _ = powder { bits.append(milk == nil ? "a water shake" : "shake") }
        for (h, _) in c.home where h.kind == .yoghurt { bits.append("yoghurt") }
        for (h, _) in c.home where h.kind == .dessert { bits.append(h.name.lowercased().contains("gelato") ? "gelato" : "ice cream") }
        let title = bits.count > 1 ? bits.dropLast().joined(separator: ", ") + " and " + bits.last! : bits[0]
        // where the numbers came from, once under the card rather than a tag on every line; amber when the dish was guessed
        let dish = bits[0], warn = i.tier == "none"
        let fromDish = i.tier == "full" ? "\(dish) from \(restaurant)'s menu"
                     : i.tier == "energy" ? "\(dish) from \(restaurant)'s kJ, protein estimated"
                     : "\(dish) estimated: its kJ wasn't on \(restaurant)'s listing. Type it or send a screenshot"
        let fromHome = c.home.isEmpty ? "" : c.home.allSatisfy { $0.0.label } ? " · the rest from your labels" : " · the rest from your log"
        return ["title": title, "note": note, "lines": lines, "kcal": c.kcal.rounded(), "p": c.p.rounded(), "c": c.c.rounded(), "f": c.f.rounded(),
                "over": max(0, c.kcal - kcal).rounded(), "source": fromDish + fromHome, "warn": warn]
    }

    // MARK: asking

    private static let s: JSON = ["type": "string"], n: JSON = ["type": "number"]
    /// tools/ai-test/intent-check.js: 54 of 54 right over 18 ways of saying it (choose, log or other), where a yes/no
    /// "is it takeaway" missed "tomorrow" and "I'd like…"
    static let routeSchema: JSON = ["type": "object", "required": ["intent", "restaurant", "area", "want", "avoid", "seen", "kcal", "protein"], "properties": [
        "intent": ["type": "string", "enum": ["choose", "log", "other"]] as JSON, "restaurant": s, "area": s, "want": ["type": "array", "items": s] as JSON,
        "avoid": ["type": "array", "items": s] as JSON,
        "seen": ["type": "array", "items": ["type": "object", "required": ["name", "kj"], "properties": ["name": s, "kj": n] as JSON] as JSON] as JSON,
        "kcal": n, "protein": n] as JSON]
    static let menuSchema: JSON = ["type": "object", "required": ["found", "restaurant", "source", "items"], "properties": [
        "found": ["type": "boolean"] as JSON, "restaurant": s, "source": s,
        "items": ["type": "array", "items": ["type": "object", "required": ["name", "kind", "published", "kj", "kcal", "protein_g", "carbs_g", "fat_g"], "properties": [
            "name": s, "kind": ["type": "string", "enum": ["main", "side", "drink", "dessert"]] as JSON,
            "published": ["type": "string", "enum": ["full", "energy", "none"]] as JSON,
            "kj": n, "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n] as JSON] as JSON] as JSON] as JSON]

    /// Kept word for word with the scripts that tested them against Claude: routeAsk with tools/ai-test/intent-check.js,
    /// menuAsk with menu-check.js.
    static func routeAsk(_ message: String, earlier: String, photo: String = "") -> String {
        """
        A message to the assistant in a food diary app\(photo.isEmpty ? "" : ", with a photo of \(photo)"). What is it?
        choose: they're deciding what to have from one particular restaurant, takeaway, café or chain, today or another day, however they put it ("Gami tonight?", "thinking Nando's for lunch tomorrow", "what's good at Guzman for 600 cals", "can I fit a Gami burger in today?", "heading to Maccas, what should I get", "want something from the Gami in Windsor tomorrow, what are my options", "I'd like the burger from Gami with a shake": what they'd like, not what they had).
        log: they're telling you what they ate or are eating, to add it ("had a Gami burger for lunch", "Gami chicken burger", "just had Nando's"), or correcting a log.
        other: anything else, including choosing food with no particular restaurant ("what should I have for dinner?") and questions.
        When the conversation so far was choosing from a restaurant, a reply changing that choice ("no milk left, I want the wings") is choose, with that restaurant.\(photo.isEmpty ? "" : " With a photo of a menu or delivery-app page, naming a dish on it for a meal (\"this burger for dinner\") is choose, unless they say they had or ate it.")
        \(earlier.isEmpty ? "" : "The conversation so far:\n\(earlier)\n")Their message: "\(message)"
        restaurant: its name as they wrote it, else empty. area: a suburb or city if they said one, else empty. want: menu items they say they want, in their words. avoid: foods they don't want or don't have in ("milk"), in their words. seen: dishes they quote from a menu or delivery app with their energy ("Chicken Burger (2280 kJ)"), each with its kJ (kcal × 4.184 if they gave kcal), else empty. kcal and protein: numbers they gave for what they have left or for this meal ("854 left" is kcal 854), else 0.
        """
    }
    static func menuAsk(_ restaurant: String, area: String, want: [String], seen: [String] = []) -> String {
        """
        Find the current menu of "\(restaurant)"\(area.isEmpty ? "" : " in \(area)"), a restaurant, takeaway or chain in \(Plan.country), and the nutrition it publishes. Look first at its listing on DoorDash, Uber Eats or Menulog, which has the full current menu and where chains put kJ in each item's name ("Chicken Burger (2280 kJ)"), then its own website or nutrition PDF.\(want.isEmpty ? "" : " They want: \(want.joined(separator: ", ")). Make sure those dishes are in the list if it sells them, with the kJ its listing shows today, not an old menu's.")\(seen.isEmpty ? "" : " They read these on its listing today: \(seen.joined(separator: ", ")). List each with exactly that kJ, and estimate its protein, carbs and fat for that energy.") List up to 30 of its items, mains first, each as one serving as sold (with its size or pieces in the name, "Original tenders, 4 pcs").
        For each item: published is full when the restaurant gives its calories and protein, energy when it gives only kJ or kcal, none when it gives nothing. kj: exactly as published, else 0. kcal: as published, else kJ ÷ 4.184, else your estimate. protein_g, carbs_g and fat_g: as published, else your honest estimate from what the item is and its usual portion. kind: main, side, drink or dessert.
        found false if you can't find its menu at all. source: where the numbers came from, a few words. Open the restaurant's DoorDash or Uber Eats store page with web_fetch and read the kJ from the item names there. When sources disagree, the delivery listing is today's menu: use its number. Never guess a kJ: an item whose energy you didn't read on a page has kj 0 and published none.
        """
    }

    /// The dishes they asked for, without the foods from home they named with them ("a shake and ice cream").
    static func dishes(_ want: [String]) -> [String] {
        want.filter { w in kind(w) == nil && !["shake", "milk", "ice cream", "yoghurt", "yogurt"].contains { w.lowercased().contains($0) } && !words(w).isEmpty }
    }

    /// Is a dish they named on this menu: all its words in an item's name.
    static func has(_ items: [Item], _ dish: String) -> Bool {
        let ws = words(dish)
        return items.contains { i in ws.allSatisfy { i.name.lowercased().contains($0) } }
    }

    /// With a photo of a menu page: choosing from it ("this burger for dinner", "what should I get?") rather than logging
    /// what they had ("had this for lunch").
    static func choosing(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        if t.range(of: #"\b(had|ate|eaten|just finished|was having)\b"#, options: .regularExpression) != nil { return false }
        return t.contains("?") || t.range(of: #"\b(for (dinner|lunch|tea|breakfast|brekkie|tonight)|want|wanna|fancy|craving|i'?d like|should|what|which|can i|plan|order|ordering|getting|thinking)\b"#, options: .regularExpression) != nil
    }

    /// A restaurant's menu, kept on the phone for a week, so asking again costs nothing; looked up again when a dish
    /// they ask for isn't on the one kept (Gami's 2026 PDF had no Chicken Burger; its DoorDash listing does).
    /// Asked again too when they quote a dish's kJ that the kept one doesn't have at about that energy, so its protein
    /// is estimated for the size they're getting.
    @MainActor static func menu(_ restaurant: String, area: String, want: [String] = [], seen: [JSON] = []) async -> JSON? {
        let key = "\(restaurant)|\(area)".lowercased(), d = UserDefaults.standard
        var kept = (d.dictionary(forKey: "takeaway.menus") as? [String: JSON]) ?? [:]
        let wanted = dishes(want)
        let quoted = seen.map { "\(str($0["name"])) (\(Fmt.int(num($0["kj"]) ?? 0)) kJ)" }
        func matches(_ m: JSON) -> Bool {
            let its = items(m)
            return wanted.allSatisfy { has(its, $0) } && seen.allSatisfy { s in
                let ws = words(str(s["name"])), k = kcal(fromKJ: num(s["kj"]) ?? 0)
                return its.contains { i in ws.allSatisfy { i.name.lowercased().contains($0) } && abs(i.kcal - k) <= k * 0.15 }
            }
        }
        if let k = kept[key], let at = num(k["at"]), Date().timeIntervalSince1970 - at < 7 * 86400, let m = k["menu"] as? JSON, matches(m) { return m }
        // the menu job opens the delivery app's page; a server from before it has only the label lookup's two searches
        let ask: [JSON] = [["text": menuAsk(restaurant, area: area, want: wanted, seen: quoted)]], country: JSON = ["country": Region.current.code]
        let fetched = await Gemini.askClaude("menu", schema: menuSchema, parts: ask, extra: country)
        guard let m = fetched != nil ? fetched : await Gemini.askClaude("lookup", schema: menuSchema, parts: ask, extra: country),
              m["found"] as? Bool == true, !items(m).isEmpty else { return nil }
        kept = kept.filter { Date().timeIntervalSince1970 - (num($0.value["at"]) ?? 0) < 7 * 86400 }
        kept[key] = ["at": Date().timeIntervalSince1970, "menu": m]
        if let ok = try? JSONSerialization.data(withJSONObject: kept), ok.count < 400_000 { d.set(kept, forKey: "takeaway.menus") }
        return m
    }

    /// The kJ they read off the listing themselves ("Chicken Burger (2280 kJ)") beat what the lookup found (6,888 kJ from an
    /// old menu): the dish takes their kJ, its protein kept and carbs and fat fitted to it; a dish the menu didn't have is
    /// added, its protein from the closest dish on the menu (a share of the energy like it), else 5 g per 100 kcal.
    /// With want, only the dishes they want are added (chips on the page aren't a main to build a meal on).
    static func withSeen(_ menu: [Item], _ seen: [JSON], want: [String]? = nil) -> [Item] {
        var out = menu
        for s in seen {
            let name = str(s["name"]).replacingOccurrences(of: #"\s*[(\[]?\s*\d[\d,]*\s*kj\s*[)\]]?"#, with: "", options: [.regularExpression, .caseInsensitive])
            let k = kcal(fromKJ: num(s["kj"]) ?? 0), ws = words(name)
            guard k > 0, !ws.isEmpty else { continue }
            if let i = out.firstIndex(where: { it in ws.allSatisfy { it.name.lowercased().contains($0) } }) {
                // close to their kJ: Claude's protein was for this size; far off (another size or a combo): in proportion
                let it = out[i], near = abs(it.kcal - k) <= k * 0.15
                let f = fitted(kcal: k, p: near ? it.p : it.p * k / max(it.kcal, 1), c: it.c, f: it.f)
                out[i] = Item(name: it.name, kind: it.kind, tier: "energy", kcal: k, p: f.p, c: f.c, f: f.f)
            } else if want.map({ w in dishes(w).contains { d in words(d).contains { name.lowercased().contains($0) } } }) ?? true {
                let like = out.first { it in it.kind == "main" && ws.contains { it.name.lowercased().contains($0) } }
                let p = like.map { $0.p / max($0.kcal, 1) * k } ?? k * 0.05
                let f = fitted(kcal: k, p: p, c: like?.c ?? 0, f: like?.f ?? 0)
                out.insert(Item(name: name.trimmingCharacters(in: .whitespaces), kind: "main", tier: "energy", kcal: k, p: f.p, c: f.c, f: f.f), at: 0)
            }
        }
        return out
    }

    /// The answer to a takeaway question, or nil when it isn't one (or Claude can't be reached): the assistant answers.
    @MainActor
    /// With a photo of a delivery-app page (Gami's Chicken Burger, 2280 kJ, on DoorDash), what the quick look read off it
    /// goes along: its dishes' kJ win, and a dish named in the message ("this burger") is the one wanted.
    static func answer(_ turns: [Assistant.Turn], store: Store, step: (@MainActor (String, String) -> Void)?, photo: Assistant.Spotted? = nil) async -> JSON? {
        // every typed message is asked (no list of words to say first): it runs alongside the assistant's own answer
        guard let last = turns.last, last.me, last.images.isEmpty || photo != nil else { return nil }
        let earlier = turns.dropLast().suffix(6).map { t -> String in
            if t.me { return "They asked: \(t.text)" }
            if let ta = t.result?["takeaway"] as? JSON { return "You suggested from \(str(ta["restaurant"])): " + list(ta["combos"]).map { str($0["title"]) }.joined(separator: "; ") }
            return "You: \(t.text.prefix(200))"
        }.joined(separator: "\n")
        let page = photo.map { p in "a menu page\(p.shop.isEmpty ? "" : " from \(p.shop)") showing " + p.listing.map { "\(str($0["name"])) (\(Fmt.int(num($0["kj"]) ?? 0)) kJ)" }.joined(separator: ", ") } ?? ""
        // with a menu page, choosing or logging is decided here: Claude called "this burger for dinner" a log one time in three
        if photo != nil, !choosing(last.text) { return nil }
        guard let route = await Gemini.askClaude("quick", schema: routeSchema, parts: [["text": routeAsk(last.text, earlier: earlier, photo: page)]]),
              // choose; or a restaurant named in a question or a wish, nothing they had, in case it's called something else
              photo != nil || str(route["intent"]) == "choose" || (!str(route["restaurant"]).isEmpty && choosing(last.text)) else { return nil }
        let said = str(route["restaurant"]).trimmingCharacters(in: .whitespaces)
        // "gami Windsor" as "Gami Windsor": a word typed all in lower case gets its capital
        let name = (said.isEmpty ? (photo?.shop ?? "") : said).split(separator: " ").map { w in w == w.lowercased() ? w.prefix(1).uppercased() + w.dropFirst() : String(w) }.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        step?("Asked about \(name)", "Finding \(name)'s menu…")
        var seen = list(route["seen"]).filter { (num($0["kj"]) ?? 0) > 0 && !str($0["name"]).isEmpty }
        for l in photo?.listing ?? [] where !seen.contains(where: { str($0["name"]).lowercased() == str(l["name"]).lowercased() }) { seen.append(l) }
        var want = route["want"] as? [String] ?? []
        // "this burger for dinner" with the page: the dish on it that the message names, else the page's first
        if let p = photo, dishes(want).isEmpty, let first = p.listing.first {
            let named = p.listing.first { l in words(str(l["name"])).contains { last.text.lowercased().contains($0) } }
            want.append(str((named ?? first)["name"]))
        }
        guard let m = await menu(name, area: str(route["area"]), want: want, seen: seen) else {
            return ["kind": "answer", "reply": "I couldn't find \(name)'s menu online. Tell me what's on it (the names and kJ from the app you order on) and I'll put it together."]
        }
        let menuItems = withSeen(items(m), seen, want: want), shown = name   // their own name for it reads better than "Gami Chicken (Gami Chicken & Beer)"
        let energyOnly = menuItems.filter { $0.tier == "energy" }.count * 2 >= menuItems.count, full = menuItems.allSatisfy { $0.tier == "full" }
        let every = menuItems.allSatisfy { $0.tier != "none" } ? "every item" : "most items"
        let found = full ? "Found \(shown)'s menu with its nutrition" : energyOnly ? "Found \(shown)'s menu: kJ on \(every)" : "Found \(shown)'s menu"
        let scans = PantryItem.Saved.load(UserDefaults.standard.string(forKey: "pantry.scans") ?? "[]")
        let home = homeFoods(store, scans: scans)
        step?(found, home.isEmpty ? "Putting it together…" : "Adding what you have at home…")

        // what to aim for: their own numbers, else everything left at dinner, else this meal's share
        let hour = Calendar.current.component(.hour, from: Date())
        let meal = Meals.named(in: last.text) ?? (hour < 11 ? "Breakfast" : hour < 16 ? "Lunch" : "Dinner")
        let left = max(0, store.budgetToday - store.eaten), share = store.mealTarget(meal)
        let pLeft = store.proteinGoal.map { max(0, $0 - store.macros(store.todayItems).p) }
        // for tomorrow: that meal's usual share of a whole day, not what's left tonight
        let tomorrow = last.text.lowercased().contains("tomorrow")
        let usual = ["Breakfast": 0.25, "Lunch": 0.30, "Dinner": 0.35][meal] ?? 0.3
        let kcal = pos(route["kcal"]) ?? (tomorrow ? (store.budgetToday * usual / 10).rounded() * 10 : meal == "Dinner" ? left : share.kcal)
        let protein = pos(route["protein"]) ?? (tomorrow ? store.proteinGoal.map { ($0 * usual).rounded() } : (meal == "Dinner" ? pLeft : share.protein).map { $0.rounded() }) ?? 30
        let avoid = route["avoid"] as? [String] ?? []
        // food from home only when they bring it up ("with a shake", "and ice cream", a protein number): "want something
        // from Gami tomorrow" came back with a protein shake and ice cream nobody asked for
        let talk = ([last.text, earlier] + want + avoid).joined(separator: " ")
        let homeToo = asksForHome(talk) || pos(route["protein"]) != nil
        let p = plan(menu: menuItems, home: homeToo ? home : [], kcal: kcal, protein: protein, want: want, avoid: avoid, place: shown)

        let smallest = menuItems.filter { $0.kind == "main" }.map { $0.kcal }.min() ?? 0
        return result(p, home: homeToo ? home : [], tips: homeToo ? [] : home, menu: menuItems, shown: shown, kcal: kcal, protein: protein, meal: meal,
                      smallest: smallest, source: str(m["source"]))
    }

    /// They brought up food from home: a shake, ice cream, yoghurt, milk, powder or "from home".
    static func asksForHome(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["shake", "ice cream", "gelato", "yoghurt", "yogurt", "milk", "powder", "from home", "at home", "kenny"].contains { t.contains($0) }
    }

    /// Other dishes to swap in (⇄), closest in size first: the mains, not the low-protein ones.
    static func swaps(for dish: Item, in menu: [Item]) -> [JSON] {
        menu.filter { $0.kind == "main" && $0 != dish && !lowProtein($0) }
            .sorted { abs($0.kcal - dish.kcal) < abs($1.kcal - dish.kcal) }.prefix(6)
            .map { ["name": $0.name, "tier": $0.tier, "kcal": $0.kcal.rounded(), "p": $0.p, "c": $0.c, "f": $0.f] as JSON }
    }

    /// A dish short of the protein, with nothing from home asked for: one shake from home offered, the smallest scoop that
    /// closes the gap (a scoop and a half at most), to add with a tap.
    static func tip(for c: Combo, protein: Double, home: [Home]) -> JSON? {
        let gap = protein - c.p
        guard gap > 0.5, let powder = home.first(where: { $0.kind == .powder }) else { return nil }
        let a = powder.amounts.filter { $0 > 0 }.first { powder.p100 * $0 / 100 >= gap } ?? powder.amounts.max() ?? 30
        let k = (powder.kcal100 * a / 100).rounded(), p = powder.p100 * a / 100
        return ["text": "Short on protein? Add a \(Fmt.one(a)) g shake from home", "more": "+\(Fmt.int(k)) kcal · +\(Int(p.rounded())) g, makes it \(Int((c.p + p).rounded())) g",
                "line": ["name": "Protein shake, water", "detail": "\(Fmt.one(a)) g powder", "tag": powder.label ? "label" : "log", "kcal": k, "p": p,
                         "add": [["name": powder.name, "grams": a, "unit": "g", "kcal": k, "p": p, "c": powder.c100 * a / 100, "f": powder.f100 * a / 100] as JSON]] as JSON]
    }

    /// The combo as they've changed it on the card: lines taken off (✕), the dish swapped for another (⇄), the tip's shake
    /// put in. Totals, how far over, and the line saying where the numbers came from all follow.
    static func edited(_ c: JSON, off: Set<Int>, dish: JSON?, tip: Bool, restaurant: String, kcal: Double) -> JSON {
        var lines = list(c["lines"]), title = str(c["title"])
        func short(_ n: String) -> String { n.components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? n }
        if let d = dish, !lines.isEmpty {
            // "Chicken Burger, shake and ice cream" → "Original tenders, shake and ice cream"
            let was = short(str(lines[0]["name"]))
            if title.hasPrefix(was) { title = short(str(d["name"])) + title.dropFirst(was.count) }
            lines[0] = ["name": str(d["name"]), "detail": "", "tag": str(d["tier"]), "kcal": num(d["kcal"]) ?? 0, "p": num(d["p"]) ?? 0,
                        "add": [["name": "\(restaurant) \(str(d["name"]))", "grams": 0, "unit": "g", "kcal": num(d["kcal"]) ?? 0, "p": num(d["p"]) ?? 0, "c": num(d["c"]) ?? 0, "f": num(d["f"]) ?? 0] as JSON]]
        }
        if tip, let t = dict(c["tip"])["line"] as? JSON { lines.append(t) }
        let on = lines.indices.filter { !off.contains($0) }
        func sum(_ k: String) -> Double { on.flatMap { list(lines[$0]["add"]) }.reduce(0.0) { $0 + (num($1[k]) ?? 0) } }
        var out = c
        out["title"] = title
        out["lines"] = lines.enumerated().map { i, l -> JSON in var x = l; x["off"] = off.contains(i); return x }
        out["kcal"] = sum("kcal").rounded(); out["p"] = sum("p").rounded(); out["c"] = sum("c").rounded(); out["f"] = sum("f").rounded()
        out["over"] = max(0, sum("kcal") - kcal).rounded()
        out["count"] = on.count
        // where the numbers came from, for what's still on the card
        let dishOn = !off.contains(0) && !lines.isEmpty, tier = dishOn ? str(lines[0]["tag"]) : ""
        let name = dishOn ? (str(lines[0]["name"]).components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? "") : ""
        let fromDish = !dishOn ? "" : tier == "full" ? "\(name) from \(restaurant)'s menu" : tier == "energy" ? "\(name) from \(restaurant)'s kJ, protein estimated"
                     : "\(name) estimated: its kJ wasn't on \(restaurant)'s listing. Type it or send a screenshot"
        let homes = on.filter { $0 > 0 }.map { str(lines[$0]["tag"]) }
        let fromHome = homes.isEmpty ? "" : homes.allSatisfy { $0 == "label" } ? "the rest from your labels" : "the rest from your log"
        out["source"] = [fromDish, fromHome].filter { !$0.isEmpty }.joined(separator: " · ")
        out["warn"] = dishOn && tier == "none"
        return out
    }

    /// What the chat shows, kept short: one sentence, one line of what it used, and the combos, each saying once where
    /// its numbers came from, with dishes to swap in and, when it's short of protein and nothing from home was asked for,
    /// one shake offered. (The low-protein and won't-fit lists were too much at once; they're left out.)
    static func result(_ p: Picks, home: [Home], tips: [Home] = [], menu: [Item] = [], shown: String, kcal: Double, protein: Double, meal: String,
                       smallest: Double, source: String = "") -> JSON {
        let names = home.map { short($0.name) }
        let mine = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? ""
        let used = "\(shown)'s menu" + (mine.isEmpty ? "" : " · your \(mine)")
        guard let top = p.combos.first?.0 else {
            return ["kind": "answer", "trail": [used], "reply": "Nothing at \(shown) fits in \(Fmt.int(kcal)) kcal. The smallest dish is \(Fmt.int(smallest)) kcal."]
        }
        let combos = p.combos.map { pick -> JSON in
            var j = json(pick.0, note: pick.1, restaurant: shown, kcal: kcal)
            j["swaps"] = swaps(for: pick.0.item, in: menu)
            if let t = tip(for: pick.0, protein: protein, home: tips) { j["tip"] = t }
            return j
        }
        let first = combos[0], title = str(first["title"]), over = num(first["over"]) ?? 0
        var reply = over > 10 ? "\(title) is \(Fmt.int(over)) kcal over what's left, but it's the closest:"
                  : p.meets ? "\(title) gets you there:" : "\(title) gets you closest, \(Fmt.int(top.p)) g of your \(Int(protein)) g protein:"
        // said first when the dish's own energy wasn't found; the card's amber line says how to give it
        if top.item.tier == "none" { reply = "I couldn't find its kJ on \(shown)'s listing, so it's estimated. " + reply }
        if home.isEmpty && tips.isEmpty && !p.meets { reply += "\n\nScan your protein powder or yoghurt in Plan a meal and I can add them from home." }
        return ["kind": "takeaway", "reply": reply, "meal": meal, "trail": [used],
                "takeaway": ["restaurant": shown, "source": source, "combos": combos, "aim": protein, "kcal": kcal] as JSON]
    }

    /// "Milk Chocolate Protein Powder" → "protein powder", for the trail.
    static func short(_ name: String) -> String {
        kind(name) == .powder ? "protein powder" : name.components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? name
    }
}
