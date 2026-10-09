import Foundation
import UIKit

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

    /// One structured answer: an image and a prompt in, JSON matching the schema out.
    static func ask(schema: JSON, parts: [JSON], quick: Bool = true) async throws -> JSON {
        let order = (quick ? lite + flash : flash + lite).filter { !spent().contains($0) }
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
