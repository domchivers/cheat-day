import UIKit
import XCTest
@testable import CheatDays

/// Real meals sent to the real AI through the app's own server (28 Nov; tools/meal-regress/meals.json): the same chat
/// the app runs, signed in as a test account, so the AI's own mistakes show (cooked bacon assumed, a label not looked
/// up), not just the app's. Skipped unless the test account's sign-in is in the environment, so ordinary runs never
/// call the AI. Each run uses the test account's daily AI allowance (a few calls a meal).
///
/// On the Mac, with the sign-in kept outside the repo (never committed, never typed into chat):
///   TEST_RUNNER_CD_LIVE_EMAIL=... TEST_RUNNER_CD_LIVE_PASSWORD=... [TEST_RUNNER_CD_LIVE_PHOTOS=/path/to/meal-regress/photos] \
///   xcodebuild test ... -only-testing:CheatDaysTests/LiveMealsTests
@MainActor
final class LiveMealsTests: XCTestCase {
    /// The test account's sign-in: read straight from ~/.cheatdays-live.env on the Mac (a simulator app can see the Mac's
    /// home through SIMULATOR_HOST_HOME), so it never goes on a command line or into a log. TEST_RUNNER_ variables didn't
    /// reach these app-hosted tests (28 Nov); the environment still wins when it has them.
    private var env: [String: String] {
        var out: [String: String] = [:]
        let pe = ProcessInfo.processInfo.environment
        if let home = pe["SIMULATOR_HOST_HOME"], let text = try? String(contentsOfFile: home + "/.cheatdays-live.env", encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
                var v = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
                out[String(l[..<eq]).trimmingCharacters(in: .whitespaces)] = v
            }
        }
        for k in ["CD_LIVE_EMAIL", "CD_LIVE_PASSWORD", "CD_LIVE_PHOTOS"] { if let v = pe[k], !v.isEmpty { out[k] = v } }
        return out
    }

    private func signedIn() async throws {
        guard let email = env["CD_LIVE_EMAIL"], let password = env["CD_LIVE_PASSWORD"], !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("No test account in the environment (CD_LIVE_EMAIL / CD_LIVE_PASSWORD): live meals skipped.")
        }
        if Supabase.shared.email.lowercased() != email.lowercased() { try await Supabase.shared.signIn(email: email, password: password) }
    }

    private func photos(_ names: [String]) throws -> [UIImage] {
        guard !names.isEmpty else { return [] }
        guard let dir = env["CD_LIVE_PHOTOS"] else { throw XCTSkip("A photo meal, and no CD_LIVE_PHOTOS folder: skipped.") }
        return try names.map { n in
            guard let img = UIImage(contentsOfFile: (dir as NSString).appendingPathComponent(n)) else { throw XCTSkip("Missing photo \(n)") }
            return img
        }
    }

    /// The chat as the app runs it, one message, and the checked card that comes back.
    private func ask(_ text: String, photos: [UIImage] = []) async throws -> (card: JSON, reply: String) {
        let turn = Assistant.Turn(me: true, text: text, result: nil, images: photos)
        let r: JSON
        do { r = try await Assistant.ask([turn], store: Store.shared) } catch {
            XCTFail("The chat failed: \(error.localizedDescription)"); throw error
        }
        let reply = str(r["reply"]).isEmpty ? str(r["text"]) : str(r["reply"])
        // what came back, so a miss says why (the kind of answer, its fields and the reply; never the account)
        let flat = { (s: String) in s.replacingOccurrences(of: "\n", with: " / ") }   // one line each, so the script's grep keeps it all
        print("LIVE \(flat(String(text.prefix(40))))… kind=\(str(r["kind"])) keys=\(r.keys.sorted()) reply=\(flat(String(reply.prefix(400))))")
        // several separate foods typed come back as one add each (kind edit), each checked against the tables like a
        // card's part (groundEdit): read them as the card's parts
        if str(r["kind"]) == "edit" {
            let adds = list(dict(r["edit"])["actions"]).filter { str($0["action"]) == "add" }
            let parts: [JSON] = adds.map { ["name": str($0["name"]), "grams": num($0["grams"]) ?? 0, "kcal": num($0["kcal"]) ?? 0, "src": str($0["src"])] }
            let card: JSON = ["parts": parts as [Any], "kcal_total": parts.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }]
            print("LIVE adds: \(parts.map { "\(str($0["name"])) \(Int(num($0["grams"]) ?? 0)) g \(Int(num($0["kcal"]) ?? 0)) kcal [\(str($0["src"]))]" }.joined(separator: "; ")) = \(Int(num(card["kcal_total"]) ?? 0))")
            return (card, reply)
        }
        guard let card = r["estimate"] as? JSON else {
            XCTFail("No estimate card: the answer was kind \"\(str(r["kind"]))\" with \(r.keys.sorted()). Reply: \(reply.prefix(300))")
            return ([:], reply)
        }
        print("LIVE card: \(list(card["parts"]).map { "\(str($0["name"])) \(Int(num($0["grams"]) ?? 0)) g \(Int(num($0["kcal"]) ?? 0)) kcal [\(str($0["src"]))]" }.joined(separator: "; ")) = \(Int(num(card["kcal_total"]) ?? 0))")
        return (card, reply)
    }

    private func part(_ card: JSON, _ words: [String]) -> JSON? {
        list(card["parts"]).first { p in let n = str(p["name"]).lowercased(); return words.contains { n.contains($0) } }
    }

    func testHomeBurgerWithAldiMince() async throws {
        try await signedIn()
        let (card, _) = try await ask("37g British streaky bacon\n250g jundurra Aldi 3 star beef mince\n10g light kewpie mayonnaise\n10g reduced sugar ketchup\n5g Australian mustard")
        let total = num(card["kcal_total"]) ?? 0
        XCTAssertTrue((680...820).contains(total), "about 750 kcal (3 Star label, raw bacon); got \(total)")
        let mince = part(card, ["mince"])
        XCTAssertTrue((560...650).contains(num(mince?["kcal"]) ?? 0), "the 3 Star mince is about 605 kcal for 250 g; got \(num(mince?["kcal"]) ?? 0)")
        let bacon = part(card, ["bacon"])
        XCTAssertTrue((90...125).contains(num(bacon?["kcal"]) ?? 0), "37 g raw streaky is about 100 kcal; got \(num(bacon?["kcal"]) ?? 0)")
        XCTAssertFalse(str(bacon?["name"]).lowercased().contains("cooked"), "weighed off the pack: raw")
    }

    func testChineseBreakfastHalfOfEverything() async throws {
        try await signedIn()
        let imgs = try photos(["breakfast-1.jpg", "breakfast-2.jpg", "breakfast-3.jpg", "breakfast-receipt.jpg"])
        let (card, reply) = try await ask("Had half of everything. Maybe 1/3 of the doujiang though", photos: imgs)
        let total = num(card["kcal_total"]) ?? 0
        XCTAssertTrue((900...1150).contains(total), "about 1,050 kcal from Taiwan's measured numbers; got \(total)")
        XCTAssertTrue((400...520).contains(num(part(card, ["youtiao", "fried dough"])?["kcal"]) ?? 0), "one youtiao, about 466 kcal")
        XCTAssertFalse(reply.lowercased().contains("menu") || reply.lowercased().contains("dish name"), "the receipt shows the names: only ask which shop. Reply: \(reply.prefix(200))")
    }
}
