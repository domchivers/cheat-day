import Foundation

/// Barcode lookups on Open Food Facts, turned into a food the same way the web app does (itemFromProduct).
enum OpenFoodFacts {
    enum Result { case found(JSON), notFound, failed(String) }

    static func lookup(_ code: String) async -> Result {
        let fields = "product_name,product_name_en,brands,quantity,product_quantity,product_quantity_unit,serving_size,serving_quantity,nutriments,image_front_small_url,categories_tags"
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=\(fields)") else { return .notFound }
        var lastError = "No connection to Open Food Facts."
        for attempt in 0..<2 {
            do {
                var req = URLRequest(url: url, timeoutInterval: 10)
                req.setValue("CheatDays iOS (domchivers.github.io/cheat-day)", forHTTPHeaderField: "User-Agent")
                let (d, r) = try await URLSession.shared.data(for: req)
                let status = (r as? HTTPURLResponse)?.statusCode ?? 0
                if status == 503 || status == 429 { lastError = "Open Food Facts is busy right now."; try? await Task.sleep(nanoseconds: 1_500_000_000); continue }
                guard let j = try JSONSerialization.jsonObject(with: d) as? JSON else { return .failed("Open Food Facts sent something unexpected.") }
                guard num(j["status"]) == 1, let p = j["product"] as? JSON else { return .notFound }
                return .found(item(from: p))
            } catch {
                lastError = attempt == 0 ? "Open Food Facts is slow right now." : "No connection to Open Food Facts."
            }
        }
        return .failed(lastError)
    }

    /// kcal per 100 and per serving, fixing the common mix-up where the kJ number sits in the kcal box.
    static func energy(_ n: JSON) -> (per100: Double?, perServing: Double?) {
        func pick(_ suffix: String, cap: Double?) -> Double? {
            let kcal = pos(n["energy-kcal" + suffix]), kj = pos(n["energy-kj" + suffix]) ?? pos(n["energy" + suffix])
            if let kcal, let kj { return abs(kcal * 4.184 - kj) / kj < 0.2 ? kcal : kj / 4.184 }
            if let kcal { if let cap, kcal > cap { return kcal / 4.184 }; return kcal }
            if let kj { return kj / 4.184 }
            return nil
        }
        return (pick("_100g", cap: 950), pick("_serving", cap: nil))
    }

    static func item(from p: JSON) -> JSON {
        let n = dict(p["nutriments"])
        let e = energy(n)
        var item: JSON = ["source": "barcode"]
        item["name"] = str(p["product_name_en"]).isEmpty ? str(p["product_name"]) : str(p["product_name_en"])
        if let brands = p["brands"] as? [String] { item["brand"] = brands.joined(separator: ", ") } else if !str(p["brands"]).isEmpty { item["brand"] = str(p["brands"]) }
        if let img = p["image_front_small_url"] as? String, !img.isEmpty { item["image"] = img }
        let q = (str(p["product_quantity_unit"]) + " " + str(p["quantity"])).lowercased()
        item["unit"] = q.range(of: #"\bml\b|\bl\b|litre|liter"#, options: .regularExpression) != nil ? "ml" : "g"
        if let k = e.per100 { item["kcalPer100"] = k.rounded() }
        var serving = pos(p["serving_quantity"])
        if serving == nil, let m = str(p["serving_size"]).range(of: #"(\d+(?:[.,]\d+)?)\s*(g|ml)"#, options: [.regularExpression, .caseInsensitive]) {
            serving = Double(str(p["serving_size"])[m].replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) })
        }
        if let serving { item["servingSize"] = serving }
        var perServing = e.perServing?.rounded()
        // a per-serving figure that doesn't match per-100 × serving is usually kJ in the kcal box
        if let ps = perServing, let k = e.per100, let sv = serving {
            let expected = k * sv / 100
            if ps > expected * 2 && abs(ps / 4.184 - expected) / expected < 0.25 { perServing = (ps / 4.184).rounded() }
        }
        if let perServing { item["kcalPerServing"] = perServing }
        if let pack = pos(p["product_quantity"]) { item["packSize"] = pack }
        if let pr = num(n["proteins_100g"]) { item["p100"] = pr; item["c100"] = num(n["carbohydrates_100g"]) ?? 0; item["f100"] = num(n["fat_100g"]) ?? 0 }
        else if let sv = serving, let pr = num(n["proteins_serving"]) {
            let k = 100 / sv
            item["p100"] = pr * k; item["c100"] = (num(n["carbohydrates_serving"]) ?? 0) * k; item["f100"] = (num(n["fat_serving"]) ?? 0) * k
        }
        // things eaten by the piece: bread by the slice, biscuits, bars...
        let fromText = pieceFromServing(str(p["serving_size"]))
        let fromCat = pieceFromCategories((p["categories_tags"] as? [String]) ?? [])
        if fromText != nil || fromCat != nil {
            item["unitLabel"] = fromText?.word ?? fromCat?.word
            if let t = fromText, let g = t.grams { item["servingSize"] = g / t.count }
            if let t = fromText, t.count > 1, let ps = num(item["kcalPerServing"]) { item["kcalPerServing"] = (ps / t.count).rounded() }
            if pos(item["servingSize"]) == nil, !(pos(item["packSize"]) != nil && pos(item["piecesPerPack"]) != nil), let g = fromCat?.grams {
                item["servingSize"] = g; item["kcalPerServing"] = nil
            }
            if let pack = pos(item["packSize"]), let sv = pos(item["servingSize"]), item["piecesPerPack"] == nil { item["piecesPerPack"] = (pack / sv).rounded() }
        }
        return item
    }

    private static func pieceFromServing(_ text: String) -> (count: Double, word: String, grams: Double?)? {
        let t = text.lowercased()
        let pattern = #"(\d+(?:[.,]\d+)?)?\s*(slices?|biscuits?|cookies?|bars?|pieces?|eggs?|sausages?|nuggets?|wraps?|rolls?|crackers?|squares?|sweets?|cans?|bottles?|pots?|scoops?|buns?|pancakes?|waffles?|muffins?|crumpets?|bagels?|fingers?|sticks?|cubes?|balls?|tablets?)\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern), let m = rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        let count = Range(m.range(at: 1), in: t).flatMap { Double(t[$0].replacingOccurrences(of: ",", with: ".")) } ?? 1
        guard let wr = Range(m.range(at: 2), in: t) else { return nil }
        var word = String(t[wr]); if word.hasSuffix("s") { word.removeLast() }
        var grams: Double?
        if let g = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*(g|ml)\b"#), let gm = g.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(gm.range(at: 1), in: t) {
            grams = Double(t[r].replacingOccurrences(of: ",", with: "."))
        }
        return (count > 0 ? count : 1, word, grams)
    }

    private static let categoryPieces: [(String, String, Double?)] = [
        (#"sliced-bread|\bbreads?\b|loaf|loaves|toast"#, "slice", 40), (#"bread-rolls|\bbuns\b|baps|burger-buns|brioche"#, "roll", 60),
        ("crumpets", "crumpet", 45), ("bagels", "bagel", 85), ("tortillas|wraps", "wrap", 60), ("pancakes", "pancake", 40),
        ("biscuits|cookies|shortbread|digestives", "biscuit", 12), ("crackers|crispbreads|rice-cakes", "cracker", 8), ("wafers", "wafer", 10),
        ("cereal-bars|protein-bars|chocolate-bars|candy-bars|snack-bars|granola-bars", "bar", nil), ("sausages|frankfurters|hot-dogs", "sausage", 60),
        (#"\beggs\b"#, "egg", 55), ("fish-fingers", "finger", 28), ("chicken-nuggets", "nugget", 18), ("cheese-slices|sliced-cheeses", "slice", 20),
        (#"sliced-hams|\bhams\b|cooked-meats|charcuterie"#, "slice", 25), ("muffins", "muffin", 100), ("croissants", "croissant", 60), ("doughnuts|donuts", "doughnut", 60),
        ("ice-cream-bars|ice-lollies|ice-pops", "lolly", 70), ("yogurts|desserts", "pot", nil), ("beverages|drinks|sodas|beers|ciders|wines", "can", nil)
    ]

    private static func pieceFromCategories(_ tags: [String]) -> (word: String, grams: Double?)? {
        let t = tags.joined(separator: " ").lowercased()
        for (pattern, word, g) in categoryPieces where t.range(of: pattern, options: .regularExpression) != nil { return (word, g) }
        return nil
    }
}
