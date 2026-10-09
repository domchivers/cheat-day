import Foundation
import UIKit

/// A photo of a nutrition table or of a pack, read by the AI and turned into a food (the web app's readLabel).
/// For a pack it couldn't read, it checks Open Food Facts for the same brand and product, then searches the web.
enum LabelReader {
    struct Result { var item: JSON; var note: String }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static let schema: JSON = {
        func n(_ d: String) -> JSON { ["type": "number", "nullable": true, "description": d] }
        func s(_ d: String) -> JSON { ["type": "string", "nullable": true, "description": d] }
        let props: JSON = [
            "photo_shows": ["type": "string", "enum": ["nutrition_table", "pack", "neither"], "description": "nutrition_table: a nutrition table or panel is the main thing in the photo. pack: a packaged product (usually its front), whether or not some figures are printed on it. neither: not a food product at all"] as JSON,
            "numbers_from": ["type": "string", "enum": ["printed", "estimate"], "description": "printed: the calories were read off the photo. estimate: nothing readable, so these are typical values for this exact product"] as JSON,
            "piece_weight": n("Weight in g (or ml) of ONE piece (one bun, one biscuit, one bar), even when the pack's serving is several pieces. Printed, or pack size divided by the number of pieces, or a typical weight for this product"),
            "kcal_per_piece": n("kcal in ONE piece"),
            "name": ["type": "string", "description": "Product name as printed, or a short description if no name is visible"] as JSON,
            "brand": s("The brand"),
            "unit": ["type": "string", "enum": ["g", "ml"], "description": "Whether the per-100 values are per 100 g or per 100 ml"] as JSON,
            "kcal_per_100": n("kcal per 100 g/ml. If only kJ is printed, convert: kcal = kJ / 4.184"),
            "serving_size": n("One serving/portion in g or ml, if stated"),
            "kcal_per_serving": n("kcal per serving/portion, if stated"),
            "pack_size": n("Total pack net weight/volume in g or ml, if visible"),
            "pieces_per_pack": n("Number of pieces/bars/biscuits per pack, if stated"),
            "protein_per_100": n("Protein g per 100 g/ml, if shown"),
            "carbs_per_100": n("Carbohydrate g per 100 g/ml, if shown"),
            "fat_per_100": n("Fat g per 100 g/ml, if shown"),
            "piece_name": s("If it's eaten by the piece, what one is called: slice, biscuit, bar, sausage… else null"),
            "is_nutrition_label": ["type": "boolean", "description": "true only if a nutrition table or energy figures are actually visible"] as JSON,
            "confidence": ["type": "string", "enum": ["high", "medium", "low"]] as JSON,
            "notes": ["type": "string", "description": "Anything unclear, e.g. 'values are per 30g portion; per-100 not shown'"] as JSON
        ]
        return ["type": "object", "properties": props, "required": Array(props.keys)]
    }()

    static let prompt = """
    This is a photo of a food or drink product, its nutrition table, or both. Read the energy information off it.
    Report only numbers you can actually read on the label; use null for anything not visible rather than guessing.
    If energy is given in kJ only, convert to kcal (kcal = kJ / 4.184). If values are per portion only, fill kcal_per_serving and serving_size and leave kcal_per_100 null.
    If the photo is of the pack itself (for example the front of a pack of biscuits or hot cross buns), set photo_shows to "pack".
    UK and Irish packs often have a front-of-pack panel like "Each 70g bun contains: Energy 823kJ 196kcal 10% | Fat ... | Sugars ... | Salt ...": the kcal figure there is for one piece (use it for kcal_per_piece and the weight for piece_weight). Never use the kJ figure or the % reference intake as calories. Australian packs may show "Health Star Rating" and "per serve" figures instead. Read anything printed on it: the name, the brand, the pack weight, how many pieces are inside, and any calorie figure (front-of-pack panels often say "each bun contains 176 kcal").
    If no calorie figure can be read but you can tell what the product is, set numbers_from to "estimate" and give typical values for that exact product, using the brand and variety if you know them: kcal_per_100, the macros per 100, piece_weight and kcal_per_piece. Set is_nutrition_label to true in that case, since there are numbers to use.
    piece_name, piece_weight and kcal_per_piece describe ONE piece as it is eaten (one bun, one biscuit). Leave them null for things not eaten by the piece (a bag of rice, a tub of yoghurt).
    If it isn't a food or drink product at all, set photo_shows to "neither", is_nutrition_label to false and leave the numbers null.
    """

    /// Read a photo. `progress` gets short updates ("Checking the numbers…").
    static func read(_ image: UIImage, progress: @escaping @MainActor (String) -> Void) async throws -> Result {
        guard let imagePart = Gemini.imagePart(image) else { throw Failure(message: "Couldn't read that photo.") }
        var text = prompt
        if let c = ShopCountry.current { text += "\nThe person shops in \(c.name). If you have to estimate, use \(c.name)'s version of this product: the same brand's recipe and sizes can differ between countries." }
        let p = try await Gemini.ask(schema: schema, parts: [imagePart, ["text": text]], quick: true)

        let anyKcal = pos(p["kcal_per_100"]) ?? pos(p["kcal_per_serving"]) ?? pos(p["kcal_per_piece"])
        if str(p["photo_shows"]) == "neither" || anyKcal == nil {
            throw Failure(message: "Couldn't tell what that is. Get the pack or its nutrition table in the frame and try again.")
        }
        let guessed = str(p["numbers_from"]) == "estimate", fromPack = str(p["photo_shows"]) == "pack"
        var item: JSON = ["source": guessed ? "claude" : "label", "name": str(p["name"]), "unit": str(p["unit"]) == "ml" ? "ml" : "g"]
        if !str(p["brand"]).isEmpty { item["brand"] = str(p["brand"]) }
        var label = str(p["piece_name"]).lowercased(); if label.hasSuffix("s") { label.removeLast() }
        if !label.isEmpty { item["unitLabel"] = label }
        if num(p["protein_per_100"]) != nil || num(p["carbs_per_100"]) != nil || num(p["fat_per_100"]) != nil {
            item["p100"] = num(p["protein_per_100"]) ?? 0; item["c100"] = num(p["carbs_per_100"]) ?? 0; item["f100"] = num(p["fat_per_100"]) ?? 0
        }
        if let k = pos(p["kcal_per_100"]) { item["kcalPer100"] = k.rounded() }
        if let v = pos(p["serving_size"]) { item["servingSize"] = v }
        if let v = pos(p["kcal_per_serving"]) { item["kcalPerServing"] = v.rounded() }
        if let v = pos(p["pack_size"]) { item["packSize"] = v }
        if let v = pos(p["pieces_per_pack"]) { item["piecesPerPack"] = v }
        // one piece, when the AI could say what one is: that's what "how many?" counts
        var pw = pos(p["piece_weight"]); let pk = pos(p["kcal_per_piece"])
        if pw == nil, let pack = pos(item["packSize"]), let pcs = pos(item["piecesPerPack"]) { pw = (pack / pcs * 10).rounded() / 10 }
        if pos(item["kcalPer100"]) == nil, let pk, let pw { item["kcalPer100"] = (pk / pw * 100).rounded() }
        if !label.isEmpty, pk != nil || (pw != nil && pos(item["kcalPer100"]) != nil) {
            if let pw { item["servingSize"] = pw } else { item["servingSize"] = nil }
            item["kcalPerServing"] = (pk ?? (pw ?? 0) * (pos(item["kcalPer100"]) ?? 0) / 100).rounded()
            if let pack = pos(item["packSize"]), let pcs = pos(item["piecesPerPack"]), let pw, abs(pack / pcs - pw) > pw * 0.15 { item["piecesPerPack"] = nil }
        }

        var source = guessed ? "estimate" : (fromPack ? "pack" : "table")
        var webTried = ""
        if fromPack && guessed {
            await progress("Checking the numbers…")
            if await packLookup(&item) { source = "matched" }
            else {
                await progress("Searching online for this product…")
                webTried = await webLookup(&item, imagePart: imagePart)
                if webTried == "found" { source = "web" }
            }
        }
        if fromPack { packAsCount(&item) }
        return Result(item: item, note: note(item, source: source, webTried: webTried))
    }

    // MARK: Open Food Facts, by brand and product name

    private static let aliases: [(String, String)] = [(#"\bm\s*(?:&|and)\s*s\b"#, "marks spencer"), (#"\bmarks\s*(?:&|and)\s*spencers?\b"#, "marks spencer"),
        (#"\bco-?op(?:erative)?\b"#, "coop"), (#"\bsainsbury'?s\b"#, "sainsbury"), (#"\bmorrisons?\b"#, "morrison"), (#"\bwoolies\b"#, "woolworths"),
        (#"\bmcvitie'?s\b"#, "mcvitie"), (#"\barnott'?s\b"#, "arnott")]
    private static let stop: Set<String> = ["the", "and", "with", "for", "pack", "each", "new", "original", "classic", "free", "from"]
    private static let same: Set<String> = ["fruited", "fruity", "fruit", "spiced", "traditional", "british", "luxury", "finest", "best", "taste", "difference", "collection",
        "extra", "large", "soft", "our", "by", "mixed", "bakery", "baked", "freshly", "fresh", "select", "essential", "essentials", "value", "everyday", "biscuits", "biscuit",
        "buns", "bun", "crumpet", "crumpets", "cookies", "cookie"]

    static func words(_ s: String) -> [String] {
        var t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        for (re, to) in aliases { t = t.replacingOccurrences(of: re, with: to, options: .regularExpression) }
        t = t.replacingOccurrences(of: #"'s\b"#, with: "", options: .regularExpression).replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression)
        return t.split(separator: " ").map(String.init).filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) && !stop.contains($0) }
    }

    /// The real numbers from Open Food Facts when the brand and product match and the calories are close; never a different flavour.
    static func packLookup(_ item: inout JSON) async -> Bool {
        let want = words(str(item["name"])), brand = words(str(item["brand"]))
        guard !want.isEmpty, !brand.isEmpty, let k100 = pos(item["kcalPer100"]) else { return false }
        let terms = "\(str(item["brand"])) \(str(item["name"]))".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let fields = "product_name,product_name_en,brands,quantity,product_quantity,product_quantity_unit,serving_size,serving_quantity,nutriments,categories_tags,countries_tags"
        let base = "https://world.openfoodfacts.org/cgi/search.pl?search_terms=\(terms)&search_simple=1&action=process&json=1&page_size=15&fields=\(fields)"
        let country = ShopCountry.current
        let urls = (country.map { ["\(base)&tagtype_0=countries&tag_contains_0=contains&tag_0=\($0.tag)"] } ?? []) + [base]
        for u in urls {
            guard let url = URL(string: u), let products = await products(url) else { continue }
            var best: JSON?, bestScore = 0.0
            for p in products {
                let it = OpenFoodFacts.item(from: p)
                guard let k = pos(it["kcalPer100"]), !str(it["name"]).isEmpty else { continue }
                let ratio = k / k100; guard ratio >= 0.75 && ratio <= 1.35 else { continue }
                let have = words(str(it["name"]) + " " + str(it["brand"]))
                guard brand.contains(where: { have.contains($0) }) else { continue }
                let hit = want.filter { have.contains($0) }.count
                guard hit >= min(2, want.count) else { continue }
                if have.contains(where: { !want.contains($0) && !brand.contains($0) && !same.contains($0) }) { continue }   // a different variety
                let here = country.map { c in ((p["countries_tags"] as? [String]) ?? []).contains { $0.hasSuffix(c.tag) } } ?? false
                let score = Double(hit) + (here ? 0.5 : 0) - Double(have.filter { same.contains($0) }.count) * 0.05
                if score > bestScore { best = it; bestScore = score }
            }
            guard let b = best, let k = pos(b["kcalPer100"]) else { continue }
            item["kcalPer100"] = k
            if b["p100"] != nil { item["p100"] = b["p100"]; item["c100"] = b["c100"] ?? 0; item["f100"] = b["f100"] ?? 0 }
            if let sv = pos(item["servingSize"]) { item["kcalPerServing"] = (k * sv / 100).rounded() }
            if pos(item["packSize"]) == nil, let pack = pos(b["packSize"]) { item["packSize"] = pack }
            item["source"] = "barcode"; item["matched"] = str(b["name"])
            return true
        }
        return false
    }

    private static func products(_ url: URL) async -> [JSON]? {
        for _ in 0..<2 {
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("CheatDays iOS (domchivers.github.io/cheat-day)", forHTTPHeaderField: "User-Agent")
            if let res = try? await URLSession.shared.data(for: req) {
                let (d, r) = res
                let status = (r as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let j = try? JSONSerialization.jsonObject(with: d) as? JSON { return list(j["products"]) }
                if status != 503 && status != 429 { return nil }
            }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
        }
        return nil
    }

    // MARK: the web, for packs nobody has listed

    static func webLookup(_ item: inout JSON, imagePart: JSON) async -> String {
        let q = """
        This is a photo of a packaged food or drink. Read everything printed on it, in any language (Chinese, Japanese, Korean, Thai and so on), including the brand and the flavour.
        My first guess: "\(str(item["brand"]).isEmpty ? "" : str(item["brand"]) + " ")\(str(item["name"]))", about \(Fmt.int(num(item["kcalPer100"]) ?? 0)) kcal per 100 \(str(item["unit"])).\(ShopCountry.current.map { " I shop in \($0.name)." } ?? "")
        Use Google Search to find this exact product (same brand, same flavour, same size if you can) and its nutrition information: the manufacturer's site, a supermarket or online shop listing, Open Food Facts, or a nutrition database. Search in the pack's own language too.
        Chinese nutrition tables (营养成分表) give energy (能量) in kJ per 100 g: convert to kcal by dividing by 4.184. NRV% is not a quantity.
        Reply with ONLY a JSON object, no other text:
        {"found": true or false, "name_en": "English name with the flavour", "name_original": "the name as printed, or null", "brand": "brand in English, or null", "kcal_per_100": number or null, "protein_per_100": number or null, "carbs_per_100": number or null, "fat_per_100": number or null, "pack_size": number or null, "pieces_per_pack": number or null, "piece_name": "what one piece is called, or null", "piece_weight": number or null, "source": "the website the numbers came from", "notes": "one short sentence: how sure you are that it's the same product"}
        Set found to false if you can't find nutrition figures for this product, rather than guessing.
        """
        guard let answer = await Gemini.askWithSearch(parts: [imagePart, ["text": q]]) else { return "error" }
        guard let r = answer.text.range(of: #"\{[\s\S]*\}"#, options: .regularExpression), let data = String(answer.text[r]).data(using: .utf8),
              let got = try? JSONSerialization.jsonObject(with: data) as? JSON else { return "notfound" }
        guard (got["found"] as? Bool) == true, let k = pos(got["kcal_per_100"]), k >= 20, k <= 950 else { return "notfound" }
        if let first = pos(item["kcalPer100"]), k < first * 0.5 || k > first * 1.8 { return "far" }
        item["kcalPer100"] = k.rounded()
        if let pr = num(got["protein_per_100"]) { item["p100"] = pr; item["c100"] = num(got["carbs_per_100"]) ?? 0; item["f100"] = num(got["fat_per_100"]) ?? 0 }
        let en = str(got["name_en"]), orig = str(got["name_original"])
        if !en.isEmpty { item["name"] = !orig.isEmpty && orig != en ? "\(en) (\(orig))" : en }
        if !str(got["brand"]).isEmpty { item["brand"] = str(got["brand"]) }
        if pos(item["packSize"]) == nil, let v = pos(got["pack_size"]) { item["packSize"] = v }
        if pos(item["piecesPerPack"]) == nil, let v = pos(got["pieces_per_pack"]) { item["piecesPerPack"] = v }
        var label = str(item["unitLabel"])
        if label.isEmpty, !str(got["piece_name"]).isEmpty { label = str(got["piece_name"]).lowercased(); if label.hasSuffix("s") { label.removeLast() }; item["unitLabel"] = label }
        let pw = pos(got["piece_weight"]) ?? pos(item["servingSize"])
        if !label.isEmpty, let pw { item["servingSize"] = pw; item["kcalPerServing"] = (pw * k / 100).rounded() }
        else if let sv = pos(item["servingSize"]) { item["kcalPerServing"] = (sv * k / 100).rounded() }
        item["web"] = String((str(got["source"]).isEmpty ? (answer.sources.first ?? "the web") : str(got["source"])).prefix(60))
        return "found"
    }

    /// A small bag or bar eaten whole: count bags or packs, with a half a tap away.
    static func packAsCount(_ item: inout JSON) {
        guard str(item["unitLabel"]).isEmpty, let pack = pos(item["packSize"]), pack <= 250, let k = pos(item["kcalPer100"]) else { return }
        let text = (str(item["name"]) + " " + str(item["brand"])).lowercased()
        item["unitLabel"] = text.range(of: "crisp|chip|puff|snack|popcorn|薯|片", options: .regularExpression) != nil ? "bag" : "pack"
        item["servingSize"] = pack
        item["kcalPerServing"] = (pack * k / 100).rounded()
        item["piecesPerPack"] = nil
    }

    static func note(_ item: JSON, source: String, webTried: String) -> String {
        let c = FoodMath.conv(item)
        let what = c.countKcal.map { "\(Fmt.int($0)) kcal per \(c.countLabel ?? "piece")" } ?? "\(Fmt.int(c.kcalPer100 ?? 0)) kcal per 100 \(str(item["unit"]))"
        switch source {
        case "web": return "\(what), found online (\(str(item["web"])))."
        case "matched": return "\(what), from Open Food Facts."
        case "pack": return "\(what), read off the pack."
        case "table": return "\(what), read off the nutrition table."
        default:
            let why = ["notfound": " It couldn't be found online.", "far": " What was found online didn't look like the same product.", "error": " The online search didn't work."][webTried] ?? ""
            return "About \(what), an estimate.\(why) A photo of the nutrition table on the back is more exact."
        }
    }
}
