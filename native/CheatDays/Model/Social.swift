import Foundation
import Observation

/// Friends: who they are, their shared days this week, their streaks, and requests. Same tables as the website.
@MainActor @Observable
final class Friends {
    static let shared = Friends()

    struct Person: Identifiable {
        let id: String            // user id
        let friendship: String    // friendship row id
        let name: String
        var days: [JSON]          // their shared days, newest first
        var stats: JSON?
    }
    struct Request: Identifiable { let id: String; let from: String; let name: String }

    private(set) var people: [Person] = []
    private(set) var requests: [Request] = []
    private(set) var myCode = ""
    private(set) var myName = ""
    private(set) var loading = false
    private(set) var error: String?
    var cheered: Set<String> = []

    private func rows(_ path: String) async throws -> [JSON] {
        let d = try await Supabase.shared.rest(path)
        return (try JSONSerialization.jsonObject(with: d) as? [Any])?.compactMap { $0 as? JSON } ?? []
    }

    func load() async {
        guard let me = Supabase.shared.userId else { return }
        loading = true
        defer { loading = false }
        do {
            try await ensureProfile(me)
            let ships = try await rows("/rest/v1/friendships?select=*&order=created_at.desc")
            var ids = Set<String>()
            for f in ships { ids.insert(str(f["requester"])); ids.insert(str(f["addressee"])) }
            ids.remove(me)
            var profiles: [JSON] = []
            if !ids.isEmpty { profiles = try await rows("/rest/v1/profiles?user_id=in.(\(ids.joined(separator: ",")))&select=user_id,display_name,friend_code") }
            let names = Dictionary(profiles.map { (str($0["user_id"]), str($0["display_name"])) }, uniquingKeysWith: { a, _ in a })
            let since = DayKey.shift(DayKey.string(Date()), days: -7)
            let days = try await rows("/rest/v1/days?day=gte.\(since)&select=*&order=day.desc")
            let stats = (try? await rows("/rest/v1/stats?select=*")) ?? []
            var ps: [Person] = [], rs: [Request] = []
            for f in ships {
                let other = str(f["requester"]) == me ? str(f["addressee"]) : str(f["requester"])
                if str(f["status"]) == "accepted" {
                    ps.append(Person(id: other, friendship: str(f["id"]), name: names[other].flatMap { $0.isEmpty ? nil : $0 } ?? "Friend",
                                     days: days.filter { str($0["user_id"]) == other }, stats: stats.first { str($0["user_id"]) == other }))
                } else if str(f["addressee"]) == me {
                    rs.append(Request(id: str(f["id"]), from: other, name: names[other] ?? "Someone"))
                }
            }
            people = ps.sorted { ($0.isActive ? 0 : 1, $0.name) < ($1.isActive ? 0 : 1, $1.name) }
            requests = rs
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ensureProfile(_ me: String) async throws {
        if let p = try await rows("/rest/v1/profiles?user_id=eq.\(me)&select=*").first {
            myCode = str(p["friend_code"]); myName = str(p["display_name"]); return
        }
        let name = Supabase.shared.email.split(separator: "@").first.map(String.init) ?? "Me"
        let letters = String(name.filter(\.isLetter).prefix(3)).uppercased().padding(toLength: 3, withPad: "X", startingAt: 0)
        let code = "\(letters)-\(Int.random(in: 1000...9999))"
        _ = try await Supabase.shared.rest("/rest/v1/profiles", method: "POST", body: [["user_id": me, "display_name": name, "friend_code": code, "updated_at": ISO.now()] as JSON],
                                           prefer: "resolution=merge-duplicates,return=representation")
        myCode = code; myName = name
    }

    func cheer(_ p: Person) async {
        cheered.insert(p.id)
        _ = try? await Supabase.shared.call("/functions/v1/push", body: ["action": "notify", "to": p.id, "kind": "react", "text": "your day", "emoji": "👏"] as JSON)
    }

    func accept(_ r: Request) async {
        _ = try? await Supabase.shared.rest("/rest/v1/friendships?id=eq.\(r.id)", method: "PATCH", body: ["status": "accepted"] as JSON)
        await load()
    }

    /// Returns a message to show: sent, not found, or the problem.
    func add(code raw: String) async -> String {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard let me = Supabase.shared.userId, !code.isEmpty else { return "Type a friend code, like DOM-1234." }
        do {
            let enc = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
            guard let p = try await rows("/rest/v1/profiles?friend_code=eq.\(enc)&select=user_id,display_name").first else { return "No one has the code \(code)." }
            if str(p["user_id"]) == me { return "That's your own code." }
            _ = try await Supabase.shared.rest("/rest/v1/friendships", method: "POST", body: [["requester": me, "addressee": str(p["user_id"])] as JSON], prefer: "return=representation")
            return "Request sent to \(str(p["display_name"]))."
        } catch {
            return error.localizedDescription.contains("duplicate") ? "You've already sent them a request." : error.localizedDescription
        }
    }
}

extension Friends.Person {
    /// Their latest shared day, if it's still their today (a day touched in the last 18 hours counts, for family abroad).
    var current: JSON? {
        guard let d = days.first else { return nil }
        if str(d["day"]) == DayKey.string(Date()) { return d }
        if let t = ISO.date(d["updated_at"] as? String), Date().timeIntervalSince(t) < 18 * 3600 { return d }
        return nil
    }
    var food: [JSON] { list(current?["items"]).filter { !str($0["name"]).hasPrefix("Workout: ") } }
    var isActive: Bool { !food.isEmpty }
    var streak: Int { Int(num(stats?["streak"]) ?? 0) }
    var level: Int { Int(num(stats?["level"]) ?? 0) }

    /// The last seven days as on budget, a little over, over, or nothing logged; oldest first.
    var week: [Int] {
        (0..<7).reversed().map { back in
            let date = DayKey.shift(DayKey.string(Date()), days: -back)
            guard let d = days.first(where: { str($0["day"]) == date }), let b = pos(d["budget"]), let k = num(d["kcal"]), k > 0 else { return 0 }
            return k <= b ? 1 : (k <= b * 1.1 ? 2 : 3)
        }
    }
}

// MARK: what the helper set for this person (budget for the week, food edits), applied once each

extension Store {
    static let helperEmails = ["domchivers@gmail.com"]
    var isHelper: Bool { Self.helperEmails.contains(Supabase.shared.email.lowercased()) }

    /// Picks up a budget or food change the helper made for this account, like the website does on each sync.
    func applyHelperChanges() async {
        guard let me = Supabase.shared.userId, !isHelper else { return }
        if let d = try? await Supabase.shared.rest("/rest/v1/budget_overrides?user_id=eq.\(me)&select=*"),
           let o = ((try? JSONSerialization.jsonObject(with: d)) as? [Any])?.first as? JSON, let base = pos(o["budget"]),
           str(o["updated_at"]) != str(doc["overrideApplied"]) {
            let days = dict(o["days"])
            let week = (0...6).map { i in Int((pos(days[String(i)]) ?? base).rounded()) }
            var counts: [Int: Int] = [:]; week.forEach { counts[$0, default: 0] += 1 }
            let most = counts.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.first?.key ?? Int(base)
            var dayBudgets: JSON = [:]
            for (i, v) in week.enumerated() where v != most { dayBudgets[String(i)] = v }
            perform(["type": "override", "updatedAt": str(o["updated_at"]), "budget": most, "dayBudgets": dayBudgets, "planKcal": Int((Double(week.reduce(0, +)) / 7).rounded())])
            let names = Calendar.current.shortWeekdaySymbols   // Sunday first, like the stored day numbers
            let odd = [1, 2, 3, 4, 5, 6, 0].filter { week[$0] != most }.map { "\(names[$0]) \(Fmt.int(Double(week[$0])))" }
            notice = odd.isEmpty ? "Your daily budget was set to \(Fmt.int(Double(most))) kcal." : "Your budget for the week was set: \(Fmt.int(Double(most))) kcal most days, \(odd.joined(separator: ", "))."
        }
        if let d = try? await Supabase.shared.rest("/rest/v1/helper_edits?user_id=eq.\(me)&applied=eq.false&select=*&order=created_at.asc&limit=50"),
           let edits = (try? JSONSerialization.jsonObject(with: d)) as? [Any] {
            for case let e as JSON in edits {
                perform(["type": "helperEdit", "day": str(e["day"]), "name": str(e["item_name"]), "oldKcal": num(e["old_kcal"]) ?? 0,
                         "newKcal": num(e["new_kcal"]) ?? 0, "remove": (e["remove"] as? Bool) ?? false, "at": nowMs()])
                notice = (e["remove"] as? Bool) == true ? "\(str(e["item_name"])) was removed from \(str(e["day"]) == today ? "today" : str(e["day"]))."
                                                         : "\(str(e["item_name"])) was changed to \(Fmt.int(num(e["new_kcal"]) ?? 0)) kcal."
                _ = try? await Supabase.shared.rest("/rest/v1/helper_edits?id=eq.\(num(e["id"]).map { String(Int($0)) } ?? str(e["id"]))&user_id=eq.\(me)", method: "PATCH", body: ["applied": true] as JSON)
            }
        }
    }

    static func applyHelperOp(_ op: JSON, to d: inout JSON, today: String) {
        switch str(op["type"]) {
        case "override":
            d["overrideApplied"] = op["updatedAt"] ?? ""
            d["budget"] = op["budget"] ?? 1600
            d["dayBudgets"] = op["dayBudgets"] ?? JSON()
            if var plan = d["plan"] as? JSON { plan["kcal"] = op["planKcal"] ?? plan["kcal"] ?? 0; d["plan"] = plan }
        case "helperEdit":
            let date = str(op["day"]), key = str(op["name"]).lowercased(), oldK = (num(op["oldKcal"]) ?? 0).rounded()
            func change(_ items: inout [JSON]) -> String? {
                guard let i = items.firstIndex(where: { str($0["name"]).lowercased() == key && (num($0["kcal"]) ?? 0).rounded() == oldK })
                        ?? items.firstIndex(where: { str($0["name"]).lowercased() == key }) else { return nil }
                let id = str(items[i]["id"])
                if (op["remove"] as? Bool) == true { items.remove(at: i) }
                else { let k = Int((num(op["newKcal"]) ?? 0).rounded()); items[i]["kcal"] = k; if items[i]["kcalPerServing"] != nil && items[i]["servingSize"] == nil { items[i]["kcalPerServing"] = k } }
                return id
            }
            var day = dict(d["day"])
            if str(day["date"]) == date {
                var items = list(day["items"])
                if let id = change(&items) {
                    day["items"] = items; d["day"] = day
                    if (op["remove"] as? Bool) == true, !id.isEmpty { var tombs = dict(d["tombs"]); tombs["item:\(id)"] = op["at"] ?? nowMs(); d["tombs"] = tombs }
                }
            } else {
                var history = list(d["history"])
                if let h = history.firstIndex(where: { str($0["date"]) == date }) {
                    var items = list(history[h]["items"])
                    if change(&items) != nil {
                        history[h]["items"] = items
                        history[h]["kcal"] = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
                        var p = 0.0, c = 0.0, f = 0.0
                        for it in items { if let m = FoodMath.macros(it, kcal: num(it["kcal"]) ?? 0) { p += m.p; c += m.c; f += m.f } }
                        history[h]["p"] = Int(p.rounded()); history[h]["c"] = Int(c.rounded()); history[h]["f"] = Int(f.rounded())
                        d["history"] = history
                    }
                }
            }
        default: break
        }
    }
}
