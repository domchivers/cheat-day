import Foundation
import UIKit

/// Asks iOS for time to finish something after the app leaves the screen.
@MainActor
enum BackgroundWork {
    private final class Ticket { var id = UIBackgroundTaskIdentifier.invalid }
    static func run<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let t = Ticket()
        t.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(t.id); t.id = .invalid
        }
        defer { if t.id != .invalid { UIApplication.shared.endBackgroundTask(t.id) } }
        return try await work()
    }
}

/// The free Gemini models, through the app's shared key (the Supabase "ai" function), like the web app.
/// Each model has its own daily allowance; a refused or busy model is skipped for the next.
enum Gemini {
    static let flash = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash"]
    static let lite = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-flash-lite-latest"]
    /// Google Search is free only on these (about 500 a day); the newer models charge for it.
    static let search = ["gemini-2.5-flash", "gemini-2.5-flash-lite"]

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Which models are used up today. Google resets them at midnight Pacific time.
    private static var pacificDay: String {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "America/Los_Angeles"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
    private static func spent() -> Set<String> {
        let d = UserDefaults.standard
        guard d.string(forKey: "ai.day") == pacificDay else { return [] }
        return Set(d.stringArray(forKey: "ai.spent") ?? [])
    }
    private static func markSpent(_ model: String) {
        let d = UserDefaults.standard
        var s = spent(); s.insert(model)
        d.set(pacificDay, forKey: "ai.day"); d.set(Array(s), forKey: "ai.spent")
    }

    /// One structured answer: an image and a prompt in, JSON matching the schema out. It carries on for a while if
    /// you leave the app meanwhile (iOS gives about half a minute), so the answer is there when you come back.
    /// With a job, Claude answers (the server picks its model for that job); if it can't, the free Gemini models do.
    static func ask(schema: JSON, parts: [JSON], quick: Bool = true, tries: Int = 99, job: String? = nil) async throws -> JSON {
        try await BackgroundWork.run("AI") {
            if let job, let answer = await claude(job, schema: schema, parts: parts) { return answer }
            return try await askNow(schema: schema, parts: parts, quick: quick, tries: tries)
        }
    }

    private static func claude(_ job: String, schema: JSON, parts: [JSON], extra: JSON = [:]) async -> JSON? {
        let body: JSON = ["parts": parts, "schema": schema, "maxTokens": 12000].merging(extra) { _, new in new }
        guard let (d, status) = try? await Supabase.shared.call("/functions/v1/ai?job=\(job)", body: body, timeout: 60), status == 200,
              let reply = try? JSONSerialization.jsonObject(with: d) as? JSON, let data = str(reply["text"]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSON
    }

    private static let labelSchema: JSON = ["type": "object", "required": ["found", "serving_g", "kcal", "protein_g", "carbs_g", "fat_g", "source"], "properties": [
        "found": ["type": "boolean"] as JSON, "serving_g": ["type": "number"] as JSON, "kcal": ["type": "number"] as JSON,
        "protein_g": ["type": "number"] as JSON, "carbs_g": ["type": "number"] as JSON, "fat_g": ["type": "number"] as JSON,
        "source": ["type": "string", "description": "where the label was found, one line"] as JSON] as JSON]
    @MainActor private static var labels: [String: JSON] = [:]

    /// A packaged product's nutrition label, looked up on the web by Claude (about 2 cents, a few seconds): per serving,
    /// or nil when no real label turns up. Each product is looked up once per session.
    @MainActor
    static func lookUpLabel(_ product: String) async -> JSON? {
        let key = product.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if let known = labels[key] { return known["found"] as? Bool == true ? known : nil }
        let ask = "Find the nutrition panel for this packaged food sold in \(Plan.country): \"\(product)\". Give the numbers per serving exactly as its label says (the brand's own site or a supermarket listing), kcal from kJ ÷ 4.184 if only kJ is given. found false if you can't find a real label for this product."
        guard let answer = await claude("lookup", schema: labelSchema, parts: [["text": ask]], extra: ["country": Region.current.code]) else { return nil }
        labels[key] = answer
        guard answer["found"] as? Bool == true, (num(answer["serving_g"]) ?? 0) > 0, (num(answer["kcal"]) ?? 0) > 0 else { return nil }
        return answer
    }

    private static func askNow(schema: JSON, parts: [JSON], quick: Bool, tries: Int) async throws -> JSON {
        let order = Array((quick ? lite + flash : flash + lite).filter { !spent().contains($0) }.prefix(tries))
        guard !order.isEmpty else { throw Failure(message: "Today's free AI allowance is used up. It comes back tomorrow morning.") }
        var thinking: String? = quick ? "minimal" : "low"
        var lastProblem = "Couldn't reach the AI. Check the signal and try again."
        var i = 0
        while i < order.count {
            let model = order[i]
            var config: JSON = ["responseMimeType": "application/json", "responseSchema": schema, "temperature": 0.2]
            if let thinking, model.hasPrefix("gemini-3") { config["thinkingConfig"] = ["thinkingLevel": thinking] }
            let body: JSON = ["contents": [["parts": parts] as JSON], "generationConfig": config]
            do {
                let (d, status) = try await Supabase.shared.call("/functions/v1/ai?model=\(model)", body: body, timeout: quick ? 30 : 45)
                if status == 200 {
                    guard let text = textOf(d), let data = text.data(using: .utf8), let j = try JSONSerialization.jsonObject(with: data) as? JSON else {
                        lastProblem = "Couldn't understand the AI's answer. Try again."; i += 1; continue
                    }
                    return j
                }
                let t = String(data: d, encoding: .utf8) ?? ""
                if status == 400, thinking != nil, t.lowercased().contains("thinking") { thinking = nil; continue }   // an older model: ask again without that setting
                if status == 429 { if t.range(of: "PerDay|per day|daily", options: .regularExpression) != nil { markSpent(model) }; lastProblem = "The free AI is busy right now."; i += 1; continue }
                if status == 404 || status == 503 { i += 1; continue }
                if status == 401 || status == 500 { throw Failure(message: "The app's shared AI isn't available right now.") }
                lastProblem = "The AI said no (\(status))."; i += 1
            } catch let f as Failure { throw f }
            catch { lastProblem = "The free AI didn't answer in time. Try again in a moment."; i += 1 }
        }
        throw Failure(message: lastProblem)
    }

    /// A plain-text answer with Google Search switched on (the 2.5 models only, where it's free).
    static func askWithSearch(parts: [JSON]) async -> (text: String, sources: [String])? {
        for model in search where !spent().contains(model) {
            let body: JSON = ["contents": [["parts": parts] as JSON], "tools": [["google_search": [String: Any]()] as JSON], "generationConfig": ["temperature": 0.2] as JSON]
            guard let res = try? await Supabase.shared.call("/functions/v1/ai?model=\(model)", body: body, timeout: 35) else { continue }
            let (d, status) = res
            if status == 429 { let t = String(data: d, encoding: .utf8) ?? ""; if t.range(of: "PerDay|per day|daily", options: .regularExpression) != nil { markSpent(model) }; continue }
            if status == 404 || status == 400 || status == 403 { markSpent(model); continue }
            guard status == 200, let text = textOf(d) else { continue }
            let j = (try? JSONSerialization.jsonObject(with: d) as? JSON) ?? [:]
            let cand = list(j["candidates"]).first ?? [:]
            let sources = list(dict(cand["groundingMetadata"])["groundingChunks"]).compactMap { dict($0["web"])["title"] as? String }
            return (text, sources)
        }
        return nil
    }

    private static func textOf(_ d: Data) -> String? {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? JSON, let cand = list(j["candidates"]).first else { return nil }
        let text = list(dict(cand["content"])["parts"]).compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// A photo shrunk to 1024 px and sent as JPEG.
    static func imagePart(_ image: UIImage) -> JSON? {
        let maxSide: CGFloat = 1024
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = small.jpegData(compressionQuality: 0.8) else { return nil }
        return ["inline_data": ["mime_type": "image/jpeg", "data": data.base64EncodedString()] as JSON]
    }
}

/// Which country's shops the phone is in (products differ between countries), from its time zone.
enum ShopCountry {
    static var current: (tag: String, name: String)? {
        let tz = TimeZone.current.identifier
        if ["Europe/London", "Europe/Belfast", "Europe/Jersey", "Europe/Guernsey", "Europe/Isle_of_Man"].contains(tz) { return ("united-kingdom", "the UK") }
        if tz.hasPrefix("Australia/") { return ("australia", "Australia") }
        if tz == "Pacific/Auckland" { return ("new-zealand", "New Zealand") }
        if tz == "Europe/Dublin" { return ("ireland", "Ireland") }
        switch Locale.current.identifier { case "en_GB": return ("united-kingdom", "the UK"); case "en_AU": return ("australia", "Australia"); default: return nil }
    }
}
