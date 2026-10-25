import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence's on-device model, for the quick jobs: "chicken wrap and a coke" to log, a short question,
/// "it was a large one". Instant, free and offline on iPhones that have it (15 Pro and newer, Apple Intelligence on).
/// Anything bigger (photos, recipes, plans, changing today's list), or any trouble, goes to Gemini as before.
enum OnDevice {
    /// The Settings switch (on unless turned off).
    static var allowed: Bool {
        get { UserDefaults.standard.object(forKey: "ai.onDevice") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ai.onDevice") }
    }

    /// Whether this iPhone can do it right now.
    static var ready: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var usable: Bool { allowed && ready }

    /// Why it isn't on, for Settings.
    static var status: String {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Quick questions and logging are answered on this iPhone, instantly and offline."
            case .unavailable(.deviceNotEligible): return "This iPhone can't run Apple Intelligence (iPhone 15 Pro or newer), so everything uses the online AI."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in the iPhone's Settings to use it."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. It'll be used once it's ready."
            default: return "Apple Intelligence isn't available right now, so the online AI answers."
            }
        }
        #endif
        return "Needs iOS 26 and an iPhone 15 Pro or newer."
    }

    /// A simple message, answered on the phone in the assistant's usual shape (kind estimate or answer).
    /// Nil when it's not a quick job, or anything went wrong: the caller asks Gemini instead.
    static func assistant(_ text: String, context: String) async -> JSON? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), usable { return await QuickModel.assistant(text, context: context) }
        #endif
        return nil
    }

    /// "It was a large one": the logged food after the change. Nil means ask Gemini.
    static func tweak(_ now: String, change: String) async -> JSON? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), usable { return await QuickModel.tweak(now, change: change) }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
private enum QuickModel {
    @Generable
    enum Kind { case log, question, other }

    @Generable
    struct Part {
        @Guide(description: "One component, e.g. 'Grilled chicken breast'")
        var name: String
        @Guide(description: "Grams as eaten")
        var grams: Double
        var kcal: Double
        var protein_g: Double
        var carbs_g: Double
        var fat_g: Double
    }

    @Generable
    struct Reply {
        @Guide(description: "log: they're telling you food they ate or will eat. question: a short question you can answer in a sentence or two. other: anything else (a recipe, a plan, a lighter version, correcting today's list, logging exercise, comparing).")
        var kind: Kind
        @Guide(description: "What you'd say back, warm and short (one or two sentences)")
        var reply: String
        @Guide(description: "For log: a short name for the food or plate")
        var name: String
        @Guide(description: "For log: total grams (or ml for drinks) as one portion")
        var portion_g: Double
        @Guide(description: "For log: total calories for the portion")
        var kcal_total: Double
        var protein_g: Double
        var carbs_g: Double
        var fat_g: Double
        @Guide(description: "For log: each component with its grams, oil and sauces as their own parts")
        var parts: [Part]
    }

    @Generable
    struct Tweaked {
        @Guide(description: "The food's name, updated if the change alters it")
        var name: String
        @Guide(description: "Calories for the whole amount after the change")
        var kcal: Double
        @Guide(description: "Grams after the change, or 0 if it can't be judged")
        var grams: Double
        var protein_g: Double
        var carbs_g: Double
        var fat_g: Double
        @Guide(description: "One short sentence saying what changed")
        var reply: String
    }

    static func assistant(_ text: String, context: String) async -> JSON? {
        let session = LanguageModelSession(instructions: """
        You are the assistant in Cheat Days, a friendly calorie diary where treats are part of the plan. \(context)
        Give honest calories and macros using standard reference values. If they give numbers themselves, use exactly those. Never preachy.
        """)
        guard let r = try? await session.respond(to: "They say: \"\(text)\"", generating: Reply.self).content else { return nil }
        switch r.kind {
        case .other: return nil
        case .question:
            guard !r.reply.isEmpty else { return nil }
            return ["kind": "answer", "reply": r.reply, "engine": "device"]
        case .log:
            guard r.kcal_total > 0, !r.name.isEmpty else { return nil }
            let parts: [JSON] = r.parts.filter { $0.grams > 0 }.map {
                ["name": $0.name, "usda_name": $0.name, "grams": $0.grams, "kcal": $0.kcal, "protein_g": $0.protein_g, "carbs_g": $0.carbs_g, "fat_g": $0.fat_g]
            }
            let estimate: JSON = ["name": r.name, "portion_g": r.portion_g, "unit": "g", "kcal_total": r.kcal_total,
                                  "protein_g": r.protein_g, "carbs_g": r.carbs_g, "fat_g": r.fat_g, "notes": "", "parts": parts]
            return ["kind": "estimate", "reply": r.reply.isEmpty ? "Here's my estimate." : r.reply, "estimate": estimate, "engine": "device"]
        }
    }

    static func tweak(_ now: String, change: String) async -> JSON? {
        let session = LanguageModelSession(instructions: "You correct foods logged in a calorie diary, using standard reference values. If they give numbers, use exactly those.")
        let prompt = "Logged: \(now). They say: \"\(change)\". Give the food as it should be logged after that change (large, small, double, half, no sauce, extra cheese and so on: scale or adjust sensibly)."
        guard let t = try? await session.respond(to: prompt, generating: Tweaked.self).content, t.kcal > 0 else { return nil }
        return ["name": t.name, "kcal": t.kcal, "grams": t.grams > 0 ? t.grams : NSNull(), "protein_g": t.protein_g, "carbs_g": t.carbs_g, "fat_g": t.fat_g, "reply": t.reply]
    }
}
#endif
