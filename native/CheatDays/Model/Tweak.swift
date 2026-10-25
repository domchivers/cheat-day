import Foundation

/// Change a logged food by saying what was different: "it was a large one", "no sauce", "half the rice".
/// The quick AI gives the corrected food; it replaces the old one in place (same entry, same meal).
enum Tweak {
    private static let schema: JSON = ["type": "object", "properties": [
        "name": ["type": "string", "description": "The food's name, updated if the change alters it (e.g. 'Large flat white')"] as JSON,
        "kcal": ["type": "number", "description": "Calories for the whole amount after the change"] as JSON,
        "grams": ["type": "number", "nullable": true, "description": "The amount in grams (or ml) after the change, if it can be judged"] as JSON,
        "protein_g": ["type": "number"] as JSON, "carbs_g": ["type": "number"] as JSON, "fat_g": ["type": "number"] as JSON,
        "reply": ["type": "string", "description": "One short sentence saying what changed, e.g. 'Large size: 190 kcal instead of 120.'"] as JSON
    ] as JSON, "required": ["name", "kcal", "grams", "protein_g", "carbs_g", "fat_g", "reply"]]

    struct Result { let item: JSON; let reply: String }

    @MainActor
    static func ask(_ item: JSON, change: String) async throws -> Result {
        let kcal = num(item["kcal"]) ?? 0
        let m = FoodMath.macros(item, kcal: kcal)
        let grams = num(item["grams"]) ?? FoodMath.amounts(item, kcal: kcal).grams
        let now = "\"\(str(item["name"]))\": \(Int(kcal)) kcal" + (grams.map { ", \(Int($0)) g" } ?? "")
            + (m.map { ", protein \(Int($0.p)) g, carbs \(Int($0.c)) g, fat \(Int($0.f)) g" } ?? "")
        let prompt = """
        A food logged in a calorie diary (in \(Plan.country)): \(now).
        The person says: "\(change)".
        Give the food as it should be logged after that change, using standard reference values: if they say large, small, double, half, no sauce, extra cheese and so on, scale or adjust the calories and macros sensibly. If they give numbers, use exactly those. Keep the name short.
        """
        let a: JSON
        if let local = await OnDevice.tweak(now, change: change) { a = local }
        else { a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true) }
        guard let k = pos(a["kcal"]) else { throw Gemini.Failure(message: "Couldn't work that change out. Try saying it another way.") }
        let p = num(a["protein_g"]) ?? 0, c = num(a["carbs_g"]) ?? 0, f = num(a["fat_g"]) ?? 0
        var b: JSON = ["name": str(a["name"]).isEmpty ? str(item["name"]) : str(a["name"]), "source": str(item["source"]).isEmpty ? "manual" : str(item["source"]),
                       "unit": str(item["unit"]).isEmpty ? "g" : str(item["unit"]), "unitLabel": "portion",
                       "kcalPerServing": k.rounded(), "pServ": p, "cServ": c, "fServ": f]
        if let g = pos(a["grams"]) {
            b["servingSize"] = g.rounded(); b["kcalPer100"] = (k / g * 1000).rounded() / 10
            b["p100"] = p / g * 100; b["c100"] = c / g * 100; b["f100"] = f / g * 100; b["grams"] = g.rounded()
        }
        b["kcal"] = Int(k.rounded())
        return Result(item: b, reply: str(a["reply"]))
    }

    /// Replace a logged food's details, keeping its place: id, meal, when it was added, any photo.
    static func applyOp(_ op: JSON, to d: inout JSON) {
        guard str(op["type"]) == "tweak" else { return }
        let id = str(op["id"]), new = dict(op["item"])
        var day = dict(d["day"]), items = list(day["items"])
        guard let i = items.firstIndex(where: { str($0["id"]) == id }) else { return }
        var it = new
        for k in ["id", "meal", "addedAt", "photo", "image"] { if let v = items[i][k] { it[k] = v } }
        it["shareLabel"] = items[i]["shareLabel"] ?? ""
        items[i] = it
        day["items"] = items; d["day"] = day
    }
}
