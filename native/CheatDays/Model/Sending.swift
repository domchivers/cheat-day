import Foundation

extension Friends {
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
