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

    /// One way to have it: one or two of the menu's dishes, each with how much of it (½: eat half, the rest keeps), and
    /// how much of each home food (0 for none). Two dishes and a part of one came with the PUBCHA chat the owner shared
    /// (21 Nov, design/takeaway-combos-mockup.html): "the bulgogi bowl and the small chicken, eat about half of it".
    struct Combo {
        var dishes: [(Item, Double)]
        var home: [(Home, Double)]
        init(item: Item, home: [(Home, Double)]) { dishes = [(item, 1)]; self.home = home }
        init(dishes: [(Item, Double)], home: [(Home, Double)] = []) { self.dishes = dishes; self.home = home }
        var item: Item { dishes[0].0 }
        private func sum(_ v: (Item) -> Double, _ h: (Home) -> Double) -> Double {
            dishes.reduce(0.0) { $0 + v($1.0) * $1.1 } + home.reduce(0.0) { $0 + h($1.0) * $1.1 / 100 }
        }
        var kcal: Double { sum({ $0.kcal }, { $0.kcal100 }) }
        var p: Double { sum({ $0.p }, { $0.p100 }) }
        var c: Double { sum({ $0.c }, { $0.c100 }) }
        var f: Double { sum({ $0.f }, { $0.f100 }) }
        func grams(_ k: Home.Kind) -> Double { home.filter { $0.0.kind == k }.reduce(0.0) { $0 + $1.1 } }
        /// Which dishes and how much of each, the same whichever way round: an order already shown isn't shown again.
        /// (by the names the card shows: three "Proper Cheesesteak + Plain wings" came from three sizes of the one name)
        var key: String {
            let parts: [String] = dishes.map { (d: (Item, Double)) -> String in
                let name: String = Takeaway.cutName(d.0.name).lowercased().trimmingCharacters(in: .whitespaces)
                let share: Int = Int((d.1 * 100).rounded())
                return "\(name)@\(share)"
            }
            return parts.sorted().joined(separator: "|")
        }
        /// More restaurant food and dessert, less plain powder; a dish only partly eaten counts a little against it.
        var enjoyment: Double {
            func weight(_ k: Home.Kind) -> Double {
                switch k { case .dessert: return 1; case .yoghurt: return 0.5; case .powder: return -0.5; case .milk: return 0 }
            }
            let food = dishes.reduce(0.0) { $0 + $1.0.kcal * $1.1 }, partial = Double(dishes.filter { $0.1 < 0.99 }.count)
            return food - 40 * partial + home.reduce(0.0) { s, h in s + h.0.kcal100 * h.1 / 100 * weight(h.0.kind) }
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
    /// With no food from home, an order can be two dishes, or part of one (design/takeaway-combos-mockup.html). \`shown\`:
    /// orders already shown ("any other options?"), left out; \`count\`: how many to give.
    static func plan(menu: [Item], home: [Home], kcal: Double, protein: Double, want: [String] = [], avoid: [String] = [], place: String = "the menu",
                     shown: Set<String> = [], count: Int = 3) -> Picks {
        let avoid = avoid.map { $0.lowercased() }.filter { !$0.isEmpty }
        // "no milk": the milk goes, not the Milk Chocolate protein powder. A kind of home food is matched by its kind
        let kinds: [String: Home.Kind] = ["milk": .milk, "powder": .powder, "protein powder": .powder, "shake": .powder, "yoghurt": .yoghurt, "yogurt": .yoghurt, "ice cream": .dessert, "dessert": .dessert]
        func avoided(_ h: Home) -> Bool {
            avoid.contains { a in
                if let k = kinds.first(where: { a.contains($0.key) }) { return k.value == h.kind }
                return h.name.lowercased().contains(a)
            }
        }
        // ("Large Fried Boneless Chicken, a water shake and ice cream", a card's whole title, avoids that dish too)
        let menu = menu.filter { i in let n = i.name.lowercased(); return !avoid.contains { n.contains($0) || (n.count > 5 && $0.contains(n)) } }, home = home.filter { !avoided($0) }
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
        // two dishes, or part of one: only with nothing from home (asked for, those are what's added) and something that fits
        let pairing = home.isEmpty && !tooBig
        let partners = menu.filter { ($0.kind == "main" || $0.kind == "side") && !lowProtein($0) }
        // "Small Fried Chicken" with "Large Fried Chicken" is the one dish twice
        let sizes: Set<String> = ["small", "large", "regular", "medium", "half", "whole"]
        func sameDish(_ a: Item, _ b: Item) -> Bool {
            if cutName(a.name).lowercased() == cutName(b.name).lowercased() { return true }
            let wa = Set(words(a.name).filter { !sizes.contains($0) }), wb = Set(words(b.name).filter { !sizes.contains($0) })
            return !wa.isEmpty && wa == wb
        }
        var tried = 0, best: [Combo] = [], every: [Item: [Combo]] = [:]
        for item in pool {
            var all = mixes.map { Combo(item: item, home: $0) }
            if pairing {
                let asked = wanted.contains(item)
                for s in asked ? [2.0 / 3, 0.5, 1.0 / 3] : [2.0 / 3, 0.5] { all.append(Combo(dishes: [(item, s)])) }
                for s in asked ? [1, 0.5, 1.0 / 3] : [1.0] {
                    for b in partners where b != item && !sameDish(b, item) {
                        for share in [1, 0.5, 1.0 / 3] { all.append(Combo(dishes: [(item, s), (b, share)])) }
                    }
                }
            }
            all = all.filter { !shown.contains($0.key) }
            tried += all.count
            every[item] = all
            let fits = over ? all : all.filter { $0.kcal <= kcal + 10 }
            if let b = pick(fits, kcal: kcal, protein: protein, over: over) { best.append(b) }
        }
        guard !best.isEmpty else { return Picks(combos: [], low: low, sides: sides, tried: tried, meets: false) }
        let first = pick(best, kcal: kcal, protein: protein, over: over)!
        var out: [(Combo, String)] = [(first, "Best fit")]
        // each dish's best order, or its next best when that's one already given: A + B was offered again as B + A
        func left() -> [Combo] {
            var cs: [Combo] = []
            for b in best where !out.contains(where: { $0.0.item == b.item }) {
                let given: Set<String> = Set(out.map { $0.0.key })
                if !given.contains(b.key) { cs.append(b); continue }
                let others: [Combo] = (every[b.item] ?? []).filter { (c: Combo) -> Bool in
                    (over || c.kcal <= kcal + 10) && !given.contains(c.key)
                }
                if let next = pick(others, kcal: kcal, protein: protein, over: over) { cs.append(next) }
            }
            return cs
        }
        // a dish asked about ("what about the seafood pancake?"): the whole of it, and some of it, as well as the pick
        if pairing, !wanted.isEmpty {
            let theirs = wanted.flatMap { every[$0] ?? [] }
            func share(_ c: Combo) -> Double { c.dishes.first { wanted.contains($0.0) }?.1 ?? 0 }
            let ways: [((Double) -> Bool, String)] = [({ $0 >= 0.99 }, "With the whole one"), ({ $0 > 0 && $0 < 0.99 }, "Some of it")]
            for (keep, note) in ways where out.count < count {
                if let c = pick(theirs.filter { keep(share($0)) }, kcal: kcal, protein: protein, over: true), !out.contains(where: { $0.0.key == c.key }) {
                    out.append((c, note))
                }
            }
        }
        if out.count < count, let m = left().filter({ $0.kcal <= kcal + 10 }).max(by: { $0.p < $1.p }), m.p > first.p + 2 { out.append((m, "Most protein")) }
        while out.count < count, let n = pick(left(), kcal: kcal, protein: protein, over: over) {
            let note = n.item.kcal > first.item.kcal + 20 ? "More from " + place : n.grams(.dessert) > 0 && first.grams(.dessert) == 0 ? "With dessert" : ""
            out.append((n, note))
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
        // (a dish asked about that can't reach it: the most protein within the calories, before any over them)
        let within = cs.filter { $0.kcal <= kcal + 10 }
        return (within.isEmpty ? cs : within).max { ($0.p, -$0.kcal) < ($1.p, -$1.kcal) }
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 && !["want", "some", "with", "have", "like", "this", "that", "these", "those", "just"].contains($0) }
            .map { $0.hasSuffix("s") && $0.count > 4 ? String($0.dropLast()) : $0 }
    }

    // MARK: the card

    /// How much of a dish: "½", "⅓", "⅔".
    static func frac(_ s: Double) -> String {
        abs(s - 0.5) < 0.01 ? "½" : abs(s - 1.0 / 3) < 0.01 ? "⅓" : abs(s - 2.0 / 3) < 0.01 ? "⅔" : abs(s - 0.25) < 0.01 ? "¼" : "\(Int((s * 100).rounded()))%"
    }

    /// A combo for the card and the chat record: its lines (each dish, with how much of it; a shake of powder and milk, a
    /// yoghurt, a dessert), each with the foods it adds, and the totals added up from them; with an estimated dish, the
    /// totals as a range too.
    static func json(_ c: Combo, note: String, restaurant: String, kcal: Double) -> JSON {
        func food(_ h: Home, _ a: Double) -> JSON {
            ["name": h.name, "grams": a, "unit": h.unit, "kcal": (h.kcal100 * a / 100).rounded(), "p": h.p100 * a / 100, "c": h.c100 * a / 100, "f": h.f100 * a / 100]
        }
        // "30 g powder + 150 ml milk": the shake's parts by what they are, their full names on the foods it adds
        func amount(_ h: Home, _ a: Double) -> String { "\(Fmt.one(a)) \(h.unit) \(h.kind == .powder ? "powder" : h.kind == .milk ? "milk" : h.name)" }
        var lines: [JSON] = c.dishes.map { d -> JSON in
            let (i, s) = d, part = s < 0.99
            let add: JSON = ["name": "\(restaurant) \(i.name)" + (part ? " (\(frac(s)))" : ""), "grams": 0, "unit": "g", "kcal": (i.kcal * s).rounded(), "p": i.p * s, "c": i.c * s, "f": i.f * s]
            return ["name": i.name, "detail": part ? "Eat \(frac(s)), the rest keeps" : "", "tag": i.tier, "dish": true, "share": s,
                    "kcal": (i.kcal * s).rounded(), "p": i.p * s, "add": [add]]
        }
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
        // "Beef Bulgogi Rice Bowl + ½ Small Fried Chicken", "Chicken Burger, shake and ice cream"
        func cut(_ n: String) -> String { n.components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? n }
        var bits = [c.dishes.map { ($0.1 < 0.99 ? frac($0.1) + " " : "") + cut($0.0.name) }.joined(separator: " + ")]
        if let _ = powder { bits.append(milk == nil ? "a water shake" : "shake") }
        for (h, _) in c.home where h.kind == .yoghurt { bits.append("yoghurt") }
        for (h, _) in c.home where h.kind == .dessert { bits.append(h.name.lowercased().contains("gelato") ? "gelato" : "ice cream") }
        let title = bits.count > 1 ? bits.dropLast().joined(separator: ", ") + " and " + bits.last! : bits[0]
        var out: JSON = ["title": title, "note": note, "lines": lines, "kcal": c.kcal.rounded(), "p": c.p.rounded(), "c": c.c.rounded(), "f": c.f.rounded(),
                         "over": max(0, c.kcal - kcal).rounded(), "key": c.key]
        out["source"] = source(dishes: lines.filter { $0["dish"] as? Bool == true }, homes: lines.filter { $0["dish"] as? Bool != true }, restaurant: restaurant)
        out["warn"] = c.dishes.contains { $0.0.tier == "none" }
        for (k, v) in spread(lines) { out[k] = v }
        return out
    }

    /// Where the numbers came from, said once under the card; amber (warn) when a dish was guessed.
    static func source(dishes: [JSON], homes: [JSON], restaurant r: String) -> String {
        let tiers = dishes.map { str($0["tag"]) }
        var fromDish = ""
        if dishes.count == 1 {
            let name = str(dishes[0]["name"]).components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? ""
            fromDish = tiers[0] == "full" ? "\(name) from \(whose(r)) menu" : tiers[0] == "energy" ? "\(name) from \(whose(r)) kJ, protein estimated"
                : "\(name) estimated: its kJ wasn't on \(whose(r)) listing. Type it or send a screenshot"
        } else if dishes.count > 1 {
            fromDish = tiers.allSatisfy { $0 == "full" } ? "From \(whose(r)) menu"
                : tiers.contains("none") ? "Estimates, give or take about 20%: \(whose(r)) listing has no kJ. Type it or send a screenshot"
                : "From \(whose(r)) kJ, protein estimated"
        }
        let tags = homes.map { str($0["tag"]) }
        let fromHome = tags.isEmpty ? "" : tags.allSatisfy { $0 == "label" } ? "the rest from your labels" : "the rest from your log"
        return [fromDish, fromHome].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// With a guessed dish (nothing published), the totals as a range, give or take a fifth of what's guessed
    /// ("1,300–1,450 kcal · 75–85 g"), as the PUBCHA chat gave them; nothing guessed, none.
    static func spread(_ lines: [JSON]) -> JSON {
        var lo = 0.0, hi = 0.0, plo = 0.0, phi = 0.0, guessed = false
        for l in lines {
            let k = num(l["kcal"]) ?? 0, p = num(l["p"]) ?? 0, e = l["dish"] as? Bool == true && str(l["tag"]) == "none" ? 0.2 : 0
            if e > 0 { guessed = true }
            lo += k * (1 - e); hi += k * (1 + e); plo += p * (1 - e); phi += p * (1 + e)
        }
        guard guessed else { return [:] }
        return ["kcalLo": (lo / 50).rounded(.down) * 50, "kcalHi": (hi / 50).rounded(.up) * 50, "pLo": (plo / 5).rounded(.down) * 5, "pHi": (phi / 5).rounded(.up) * 5]
    }

    // MARK: asking

    private static let s: JSON = ["type": "string"], n: JSON = ["type": "number"]
    /// tools/ai-test/intent-check.js: 54 of 54 right over 18 ways of saying it (choose, log or other), where a yes/no
    /// "is it takeaway" missed "tomorrow" and "I'd like…". find-check.js: 54 of 54 again with find added, "the poke one"
    /// after a list of places included
    static let routeSchema: JSON = ["type": "object", "required": ["intent", "restaurant", "area", "want", "avoid", "seen", "kcal", "protein"], "properties": [
        "intent": ["type": "string", "enum": ["choose", "find", "log", "other"]] as JSON, "restaurant": s, "area": s, "want": ["type": "array", "items": s] as JSON,
        "avoid": ["type": "array", "items": s] as JSON,
        "seen": ["type": "array", "items": ["type": "object", "required": ["name", "kj"], "properties": ["name": s, "kj": n] as JSON] as JSON] as JSON,
        "kcal": n, "protein": n] as JSON]
    static let menuSchema: JSON = ["type": "object", "required": ["found", "restaurant", "source", "items", "tips"], "properties": [
        "found": ["type": "boolean"] as JSON, "restaurant": s, "source": s, "tips": ["type": "array", "items": s] as JSON,
        "items": ["type": "array", "items": ["type": "object", "required": ["name", "kind", "published", "kj", "kcal", "protein_g", "carbs_g", "fat_g"], "properties": [
            "name": s, "kind": ["type": "string", "enum": ["main", "side", "drink", "dessert"]] as JSON,
            "published": ["type": "string", "enum": ["full", "energy", "none"]] as JSON,
            "kj": n, "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n] as JSON] as JSON] as JSON] as JSON]
    static let findSchema: JSON = ["type": "object", "required": ["found", "places"], "properties": [
        "found": ["type": "boolean"] as JSON,
        "places": ["type": "array", "items": ["type": "object", "required": ["name", "area", "cuisine", "dish", "published", "kj", "kcal", "protein_g", "carbs_g", "fat_g"], "properties": [
            "name": s, "area": s, "cuisine": s, "dish": s, "published": ["type": "string", "enum": ["full", "energy", "none"]] as JSON,
            "kj": n, "kcal": n, "protein_g": n, "carbs_g": n, "fat_g": n] as JSON] as JSON] as JSON] as JSON]

    /// Kept word for word with the scripts that tested them against Claude: routeAsk with tools/ai-test/intent-check.js
    /// and pubcha-route-check.js (asking for other options or saying a dish isn't on the app is choosing again: 27 of 27),
    /// menuAsk with menu-check.js, findAsk with find-protein-check.js ("new").
    static func routeAsk(_ message: String, earlier: String, photo: String = "") -> String {
        """
        A message to the assistant in a food diary app\(photo.isEmpty ? "" : ", with a photo of \(photo)"). What is it?
        choose: they're deciding what to have from one particular restaurant, takeaway, café or chain, today or another day, however they put it ("Gami tonight?", "thinking Nando's for lunch tomorrow", "what's good at Guzman for 600 cals", "can I fit a Gami burger in today?", "heading to Maccas, what should I get", "want something from the Gami in Windsor tomorrow, what are my options", "I'd like the burger from Gami with a shake": what they'd like, not what they had).
        find: they want you to suggest places to eat, somewhere or of a kind, with no particular restaurant named ("any good lunch spots near me in South Yarra?", "somewhere high protein on Chapel St", "good Thai near work for dinner", "where can I get a healthy lunch in the city?").
        log: they're telling you what they ate or are eating, to add it ("had a Gami burger for lunch", "Gami chicken burger", "just had Nando's"), or correcting a log.
        other: anything else, including choosing food with no restaurant and no places wanted ("what should I have for dinner?") and questions.
        When the conversation so far was choosing from a restaurant, a reply changing that choice ("no milk left, I want the wings", "the lamb one instead") is choose, with that restaurant; so is asking for other or more options there, or saying a dish suggested isn't on their app or menu, or asking you to look at its menu again ("any other things?", "don't see the boneless option", "check on DoorDash"), with each dish they said they can't see in avoid; a question about the order already suggested is other: which sides, sauces, dips, sizes or extras to pick with it, what you'd recommend among its options, or anything about pictures they sent ("which sides should I get?", "what would you recommend on the picks", "from the pictures I sent"). When you suggested places, picking one ("the poke one", "the second") is choose, with that place's name and area.\(photo.isEmpty ? "" : " With a photo of a menu or delivery-app page, naming a dish on it for a meal (\"this burger for dinner\") is choose, unless they say they had or ate it.")
        \(earlier.isEmpty ? "" : "The conversation so far:\n\(earlier)\n")Their message: "\(message)"
        restaurant: its name as they wrote it, else empty. area: a suburb, street or city if they said one, else empty. want: menu items they say they want, in their words, or for find the kind of food they're after ("Thai", "high protein"). avoid: foods they don't want or don't have in ("milk"), in their words. seen: dishes they quote from a menu or delivery app with their energy ("Chicken Burger (2280 kJ)"), each with its kJ (kcal × 4.184 if they gave kcal), else empty. kcal and protein: numbers they gave for what they have left or for this meal ("854 left" is kcal 854), else 0.
        """
    }
    static func menuAsk(_ restaurant: String, area: String, want: [String], seen: [String] = []) -> String {
        """
        Find the current menu of "\(restaurant)"\(area.isEmpty ? "" : " in \(area)"), a restaurant, takeaway or chain in \(Plan.country), and the nutrition it publishes. Look first for the nutrition it publishes itself: chains in Australia list kJ (often protein too) on their own website's menu or nutrition page, or a nutrition PDF; search the web for "\(restaurant) nutrition information" first, then open its own page or PDF from those results with web_fetch (a page can only be opened once a search has shown it) and read each item's numbers from it. DoorDash, Uber Eats and Menulog pages usually can't be opened, but their search results show the current menu's item names and often kJ in each name ("Chicken Burger (2280 kJ)"): use them for names and any kJ shown.\(want.isEmpty ? "" : " They want: \(want.joined(separator: ", ")). Make sure those dishes are in the list if it sells them, with the kJ its listing shows today, not an old menu's.")\(seen.isEmpty ? "" : " They read these on its listing today: \(seen.joined(separator: ", ")). List each with exactly that kJ, and estimate its protein, carbs and fat for that energy.") List up to 30 of its items, mains first, each as one serving as sold (with its size or pieces in the name, "Original tenders, 4 pcs").\(want.isEmpty ? "" : " When a dish they want comes another way it sells (another base such as high protein, gluten free or thin, or a protein option), list that way as its own item named with it (\"Pepperoni pizza, high protein base\"), with its own numbers.")
        For each item: published is full when the restaurant gives its calories and protein, energy when it gives only kJ or kcal, none when it gives nothing. kj: exactly as published, else 0. kcal: as published, else kJ ÷ 4.184, else your estimate. protein_g, carbs_g and fat_g: as published, else your honest estimate from what the item is and its usual portion. kind: main, side, drink or dessert.
        found false if you can't find its menu at all. tips: up to 3 short tips for ordering there with fewer calories or more protein, from what its menu has (its lightest flavour or sauce, a dish to skip, a deal on now), each under 15 words; empty when there are none worth giving. source: where the numbers came from, a few words. When its own figures and a delivery listing's kJ disagree, the delivery listing is today's menu: use its number. Never guess a kJ: an item whose energy you didn't read on a page has kj 0 and published none.
        """
    }

    /// Kept word for word with tools/ai-test/find-protein-check.js ("pub"): places that publish their nutrition, read from
    /// their own pages (Guzman y Gomez and Zambrero came back with their published kJ and protein every run, Nov 2026).
    static func findAsk(_ area: String, want: [String], meal: String, kcal: Double, protein: Double) -> String {
        """
        Find 4 real restaurants, cafés or takeaways in or near \(area), \(Plan.country), for \(meal.lowercased())\(want.isEmpty ? "" : ", for someone after \(want.joined(separator: ", "))"), choosing places that publish their nutrition: chains in Australia show kJ (often protein too) on their own website's menu or nutrition page or a nutrition PDF, and sites like macromenu.com.au list chains' published figures. Always give 4 different places (4 different businesses, never the same chain twice), at least 3 of them places that publish their nutrition when there are; only make up the 4 with a place that doesn't when there aren't enough. For each, the one order from its current menu that gets to \(Int(protein)) g protein or more within about \(Fmt.int(kcal)) kcal: one dish when a dish has that much protein, else a dish with what makes up the protein from the same menu (double meat, extra pieces of chicken, a second small main, a protein side), up to three items. The protein matters most: where the menu can reach \(Int(protein)) g, the order reaches it; where it can't, give the order with the most protein you can within the calories. Always give 4 places. Search the web for them, then open the place's own nutrition page or PDF (or macromenu.com.au) with web_fetch and read the order's numbers from it; DoorDash, Uber Eats and Menulog pages usually can't be opened, though their search results show item names and often kJ. Only list places in that area, still trading.
        For each place: name as it calls itself. area: its street or suburb, a few words. cuisine: one or two words. dish: the order as named on its menu, items joined with " + " ("Grilled Chicken Bowl + Extra Chicken"). published is full when the place gives the calories and protein of every item in the order, energy when it gives only their kJ or kcal, none when any item has nothing. kj: the items' published kJ added up, else 0. kcal: as published added up, else kJ ÷ 4.184, else your honest estimate. protein_g, carbs_g and fat_g: for the whole order, as published, else your honest estimate from what each item is and its usual portion. Never guess a kJ: an order with an item whose energy you didn't read on a page has kj 0 and published none.
        found false if you couldn't find places there.
        """
    }

    /// Any places there, as before 1.3.50 (find-protein-check.js "new"): for when the published-nutrition search finds
    /// too few. In a suburb ("South Yarra") it mostly came back with none, where this found four.
    static func findAskAny(_ area: String, want: [String], meal: String, kcal: Double, protein: Double) -> String {
        """
        Find 4 real restaurants, cafés or takeaways in or near \(area), \(Plan.country), for \(meal.lowercased())\(want.isEmpty ? "" : ", for someone after \(want.joined(separator: ", "))"). For each, the one order from its current menu that gets to \(Int(protein)) g protein or more within about \(Fmt.int(kcal)) kcal: one dish when a dish has that much protein, else a dish with what makes up the protein from the same menu (double meat, extra pieces of chicken, a second small main, a protein side), up to three items. The protein matters most: where the menu can reach \(Int(protein)) g, the order reaches it; where it can't, give the order with the most protein you can within the calories. Always give 4 places. Search the web for places there; delivery listings on DoorDash, Uber Eats or Menulog have the current menu, often with kJ in each item's name ("Chicken Bowl (2280 kJ)"). Only list places you found on a page, in that area, still trading.
        For each place: name as it calls itself. area: its street or suburb, a few words. cuisine: one or two words. dish: the order as named on its menu, items joined with " + " ("Grilled Chicken Bowl + Extra Chicken"). published is full when the place gives the calories and protein of every item in the order, energy when it gives only their kJ or kcal, none when any item has nothing. kj: the items' published kJ added up, else 0. kcal: as published added up, else kJ ÷ 4.184, else your honest estimate. protein_g, carbs_g and fat_g: for the whole order, as published, else your honest estimate from what each item is and its usual portion. Never guess a kJ: an order with an item whose energy you didn't read on a page has kj 0 and published none.
        found false if you couldn't find places there.
        """
    }

    /// choose, find, log or other for a message typed in Plan a meal; nil when Claude can't be reached. Choose needs a
    /// restaurant named, as in the assistant.
    @MainActor static func intent(_ text: String) async -> String? {
        guard let r = await Gemini.askClaude("quick", schema: routeSchema, parts: [["text": routeAsk(text, earlier: "")]]) else { return nil }
        let i = str(r["intent"])
        if deliveryApp(str(r["restaurant"])) { return "find" }
        return i == "choose" && str(r["restaurant"]).isEmpty ? "other" : i
    }

    /// DoorDash, Uber Eats, Menulog and the like: where they order, not a restaurant.
    static func deliveryApp(_ name: String) -> Bool {
        let n = name.lowercased().replacingOccurrences(of: #"[^a-z]"#, with: "", options: .regularExpression)
        return ["doordash", "ubereats", "uber", "menulog", "deliveroo", "grubhub", "foodpanda"].contains(n)
    }

    /// The dishes they asked for, without the foods from home they named with them ("a shake and ice cream").
    static func dishes(_ want: [String]) -> [String] {
        // (and not "high protein" alone: how they'd like it, not a dish. "Any other options?" came with it, 21 Nov)
        want.filter { w in kind(w) == nil && !["shake", "milk", "ice cream", "yoghurt", "yogurt"].contains { w.lowercased().contains($0) } && !words(core(w)).isEmpty }
    }

    /// Words that say how they'd like a dish, not which dish. "Protein pepperoni pizza" from Crust is its pepperoni pizza,
    /// wanted high in protein: no item had "protein" in its name, so the pepperoni was dropped as not on the menu and a
    /// pesto chicken pizza given instead (16 Nov).
    static let manner: Set<String> = ["protein", "high", "healthy", "healthier", "light", "lighter", "lean", "low", "carb", "keto",
                                      "large", "small", "big", "medium", "regular"]
    /// The kind of dish, which a menu's names often leave out at a place that only sells it.
    static let generic: Set<String> = ["pizza", "pizzas", "burger", "burgers", "pasta", "bowl", "bowls", "wrap", "wraps", "salad", "sandwich", "sub", "meal"]
    /// A dish's style, which a menu often names its own way: Sparrow's Philly cheesesteak is its Proper Cheesesteak (22 Nov).
    static let style: Set<String> = ["philly", "classic", "original", "proper", "signature", "famous", "traditional", "authentic"]
    /// The dish without those words ("pepperoni pizza").
    static func core(_ dish: String) -> String {
        dish.split(separator: " ").filter { !manner.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }.joined(separator: " ")
    }

    /// The dishes they want, as the menu has them: one it doesn't list the way they said ("protein pepperoni pizza") is
    /// its plain dish when it has that, said in the lead; one it doesn't have at all is left out.
    /// A base asked for is a way of having a pizza, not a dish: "They do a protein pizza base" (16 Nov) was looked for as a
    /// dish and said not to be on Crust's menu. The menu's own items on it when the lookup found any ("Crust Supreme,
    /// high protein base"); else said plainly that its numbers aren't out, and planned on the usual base.
    static func isWay(_ s: String) -> Bool {
        s.lowercased().range(of: #"\b(base|bases|crust|dough)\b"#, options: .regularExpression) != nil
    }

    static func onMenu(_ want: [String], _ items: [Item]) -> (want: [String], plain: [(said: String, dish: String)], missing: [String], ways: [String]) {
        let asked = dishes(want)
        var plain: [(said: String, dish: String)] = [], missing: [String] = [], ways: [String] = []
        // the dish it's for, when they said one ("pepperoni pizza" and "gluten free base"): the item must be that dish on it
        let dishWords = asked.filter { !isWay($0) }.flatMap { words(core($0)) }.filter { !generic.contains($0) }
        var covered = false
        for d in asked where isWay(d) {
            let ws = words(d).filter { !generic.contains($0) && !["high", "base"].contains($0) } + dishWords
            if !ws.isEmpty, let on = items.first(where: { i in let n = i.name.lowercased(); return n.contains("base") && ws.allSatisfy { n.contains($0) } }) {
                plain.append((d, on.name)); covered = true
            } else { ways.append(d) }
        }
        for d in asked where !isWay(d) && !(covered) && !has(items, d) {
            // without the manner words, then without the kind of dish too (Crust's is "Classic Pepperoni", no "pizza")
            let c = core(d)
            // the kind of dish dropped only when the place sells that kind (some item says pizza): a chicken wrap at a
            // place with no wraps is still not on the menu, not its chicken pizza
            let kinds = c.split(separator: " ").map { String($0).lowercased() }.filter { generic.contains($0) }
            let sold = kinds.allSatisfy { k in items.contains { $0.name.lowercased().contains(k.hasSuffix("s") ? String(k.dropLast()) : k) } }
            let bare = c.split(separator: " ").filter { !generic.contains(String($0).lowercased()) }.joined(separator: " ")
            let unstyled: String = c.split(separator: " ").filter { !style.contains(String($0).lowercased()) }.joined(separator: " ")
            // (not "classic burger" to any burger: what's left has to name a dish)
            let namesDish: Bool = words(unstyled).contains { (w: String) -> Bool in !generic.contains(w) }
            var tries: [String] = c == d ? [] : [c]
            if sold && !kinds.isEmpty { tries.append(bare) }
            if unstyled != c && namesDish { tries.append(unstyled) }
            let found = tries.filter { !words($0).isEmpty }.lazy.compactMap { k in
                items.first { i in words(k).allSatisfy { i.name.lowercased().contains($0) } }
            }.first
            if let found { plain.append((d, found.name)) } else { missing.append(d) }
        }
        // a dish now on the base they asked for is that one item, not the dish and the base as two
        let kept = want.compactMap { w -> String? in
            if missing.contains(w) || ways.contains(w) || (covered && asked.contains(w) && !isWay(w)) { return nil }
            return plain.first { $0.said == w }?.dish ?? w
        }
        return (kept, plain, missing, ways)
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

    /// "Gami's", "Sparrows'".
    static func whose(_ name: String) -> String {
        let endsInS: Bool = name.lowercased().hasSuffix("s")
        if name.lowercased().hasSuffix("'s") || name.lowercased().hasSuffix("’s") { return name }
        return endsInS ? name + "'" : name + "'s"
    }

    /// The name of a place typed in this message, not just still in mind from the chat or read off a photo.
    static func typed(_ name: String, in text: String) -> Bool {
        let t: String = text.lowercased(), n: String = name.lowercased()
        guard !n.isEmpty else { return false }
        func bare(_ x: String) -> [String] {
            x.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { (w: String) -> Bool in !w.isEmpty && w != "the" }
        }
        // whole words: "half the noodles" doesn't name Noodle & BBQ
        let saidWords: [String] = bare(t), nameWords: [String] = bare(n)
        guard let first = nameWords.first else { return false }
        return saidWords.contains(first) || t.contains(n)
    }

    /// Saying something on a planned card isn't there to order ("No wings on DoorDash"), not that they didn't eat it.
    static func correcting(_ text: String) -> Bool {
        let t: String = text.lowercased().replacingOccurrences(of: "’", with: "'")
        if t.range(of: #"\b(had|ate|eaten|didn't have|didn't eat)\b"#, options: .regularExpression) != nil { return false }
        let gone = #"\b(no|not|isn't|aren't|don't|doesn't|can't)\b.*\b(doordash|door dash|uber|menulog|menu|app|listed|available|see|sell)\b|\bsold out\b"#
        return t.range(of: gone, options: .regularExpression) != nil
    }

    /// A typed message that's about the photos just read, not a restaurant's menu to look up: "Wanted the stinky tofu
    /// for myself everything else around half or what do you recommend?" under the receipt was planned from Noodle &
    /// BBQ's menu online, which "didn't have" the tofu on the receipt (22 Nov). The place was only still in mind.
    static func aboutPhotos(_ turns: [Assistant.Turn], intent: String, restaurant: String) -> Bool {
        guard let last = turns.last, last.images.isEmpty, !Assistant.carriedPhotos(turns).isEmpty else { return false }
        if Assistant.mentionsPhotos(last.text) { return true }
        // somewhere else to eat, or a place named in this message
        if intent == "find" || typed(restaurant, in: last.text) { return false }
        let before: [Assistant.Turn] = Array(turns.dropLast())
        guard let at = before.lastIndex(where: { (t: Assistant.Turn) -> Bool in t.me && !t.images.isEmpty }) else { return false }
        // a menu page the planner itself answered: what follows is still the planner's ("any other options?")
        let own: Assistant.Turn? = before[(at + 1)...].first { (t: Assistant.Turn) -> Bool in !t.me }
        return !isPlanned(own?.result)
    }

    /// The planner's answers: a card, a list of places, or that it couldn't find a menu.
    static func isPlanned(_ r: JSON?) -> Bool {
        guard let r else { return false }
        return r["takeaway"] != nil || r["places"] != nil || r["menuMissing"] as? Bool == true
    }

    /// The card this message corrects: the answer just before it, when that was one and they say part of it isn't there.
    static func correctedCard(_ turns: [Assistant.Turn]) -> JSON? {
        guard let last = turns.last, last.me, correcting(last.text) else { return nil }
        return turns.dropLast().last { (t: Assistant.Turn) -> Bool in !t.me }?.result?["takeaway"] as? JSON
    }

    /// The dish a corrected card was built on (the first in every one of its orders: the cheesesteak, not the wings with
    /// it), unless that's the one they say isn't there.
    static func keptDish(_ card: JSON, said: String) -> [String] {
        var firsts: Set<String> = []
        for c in list(card["combos"]) {
            guard let l = list(c["lines"]).first else { continue }
            firsts.insert(cutName(str(l["name"])).trimmingCharacters(in: .whitespaces))
        }
        guard firsts.count == 1, let dish = firsts.first else { return [] }
        let t: String = said.lowercased()
        let struck: Bool = words(dish).contains { (w: String) -> Bool in t.contains(w) }
        return struck ? [] : [dish]
    }

    /// Two ways of writing the one place ("Zambrero", "Zambrero Melbourne").
    static func samePlace(_ a: String, _ b: String) -> Bool {
        let x: String = a.lowercased(), y: String = b.lowercased()
        if x == y { return !x.isEmpty }
        return x.count > 3 && y.count > 3 && (x.contains(y) || y.contains(x))
    }

    /// A restaurant's menu, kept on the phone for a week, so asking again costs nothing; looked up again when a dish
    /// they ask for isn't on the one kept (Gami's 2026 PDF had no Chicken Burger; its DoorDash listing does).
    /// Asked again too when they quote a dish's kJ that the kept one doesn't have at about that energy, so its protein
    /// is estimated for the size they're getting.
    /// `fresh`: they asked to look again ("check on DoorDash"): the kept one isn't used.
    @MainActor static func menu(_ restaurant: String, area: String, want: [String] = [], seen: [JSON] = [], fresh: Bool = false) async -> JSON? {
        let key = "\(restaurant)|\(area)".lowercased(), d = UserDefaults.standard
        var kept = (d.dictionary(forKey: "takeaway.menus") as? [String: JSON]) ?? [:]
        let wanted = dishes(want)
        let quoted = seen.map { "\(str($0["name"])) (\(Fmt.int(num($0["kj"]) ?? 0)) kJ)" }
        func matches(_ m: JSON) -> Bool {
            let its = items(m)
            return onMenu(wanted, its).missing.isEmpty && seen.allSatisfy { s in
                let ws = words(str(s["name"])), k = kcal(fromKJ: num(s["kj"]) ?? 0)
                return its.contains { i in ws.allSatisfy { i.name.lowercased().contains($0) } && abs(i.kcal - k) <= k * 0.15 }
            }
        }
        if !fresh, let k = kept[key], let at = num(k["at"]), Date().timeIntervalSince1970 - at < 7 * 86400, let m = k["menu"] as? JSON, matches(m) { return m }
        // the menu job opens the delivery app's page; a server from before it has only the label lookup's two searches
        let ask: [JSON] = [["text": menuAsk(restaurant, area: area, want: wanted, seen: quoted)]], country: JSON = ["country": Region.current.code]
        let fetched = await Gemini.askClaude("menu", schema: menuSchema, parts: ask, extra: country)
        guard var m = fetched != nil ? fetched : await Gemini.askClaude("lookup", schema: menuSchema, parts: ask, extra: country),
              m["found"] as? Bool == true, !items(m).isEmpty else { return fresh ? kept[key]?["menu"] as? JSON : nil }   // looked again, found nothing: the one kept
        if let was = kept[key]?["menu"] as? JSON { m = steady(m, was: was) }
        kept = kept.filter { Date().timeIntervalSince1970 - (num($0.value["at"]) ?? 0) < 7 * 86400 }
        kept[key] = ["at": Date().timeIntervalSince1970, "menu": m]
        if let ok = try? JSONSerialization.data(withJSONObject: kept), ok.count < 400_000 { d.set(kept, forKey: "takeaway.menus") }
        return m
    }

    /// A menu looked up again keeps the protein, carbs and fat it estimated before for a dish at the same energy:
    /// Crust publishes only kJ, and asked again (for its protein base) the same 1,329 kcal Pesto Chicken Club pizza
    /// came back with 60 g protein where it had 50 (16 Nov). Published numbers always come from the new lookup.
    static func steady(_ menu: JSON, was: JSON) -> JSON {
        let old = list(was["items"])
        var m = menu
        m["items"] = list(menu["items"]).map { it -> JSON in
            guard str(it["published"]) != "full", let k = num(it["kcal"]), k > 0,
                  let o = old.first(where: { str($0["name"]).lowercased() == str(it["name"]).lowercased() }),
                  let ok = num(o["kcal"]), abs(ok - k) <= k * 0.05 else { return it }
            var x = it
            for f in ["protein_g", "carbs_g", "fat_g"] { x[f] = o[f] ?? it[f] }
            return x
        }
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

    /// Whether the planner is taking a message, known as soon as it decides (before its menu search): the assistant's
    /// careful answer was being paid for (3.8¢) even when the planner's card won.
    @MainActor final class Decision {
        private var value: Bool?, waiting: [CheckedContinuation<Bool, Never>] = []
        func set(_ v: Bool) {
            guard value == nil else { return }
            value = v; answer(v)
        }
        /// true when the planner took it; false when it didn't, or hasn't decided within the wait
        func wait(_ seconds: Double) async -> Bool {
            if let value { return value }
            Task { try? await Task.sleep(for: .seconds(seconds)); self.answer(false) }
            return await withCheckedContinuation { waiting.append($0) }
        }
        private func answer(_ v: Bool) { let w = waiting; waiting = []; for c in w { c.resume(returning: v) } }
    }

    /// The answer to a takeaway question, or nil when it isn't one (or Claude can't be reached): the assistant answers.
    @MainActor
    /// With a photo of a delivery-app page (Gami's Chicken Burger, 2280 kJ, on DoorDash), what the quick look read off it
    /// goes along: its dishes' kJ win, and a dish named in the message ("this burger") is the one wanted.
    /// \`room\` and \`proteinLeft\`: what's free for it when it isn't everything left today (the cheat day planner: the
    /// rest of the day's plan taken off), used when they don't give their own numbers.
    static func answer(_ turns: [Assistant.Turn], store: Store, step: (@MainActor (String, String) -> Void)?, photo: Assistant.Spotted? = nil,
                       decided: Decision? = nil, room: Double? = nil, proteinLeft: Double? = nil) async -> JSON? {
        // every typed message is asked (no list of words to say first): it runs alongside the assistant's own answer
        guard let last = turns.last, last.me, last.images.isEmpty || photo != nil else { return nil }
        let earlier = turns.dropLast().suffix(6).map { t -> String in
            if t.me { return "They asked: \(t.text)" }
            if let ta = t.result?["takeaway"] as? JSON { return "You suggested from \(str(ta["restaurant"])): " + list(ta["combos"]).map { str($0["title"]) }.joined(separator: "; ") }
            if let pl = t.result?["places"] as? JSON { return "You suggested these places: " + list(pl["places"]).map { "\(str($0["name"])) (\(str($0["area"])))" }.joined(separator: ", ") }
            return "You: \(t.text.prefix(200))"
        }.joined(separator: "\n")
        let said = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "a burrito for under 700cals", then "find some places": still 700, not everything left (it became 1,021)
        let theirKcal = saidKcal(turns.filter { $0.me }.map { $0.text })
        let proteinTalk = turns.filter { $0.me }.contains { $0.text.lowercased().contains("protein") }
        let shown = turns.dropLast().last { $0.result?["places"] != nil }?.result?["places"] as? JSON
        if photo == nil {
            // a place on the list, tapped (its whole name is sent): planned with no asking. Anything more ("had Grill'd")
            // goes to the router, which says whether it's choosing
            if let pl = shown, let p = list(pl["places"]).first(where: { str($0["name"]).lowercased() == said.lowercased() }) {
                decided?.set(true); return await chosen(p, from: pl, store: store, step: step)
            }
            // "Whereabouts?" answered with a suburb: the search they asked for, there
            if let w = turns.dropLast().last(where: { !$0.me })?.result?["whereabouts"] as? JSON, said.split(separator: " ").count <= 5, !said.contains("?") {
                decided?.set(true); return await find(area: said, want: w["want"] as? [String] ?? [], asked: str(w["asked"]), kcal: theirKcal, protein: nil, store: store, step: step)
            }
        }
        // A place's menu is already planned in this chat: a question about that order ("which sides should I get?",
        // "from the pictures I sent") is the assistant's to answer. It was planned all over again, the same card each
        // time, because the place's name was still in mind and the message read like choosing.
        let planned = turns.dropLast().contains { $0.result?["takeaway"] != nil }
        let page = photo.map { p -> String in p.listing.isEmpty ? "the place's page on the app they order from" : "a menu page\(p.shop.isEmpty ? "" : " from \(p.shop)") showing " + p.listing.map { "\(str($0["name"])) (\(Fmt.int(num($0["kj"]) ?? 0)) kJ)" }.joined(separator: ", ") } ?? ""
        // with a menu page, choosing or logging is decided here: Claude called "this burger for dinner" a log one time in three
        // ("No wings on DoorDash", with the screenshot: the card planned again without them, not the photo taken for a plate)
        let corrected: JSON? = photo == nil ? nil : correctedCard(turns)
        if photo != nil, corrected == nil, !choosing(last.text) { return nil }
        guard let route = await Gemini.askClaude("quick", schema: routeSchema, parts: [["text": routeAsk(last.text, earlier: earlier, photo: page)]]),
              // choose; or a restaurant named in a question or a wish, nothing they had, in case it's called something else
              photo != nil || ["choose", "find"].contains(str(route["intent"])) || (!str(route["restaurant"]).isEmpty && choosing(last.text) && !(planned && str(route["intent"]) == "other")) else { return nil }
        if photo == nil && aboutPhotos(turns, intent: str(route["intent"]), restaurant: str(route["restaurant"])) { return nil }
        // "any good lunch spots in South Yarra?": places found on the web, each with the dish that suits them. A delivery
        // app named is where they'd order, not a restaurant: "Some high protein meals on door dash?" looked for DoorDash's
        // own menu and said it couldn't find it (16 Nov).
        if photo == nil, (str(route["intent"]) == "find" && str(route["restaurant"]).isEmpty) || deliveryApp(str(route["restaurant"])) {
            decided?.set(true); return await find(area: str(route["area"]), want: route["want"] as? [String] ?? [], asked: last.text, kcal: pos(route["kcal"]) ?? theirKcal, protein: pos(route["protein"]),
                                                proteinAsked: pos(route["protein"]) != nil || proteinTalk, store: store, step: step)
        }
        var named = str(route["restaurant"]).trimmingCharacters(in: .whitespaces)
        if let c = corrected { named = str(c["restaurant"]) }
        // "the poke one": a place from the list, with its dish's kJ. Not once it's been planned: "Any other suggestions"
        // after Zambrero's card came back as that same card (22 Nov)
        var listed: JSON?
        if photo == nil, let pl = shown, !named.isEmpty, let p = place(named, in: pl) {
            let placeName: String = str(p["name"])
            let been: Bool = turns.dropLast().contains { (t: Assistant.Turn) -> Bool in
                guard let ta = t.result?["takeaway"] as? JSON else { return false }
                return samePlace(str(ta["restaurant"]), placeName)
            }
            if !been { decided?.set(true); return await chosen(p, from: pl, store: store, step: step) }
            listed = p
            named = placeName
        }
        // "gami Windsor" as "Gami Windsor": a word typed all in lower case gets its capital
        let name = (named.isEmpty ? (photo?.shop ?? "") : named).split(separator: " ").map { w in w == w.lowercased() ? w.prefix(1).uppercased() + w.dropFirst() : String(w) }.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        var seen = list(route["seen"]).filter { (num($0["kj"]) ?? 0) > 0 && !str($0["name"]).isEmpty }
        for l in photo?.listing ?? [] where !seen.contains(where: { str($0["name"]).lowercased() == str(l["name"]).lowercased() }) { seen.append(l) }
        var want = route["want"] as? [String] ?? []
        // "this burger for dinner" with the page: the dish on it that the message names, else the page's first
        if let c = corrected { want = keptDish(c, said: said) }
        if let p = photo, corrected == nil, dishes(want).isEmpty, let first = p.listing.first {
            let named = p.listing.first { l in words(str(l["name"])).contains { last.text.lowercased().contains($0) } }
            want.append(str((named ?? first)["name"]))
        }
        // "Check on DoorDash" after a card: its menu looked up again, not the same card from the one kept (21 Nov, PUBCHA)
        let again = planned && (said.lowercased().range(of: #"\b(check|look|again|recheck|refresh)\b"#, options: .regularExpression) != nil
                                || ["doordash", "door dash", "uber", "menulog"].contains { said.lowercased().contains($0) })
        // their numbers from earlier in the chat too: "check on DoorDash" gave none, and the protein they asked for was lost
        let earlierProtein = turns.dropLast().reversed().compactMap { t -> Double? in (t.result?["takeaway"] as? JSON).flatMap { pos($0["aim"]) } }.first
        // the orders already shown in this chat, and their dishes
        let shownCombos = turns.dropLast().flatMap { t -> [JSON] in list((t.result?["takeaway"] as? JSON)?["combos"]) }
        let shownDishes = Set(shownCombos.flatMap { c -> [String] in
            let ls = list(c["lines"]), marked = ls.filter { $0["dish"] as? Bool == true }
            return (marked.isEmpty ? Array(ls.prefix(1)) : marked).map { cutName(str($0["name"])).lowercased() }
        })
        // "what else is there?" came back with every dish already suggested as avoided, which would leave the half chicken
        // out of every other pairing: one stays avoided only when they said something about it ("don't see boneless")
        let lower = said.lowercased()
        let avoidList = (route["avoid"] as? [String] ?? []).filter { a in
            let al = cutName(a).lowercased()
            let wasShown = shownDishes.contains { $0.contains(al) || al.contains($0) }
            return !wasShown || words(a).contains { lower.contains($0) }
        }
        // "any other options?": four more, none already shown
        let others = planned && dishes(want).isEmpty && lower.range(of: #"\b(other|else|another|alternatives?|options?|ideas?)\b"#, options: .regularExpression) != nil
        let before = others ? Set(shownCombos.map { str($0["key"]) }.filter { !$0.isEmpty }) : []
        var avoiding: [String] = avoidList
        // said to be off the app, and the router named none: the card's dishes their message names
        if corrected != nil && avoiding.isEmpty {
            avoiding = Array(shownDishes).filter { (d: String) -> Bool in words(d).contains { (w: String) -> Bool in lower.contains(w) } }
        }
        // what was struck off this place's last card stays off ("no wings", then "any other options?"), unless it's asked for now
        let lastCard: JSON? = turns.dropLast().last { (t: Assistant.Turn) -> Bool in t.result?["takeaway"] != nil }?.result?["takeaway"] as? JSON
        if let c = lastCard, samePlace(str(c["restaurant"]), name) {
            let wants: String = want.joined(separator: " ").lowercased()
            for a in c["avoid"] as? [String] ?? [] where !avoiding.contains(a) {
                let askedFor: Bool = words(a).contains { (w: String) -> Bool in wants.contains(w) }
                if !askedFor { avoiding.append(a) }
            }
        }
        var area: String = str(route["area"]).trimmingCharacters(in: .whitespaces)
        if area.isEmpty, let p = listed { area = str(p["area"]) }
        // a place nobody can find by its name alone is looked for again where they've been looking (22 Nov: a noodle bar
        // found nothing with no city, and its menu with Melbourne)
        let searched: String = str(shown?["area"])
        let near: String = searched.isEmpty ? (UserDefaults.standard.string(forKey: "takeaway.area") ?? "") : searched
        var toKcal: Double? = pos(route["kcal"]) ?? theirKcal ?? room
        var toProtein: Double? = pos(route["protein"]) ?? (proteinTalk ? earlierProtein : nil) ?? proteinLeft
        if listed != nil, let pl = shown {
            toKcal = toKcal ?? pos(pl["kcal"])
            if pl["proteinAsked"] as? Bool ?? true { toProtein = toProtein ?? pos(pl["protein"]) }
        }
        decided?.set(true)
        var out: JSON = await choose(name, area: area, want: want, seen: seen, avoid: avoiding, said: last.text, earlier: earlier,
                                     kcal: toKcal, protein: toProtein,
                                     meal: nil, store: store, step: step, fresh: again,
                                     before: before, count: others ? 4 : 3, followUp: planned, near: near)
        if str(route["intent"]) == "choose" && typed(named, in: said) { out["named"] = true }
        if var ta = out["takeaway"] as? JSON, !avoiding.isEmpty {
            ta["avoid"] = avoiding
            out["takeaway"] = ta
        }
        return out
    }

    /// Calories they gave for the meal earlier in the chat ("a burrito for under 700cals"), the latest; nil when none.
    static func saidKcal(_ texts: [String]) -> Double? {
        for t in texts.reversed() {
            let l = t.lowercased()
            guard let r = l.range(of: #"\d[\d,]{1,4}\s*(k?cals?|calories|kcal)\b"#, options: .regularExpression) else { continue }
            if let v = Double(l[r].prefix { $0.isNumber || $0 == "," }.replacingOccurrences(of: ",", with: "")), v >= 150, v <= 3000 { return v }
        }
        return nil
    }

    /// A place off the list, tapped or named: planned like naming it, the dish's kJ the search read going along as quoted.
    @MainActor static func chosen(_ p: JSON, from pl: JSON, store: Store, step: (@MainActor (String, String) -> Void)?) async -> JSON {
        let seen: [JSON] = (num(p["kj"]) ?? 0) > 0 ? [["name": str(p["dish"]), "kj": num(p["kj"]) ?? 0]] : []
        return await choose(str(p["name"]), area: str(p["area"]), want: [], seen: seen, avoid: [], said: str(pl["asked"]), earlier: "",
                            // the protein only when they'd asked for it (a list for "a burrito under 700" didn't)
                            kcal: pos(pl["kcal"]), protein: (pl["proteinAsked"] as? Bool ?? true) ? pos(pl["protein"]) : nil, meal: str(pl["meal"]).isEmpty ? nil : str(pl["meal"]), store: store, step: step)
    }

    /// The place on a list of places that a message names: its whole name ("Zeus Street Greek", what a tap sends), or the
    /// name the router read from "the Greek one".
    static func place(_ text: String, in pl: JSON) -> JSON? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let all = list(pl["places"])
        return all.first { str($0["name"]).lowercased() == t }
            ?? all.first { p in let n = str(p["name"]).lowercased(); return n.count > 3 && t.count > 3 && (n.contains(t) || t.contains(n)) }
    }

    /// "near me" and "near work" say nowhere to search: the last area they asked about is used, else they're asked.
    static func vague(_ area: String) -> Bool {
        let a = area.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^(near|around|by|close to)\s+"#, with: "", options: .regularExpression)
        return a.isEmpty || ["me", "here", "work", "home", "my place", "the office", "office", "uni", "my work", "my house", "nearby"].contains(a)
    }

    /// "near me", "nearby" or nowhere said: where they are now. ("near work" isn't: they may not be there.)
    static func here(_ area: String) -> Bool {
        let a = area.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^(near|around|by|close to)\s+"#, with: "", options: .regularExpression)
        return ["", "me", "here", "nearby"].contains(a)
    }

    /// Places to eat somewhere, found on the web (the menu job's search), each with the one dish that suits what's left.
    @MainActor static func find(area said: String, want: [String], asked: String, kcal: Double?, protein: Double?, proteinAsked: Bool = true, store: Store,
                                step: (@MainActor (String, String) -> Void)?) async -> JSON {
        let d = UserDefaults.standard
        var area = said.trimmingCharacters(in: .whitespaces), located = false
        if vague(said) {
            // "near me" or nowhere said: the suburb they're in (location asked for the first time); "near work": the last area
            if here(said), !Locator.shared.refused {
                step?("Asked for places near you", "Finding your suburb…")
                if let s = await Locator.shared.suburb() { area = s; located = true }
            }
            if !located { area = d.string(forKey: "takeaway.area") ?? "" }
        }
        guard !area.isEmpty else {
            return ["kind": "answer", "reply": "Whereabouts? Tell me the suburb or street and I'll find places there.", "whereabouts": ["want": want, "asked": asked] as JSON]
        }
        if !located { d.set(area, forKey: "takeaway.area") }   // a suburb they typed, for "near work" later
        let a = aim(store, said: asked), k = kcal ?? a.kcal, p = protein ?? a.protein
        step?(located ? "You're in \(area)" : "Asked for places in \(area)", "Searching the web for places in \(area)…")
        let ask: [JSON] = [["text": findAsk(area, want: want, meal: a.meal, kcal: k, protein: p)]]
        var r = await Gemini.askClaude("menu", schema: findSchema, parts: ask, extra: ["country": Region.current.code])
        // places that publish their nutrition first; too few of them there (a suburb), any places there as before
        if r == nil || r?["found"] as? Bool != true || list(r?["places"]).count < 2 {
            step?("Few places there publish their numbers", "Looking wider…")
            let wide: [JSON] = [["text": findAskAny(area, want: want, meal: a.meal, kcal: k, protein: p)]]
            if let w = await Gemini.askClaude("menu", schema: findSchema, parts: wide, extra: ["country": Region.current.code]), w["found"] as? Bool == true,
               list(w["places"]).count > list(r?["places"]).count { r = w }
        }
        guard let r else {
            return ["kind": "answer", "reply": "I couldn't search for places just now. Try again in a minute, or name a place and I'll check its menu."]
        }
        return places(r, area: area, asked: asked, meal: a.meal, kcal: k, protein: p, proteinAsked: proteinAsked)
    }

    /// What the chat shows for places found: one sentence and the list, each place's numbers from its own kJ where it
    /// gave one (said "their kJ"), else marked estimated.
    static func places(_ r: JSON, area: String, asked: String, meal: String, kcal: Double, protein: Double, proteinAsked: Bool = true) -> JSON {
        let found = list(r["places"]).filter { !str($0["name"]).isEmpty && !str($0["dish"]).isEmpty }.prefix(4).map { p -> JSON in
            var x = p
            let kj = num(p["kj"]) ?? 0
            if kj > 0 { x["kcal"] = Takeaway.kcal(fromKJ: kj) }
            if kj <= 0, str(p["published"]) != "full" { x["published"] = "none" }   // no energy read on a page is an estimate
            return x
        }
        guard r["found"] as? Bool == true, !found.isEmpty else {
            return ["kind": "answer", "trail": ["Searched the web for places in \(area)"],
                    "reply": "I couldn't find places in \(area) online. Name one you're thinking of and I'll check its menu."]
        }
        // The ones that get to the protein asked for (within a tenth) and stay near the calories come first, then the
        // rest by how much protein they have, and the sentence says how many do. It said they all "fit" whatever the
        // numbers were: four dinners of 35 to 52 g were offered as fitting 70 g.
        // When they didn't ask about protein, the calories decide what fits ("a burrito under 700" was answered with
        // "nothing gets to 58 g protein" over and over), most protein first among them.
        func fits(_ p: JSON) -> Bool { (!proteinAsked || (num(p["protein_g"]) ?? 0) >= protein * 0.9) && (num(p["kcal"]) ?? 0) <= kcal * 1.15 }
        func byProtein(_ a: JSON, _ b: JSON) -> Bool { (num(a["protein_g"]) ?? 0) > (num(b["protein_g"]) ?? 0) }
        let fitting = found.filter(fits)
        let ranked = (proteinAsked ? fitting : fitting.sorted(by: byProtein)) + found.filter { !fits($0) }.sorted(by: byProtein)
        let hits = found.filter(fits).count, aim = "around \(Fmt.int(kcal)) kcal" + (proteinAsked ? " with \(Int(protein)) g protein" : "")
        let reply: String
        if !proteinAsked {
            reply = hits == ranked.count ? "For \(meal.lowercased()) \(aim), \(ranked.count == 1 ? "this place" : "these \(ranked.count)") in \(area) fit, most protein first. Tap one to plan it:"
                : hits > 0 ? "For \(meal.lowercased()) \(aim), \(hits) of these \(ranked.count) in \(area) fit (listed first, most protein first); the rest are over. Tap one to plan it:"
                : "Nothing I found in \(area) comes in \(aim) for \(meal.lowercased()). These are the closest. Tap one to plan it:"
        } else if hits == ranked.count { reply = "For \(meal.lowercased()) \(aim), \(ranked.count == 1 ? "this place" : "these \(ranked.count)") in \(area) fit. Tap one to plan it:" }
        else if hits > 0 { reply = "For \(meal.lowercased()) \(aim), \(hits) of these \(ranked.count) in \(area) \(hits == 1 ? "gets" : "get") there (listed first). \(ranked.count - hits == 1 ? "The other falls" : "The rest fall") short on protein. Tap one to plan it:" }
        else { reply = "Nothing I found in \(area) gets to \(Int(protein)) g protein in around \(Fmt.int(kcal)) kcal for \(meal.lowercased()). These come closest, most protein first. Tap one to plan it:" }
        return ["kind": "places", "reply": reply, "meal": meal, "trail": ["Searched the web for places in \(area)"],
                "places": ["area": area, "asked": asked, "meal": meal, "kcal": kcal, "protein": protein, "proteinAsked": proteinAsked, "places": ranked] as JSON]
    }

    /// What to aim for: everything left at dinner, else this meal's share; for tomorrow, that meal's usual share of a day.
    @MainActor static func aim(_ store: Store, said text: String, meal named: String? = nil) -> (meal: String, kcal: Double, protein: Double) {
        let hour = Calendar.current.component(.hour, from: Date())
        let meal = named ?? Meals.named(in: text) ?? (hour < 11 ? "Breakfast" : hour < 16 ? "Lunch" : "Dinner")
        let left = max(0, store.budgetToday - store.eaten), share = store.mealTarget(meal)
        let pLeft = store.proteinGoal.map { max(0, $0 - store.macros(store.todayItems).p) }
        let tomorrow = text.lowercased().contains("tomorrow")
        let usual = ["Breakfast": 0.25, "Lunch": 0.30, "Dinner": 0.35][meal] ?? 0.3
        let kcal = tomorrow ? (store.budgetToday * usual / 10).rounded() * 10 : meal == "Dinner" ? left : share.kcal
        let protein = (tomorrow ? store.proteinGoal.map { ($0 * usual).rounded() } : (meal == "Dinner" ? pLeft : share.protein).map { $0.rounded() }) ?? 30
        return (meal, kcal, protein)
    }

    /// The card for one restaurant: its menu found (or kept), the home foods, the plan.
    @MainActor static func choose(_ name: String, area: String, want: [String], seen: [JSON], avoid: [String], said text: String, earlier: String,
                                  kcal theirKcal: Double?, protein theirProtein: Double?, meal named: String?, store: Store,
                                  step: (@MainActor (String, String) -> Void)?, fresh: Bool = false,
                                  before: Set<String> = [], count: Int = 3, followUp: Bool = false, near: String = "") async -> JSON {
        step?("Asked about \(name)", fresh ? "Looking at \(whose(name)) menu again…" : "Finding \(whose(name)) menu…")
        // what to aim for: their own numbers, else everything left at dinner, else this meal's share
        let a = aim(store, said: text, meal: named), meal = a.meal
        let kcal = theirKcal ?? a.kcal, protein = theirProtein ?? a.protein
        // (a few cold sides alone are no menu to plan a meal from)
        func usable(_ m: JSON?) -> JSON? {
            guard let m else { return nil }
            let hasMain: Bool = items(m).contains { (i: Item) -> Bool in i.kind == "main" }
            return hasMain || !seen.isEmpty ? m : nil
        }
        var got: JSON? = usable(await menu(name, area: area, want: want, seen: seen, fresh: fresh))
        var foundNear = ""
        if got == nil, area.isEmpty, !vague(near) {
            step?("Nothing by that name alone", "Looking for \(name) in \(near)…")
            got = usable(await menu(name, area: near, want: want, seen: seen, fresh: fresh))
            if let g = got {
                let who: String = str(g["restaurant"]).isEmpty ? name : str(g["restaurant"])
                foundNear = "I took that to be \(who), looking in \(near). If it's another shop, send a screenshot of its menu. "
            }
        }
        guard let m = got else {
            let target: String = "\(Int(protein)) g protein in about \(Fmt.int(kcal)) kcal"
            let searchedIn: String = !area.isEmpty ? " in \(area)" : vague(near) ? "" : " in \(near)"
            let reply: String = "I couldn't find \(whose(name)) menu online\(searchedIn). Send a screenshot of it, or type a few of its dishes, and I'll pick for \(target)."
            return ["kind": "answer", "menuMissing": true, "reply": reply]
        }
        let menuItems = withSeen(items(m), seen, want: want), shown = name   // their own name for it reads better than "Gami Chicken (Gami Chicken & Beer)"
        let energyOnly = menuItems.filter { $0.tier == "energy" }.count * 2 >= menuItems.count, full = menuItems.allSatisfy { $0.tier == "full" }
        let every = menuItems.allSatisfy { $0.tier != "none" } ? "every item" : "most items"
        let found = full ? "Found \(whose(shown)) menu with its nutrition" : energyOnly ? "Found \(whose(shown)) menu: kJ on \(every)" : "Found \(whose(shown)) menu"
        let scans = PantryItem.Saved.load(UserDefaults.standard.string(forKey: "pantry.scans") ?? "[]")
        let home = homeFoods(store, scans: scans)
        step?(found, home.isEmpty ? "Putting it together…" : "Adding what you have at home…")

        // food from home only when they bring it up ("with a shake", "and ice cream"): "want something from Gami
        // tomorrow" came back with a protein shake and ice cream nobody asked for, and so did "1400 kcal, 80 g protein"
        // from PUBCHA (21 Nov: "a water shake and ice cream" on every option). Short of the protein, one shake is
        // offered on the card instead, to add with a tap.
        // (what they said: the cards' own titles, "…, a water shake and ice cream", aren't them asking for it)
        let theirs = earlier.split(separator: "\n").filter { $0.hasPrefix("They asked:") }.joined(separator: " ")
        let talk = ([text, theirs] + want + avoid).joined(separator: " ")
        let homeToo = asksForHome(talk)
        // "What if I did a wrap?" at a place with no wraps: said, not the same card again as if it had been heard
        let asked = onMenu(want, menuItems), missing = asked.missing
        let lead = !missing.isEmpty ? "I couldn't see \(missing.joined(separator: " or ").lowercased()) on \(whose(shown)) menu online, so here's the closest. If it's there, send a screenshot. "
                 : !asked.ways.isEmpty ? "\(shown) doesn't give numbers for its \(asked.ways[0].lowercased()), so these are on its usual base. "
                 : asked.plain.first(where: { isWay($0.said) || core($0.said) != $0.said }).map { isWay($0.said) ? "On its \($0.said.lowercased()): " : "\(shown) doesn't list a \($0.said.lowercased()), so here's its \($0.dish.lowercased()). " } ?? ""
        let proteinAsked = theirProtein != nil || talk.lowercased().contains("protein") || homeToo
        let p = plan(menu: menuItems, home: homeToo ? home : [], kcal: kcal, protein: protein, want: asked.want, avoid: avoid, place: shown,
                     shown: before, count: count)
        // "what about the seafood pancake?" after a card: said straight whether it suits, and what's still best (the PUBCHA chat)
        var verdict = "", still = ""
        if followUp, let w = asked.want.first, let i = menuItems.first(where: { has([$0], w) }) {
            let per = i.p / max(i.kcal, 1) * 100, est = i.tier == "none" ? "about " : ""
            verdict = per < 5 ? "\(cutName(i.name)) isn't a great pick for this: \(est)\(Fmt.int(i.kcal)) kcal for \(Int(i.p.rounded())) g protein. "
                              : "\(cutName(i.name)) can work: \(est)\(Fmt.int(i.kcal)) kcal and \(Int(i.p.rounded())) g protein. "
            let plain = plan(menu: menuItems, home: homeToo ? home : [], kcal: kcal, protein: protein, avoid: avoid, place: shown)
            if let b = plain.combos.first?.0, !b.dishes.contains(where: { $0.0 == i }) {
                still = "\n\nStill the best for what you're after: " + str(json(b, note: "", restaurant: shown, kcal: kcal)["title"]) + "."
            }
        }
        let advice = Array((m["tips"] as? [String] ?? []).filter { !$0.isEmpty }.prefix(3))
        let smallest = menuItems.filter { $0.kind == "main" }.map { $0.kcal }.min() ?? 0
        var out = result(p, home: homeToo ? home : [], tips: homeToo ? [] : home, menu: menuItems, shown: shown, kcal: kcal, protein: protein, meal: meal,
                         smallest: smallest, source: str(m["source"]), lead: foundNear + lead + verdict, proteinAsked: proteinAsked, advice: advice, others: !before.isEmpty)
        if !still.isEmpty, str(out["kind"]) == "takeaway" { out["reply"] = str(out["reply"]) + still }
        return out
    }

    /// A dish's name without its size or pieces: "Seafood Pancake" from "Seafood Pancake, large".
    static func cutName(_ n: String) -> String { n.components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? n }

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
            lines[0] = ["name": str(d["name"]), "detail": "", "tag": str(d["tier"]), "dish": true, "share": 1.0, "kcal": num(d["kcal"]) ?? 0, "p": num(d["p"]) ?? 0,
                        "add": [["name": "\(restaurant) \(str(d["name"]))", "grams": 0, "unit": "g", "kcal": num(d["kcal"]) ?? 0, "p": num(d["p"]) ?? 0, "c": num(d["c"]) ?? 0, "f": num(d["f"]) ?? 0] as JSON]]
        }
        // a card from before dishes were marked: its first line is the dish
        if !lines.isEmpty, !lines.contains(where: { $0["dish"] != nil }) { lines[0]["dish"] = true }
        if tip, let t = dict(c["tip"])["line"] as? JSON { lines.append(t) }
        let on = lines.indices.filter { !off.contains($0) }
        func sum(_ k: String) -> Double { on.flatMap { list(lines[$0]["add"]) }.reduce(0.0) { $0 + (num($1[k]) ?? 0) } }
        var out = c
        out["title"] = title
        out["lines"] = lines.enumerated().map { i, l -> JSON in var x = l; x["off"] = off.contains(i); return x }
        out["kcal"] = sum("kcal").rounded(); out["p"] = sum("p").rounded(); out["c"] = sum("c").rounded(); out["f"] = sum("f").rounded()
        out["over"] = max(0, sum("kcal") - kcal).rounded()
        out["count"] = on.count
        // where the numbers came from, and the range when a dish is guessed, for what's still on the card
        let kept = on.map { lines[$0] }
        out["source"] = source(dishes: kept.filter { $0["dish"] as? Bool == true }, homes: kept.filter { $0["dish"] as? Bool != true }, restaurant: restaurant)
        out["warn"] = kept.contains { $0["dish"] as? Bool == true && str($0["tag"]) == "none" }
        for k in ["kcalLo", "kcalHi", "pLo", "pHi"] { out[k] = nil }
        for (k, v) in spread(kept) { out[k] = v }
        return out
    }

    /// What the chat shows, kept short: one sentence, one line of what it used, and the combos, each saying once where
    /// its numbers came from, with dishes to swap in and, when it's short of protein and nothing from home was asked for,
    /// one shake offered. (The low-protein and won't-fit lists were too much at once; they're left out.)
    static func result(_ p: Picks, home: [Home], tips: [Home] = [], menu: [Item] = [], shown: String, kcal: Double, protein: Double, meal: String,
                       smallest: Double, source: String = "", lead: String = "", proteinAsked: Bool = true, advice: [String] = [], others: Bool = false) -> JSON {
        let names = home.map { short($0.name) }
        let mine = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? ""
        let used = "\(whose(shown)) menu" + (mine.isEmpty ? "" : " · your \(mine)")
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
        var reply = others ? "\(combos.count == 1 ? "One more" : "\(combos.count) more") from \(shown):"
                  : over > 10 ? "\(title) is \(Fmt.int(over)) kcal over what's left, but it's the closest:"
                  : p.meets ? "\(title) gets you there:"
                  : proteinAsked ? "\(title) gets you closest, \(Fmt.int(top.p)) g of your \(Int(protein)) g protein:"
                  : "\(title) fits in \(Fmt.int(kcal)) kcal, with \(Fmt.int(top.p)) g protein:"
        // said first when the dish's own energy wasn't found; the card's amber line says how to give it
        // said first when a dish's own energy wasn't found: ranges on the card (the PUBCHA chat's "give or take about 20%")
        if top.dishes.contains(where: { $0.0.tier == "none" }) {
            reply = "\(shown) doesn't publish kJ\(top.dishes.count > 1 || others ? " for these" : " for this"), so the numbers are estimates, give or take about 20%. " + reply
        }
        reply = lead + reply
        if home.isEmpty && tips.isEmpty && !p.meets && proteinAsked { reply += "\n\nScan your protein powder or yoghurt in Plan a meal and I can add them from home." }
        return ["kind": "takeaway", "reply": reply, "meal": meal, "trail": [used],
                "takeaway": ["restaurant": shown, "source": source, "combos": combos, "aim": protein, "kcal": kcal, "tips": advice] as JSON]
    }

    /// "Milk Chocolate Protein Powder" → "protein powder", for the trail.
    static func short(_ name: String) -> String {
        kind(name) == .powder ? "protein powder" : name.components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? name
    }
}
