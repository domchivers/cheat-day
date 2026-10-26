import Foundation

extension Friends {
    /// Send a saved meal or recipe (ingredients, method, portions) to a friend. It waits on their Today, where they
    /// can save it to their meals or have a portion. The website just sees a food with a portion's numbers.
    func sendMeal(_ meal: JSON, to p: Person) async throws {
        guard let me = Supabase.shared.userId else { throw APIError(status: 401, message: "Not signed in") }
        var payload = Store.shared.mealBasis(meal)
        var copy = meal
        copy.removeValue(forKey: "uses"); copy.removeValue(forKey: "lastUsed")
        payload["kind"] = "meal"; payload["meal"] = copy
        let per = num(payload["kcalPerServing"]) ?? 0
        var row: JSON = ["from_user": me, "to_user": p.id, "name": str(meal["name"]).isEmpty ? "A meal" : str(meal["name"]),
                         "kcal": Int(per.rounded()), "unit": "g", "payload": payload]
        row["grams"] = num(payload["servingSize"]).map { Int($0.rounded()) } ?? NSNull()
        row["photo"] = str(meal["photo"]).hasPrefix("http") ? str(meal["photo"]) : NSNull()
        _ = try await Supabase.shared.rest("/rest/v1/sends", method: "POST", body: [row])
        _ = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "notify", "to": p.id, "kind": "send", "text": "the recipe for " + str(row["name"])])
        Store.shared.perform(["type": "bump", "key": "sendCount"], syncAfter: 3)
    }

    /// Send one of your foods to a friend: it waits on their Today to add in one tap (the website's sendItem).
    func send(_ item: JSON, to p: Person) async throws {
        guard let me = Supabase.shared.userId else { throw APIError(status: 401, message: "Not signed in") }
        var row: JSON = ["from_user": me, "to_user": p.id, "name": item["name"] ?? "", "kcal": Int((num(item["kcal"]) ?? 0).rounded()),
                         "unit": str(item["unit"]).isEmpty ? "g" : str(item["unit"]), "payload": FoodMath.basisOf(item)]
        if let g = num(item["grams"]) ?? FoodMath.amounts(item, kcal: num(item["kcal"]) ?? 0).grams { row["grams"] = Int(g.rounded()) } else { row["grams"] = NSNull() }
        if str(item["photo"]).hasPrefix("http") { row["photo"] = str(item["photo"]) } else { row["photo"] = NSNull() }
        _ = try await Supabase.shared.rest("/rest/v1/sends", method: "POST", body: [row])
        _ = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "notify", "to": p.id, "kind": "send", "text": str(item["name"])])
        Store.shared.perform(["type": "bump", "key": "sendCount"], syncAfter: 3)
    }
}
