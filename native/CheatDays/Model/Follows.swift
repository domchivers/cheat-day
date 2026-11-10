import SwiftUI

/// Following: one-way, posts only (never your day, week or food log). A public profile is followed straight away; a
/// private one gets a request to accept in Activity. Also blocking, people search, "From your friends", and Explore.
@Observable @MainActor
final class Follows {
    static let shared = Follows()

    private(set) var mine: [JSON] = []     // rows where I'm the follower
    private(set) var ofMe: [JSON] = []     // rows where I'm the followee
    private(set) var blocked: Set<String> = []
    private(set) var explore: [JSON] = []
    private(set) var loaded = false   // who I follow has come down at least once: until then the button waits
    private(set) var exploring = false
    var error: String?
    private var api: Supabase { Supabase.shared }
    var me: String { api.userId ?? "" }

    private func rows(_ path: String, method: String = "GET", body: Any? = nil) async throws -> [JSON] {
        let d = try await api.rest(path, method: method, body: body)
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    func load() async {
        defer { loaded = true }   // a failed or signed-out load still ends the wait, so the button shows Follow
        guard !me.isEmpty else { return }
        mine = (try? await rows("/rest/v1/follows?follower=eq.\(me)&select=*")) ?? []
        ofMe = (try? await rows("/rest/v1/follows?followee=eq.\(me)&select=*&order=created_at.desc")) ?? []
        blocked = Set(((try? await rows("/rest/v1/blocks?blocker=eq.\(me)&select=blocked")) ?? []).map { str($0["blocked"]) })
        await Profiles.shared.load(mine.map { str($0["followee"]) } + ofMe.map { str($0["follower"]) })
    }

    /// People I follow (accepted): their posts are in my feed.
    var following: [String] { mine.filter { str($0["status"]) == "accepted" }.map { str($0["followee"]) } }
    var requests: [JSON] { ofMe.filter { str($0["status"]) == "pending" } }
    var followers: [JSON] { ofMe.filter { str($0["status"]) == "accepted" } }

    enum State { case none, requested, following }
    func state(_ id: String) -> State {
        guard let r = mine.first(where: { str($0["followee"]) == id }) else { return .none }
        return str(r["status"]) == "accepted" ? .following : .requested
    }
    func followsMe(_ id: String) -> Bool { followers.contains { str($0["follower"]) == id } }

    func follow(_ id: String) async {
        guard id != me, state(id) == .none else { return }
        let isPublic = Profiles.shared.all[id].map { !$0.isPrivate } ?? false
        let friend = Friends.shared.people.contains { $0.id == id }
        let status = isPublic || friend ? "accepted" : "pending"
        do {
            // the server has the last word (follow_status_server.sql): a friend or a public profile is followed straight away
            let d = try await api.rest("/rest/v1/follows", method: "POST", body: [["follower": me, "followee": id, "status": status]], prefer: "return=representation")
            let got = ((try? JSONSerialization.jsonObject(with: d)) as? [JSON])?.first.map { str($0["status"]) } ?? status
            mine.removeAll { str($0["followee"]) == id }
            mine.append(["follower": me, "followee": id, "status": got.isEmpty ? status : got])
            notify(id, got == "accepted" ? "follow" : "follow_request")
            error = nil
        } catch { self.error = "Couldn't follow: following needs setting up (supabase/followers_explore.sql)." }
    }

    /// Unfollow, or take back a request.
    func unfollow(_ id: String) async {
        _ = try? await api.rest("/rest/v1/follows?follower=eq.\(me)&followee=eq.\(id)", method: "DELETE")
        mine.removeAll { str($0["followee"]) == id }
    }

    func accept(_ follower: String) async {
        _ = try? await api.rest("/rest/v1/follows?follower=eq.\(follower)&followee=eq.\(me)", method: "PATCH", body: ["status": "accepted"])
        if let i = ofMe.firstIndex(where: { str($0["follower"]) == follower }) { ofMe[i]["status"] = "accepted" }
    }

    /// Decline a request, or remove a follower.
    func remove(_ follower: String) async {
        _ = try? await api.rest("/rest/v1/follows?follower=eq.\(follower)&followee=eq.\(me)", method: "DELETE")
        ofMe.removeAll { str($0["follower"]) == follower }
    }

    func block(_ id: String) async {
        _ = try? await api.rest("/rest/v1/blocks", method: "POST", body: [["blocker": me, "blocked": id]])
        await unfollow(id); await remove(id)
        blocked.insert(id)
    }
    func unblock(_ id: String) async {
        _ = try? await api.rest("/rest/v1/blocks?blocker=eq.\(me)&blocked=eq.\(id)", method: "DELETE")
        blocked.remove(id)
    }

    func counts(_ id: String) async -> (followers: Int, following: Int)? {
        guard let r = try? await rows("/rest/v1/rpc/follow_counts", method: "POST", body: ["u": id]).first else { return nil }
        return (Int(num(r["followers"]) ?? 0), Int(num(r["following"]) ?? 0))
    }

    /// Someone's followers or who they follow ("followers" or "following"), newest first.
    func list(_ id: String, _ which: String) async -> [String] {
        let got = (try? await rows("/rest/v1/rpc/follow_list", method: "POST", body: ["u": id, "which": which])) ?? []
        let ids = got.map { str($0["user_id"]) }.filter { !$0.isEmpty }
        await Profiles.shared.load(ids)
        return ids
    }

    /// People by @name or name.
    func search(_ q: String) async -> [Profiles.Profile] {
        let t = q.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
        guard t.count >= 2, let enc = t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return [] }
        let got = (try? await rows("/rest/v1/profiles?or=(username.ilike.*\(enc)*,display_name.ilike.*\(enc)*)&select=*&limit=25")) ?? []
        let people = got.map { Profiles.Profile($0) }.filter { $0.id != me && !blocked.contains($0.id) }
        Profiles.shared.keep(people)
        return people
    }

    /// People my friends follow: (who, a friend who follows them, how many friends do).
    func suggestions() async -> [(id: String, via: String, n: Int)] {
        let got = (try? await rows("/rest/v1/rpc/follow_suggestions", method: "POST", body: [String: Any]())) ?? []
        let out = got.map { (id: str($0["user_id"]), via: str($0["via"]), n: Int(num($0["n"]) ?? 1)) }
        await Profiles.shared.load(out.map(\.id) + out.map(\.via))
        return out
    }

    func loadExplore() async {
        exploring = true; defer { exploring = false }
        do {
            explore = try await rows("/rest/v1/rpc/explore_posts", method: "POST", body: ["lim": 90]).filter { !blocked.contains(str($0["owner"])) }
            error = nil
            await Profiles.shared.load(explore.map { str($0["owner"]) })
            await Feed.shared.loadExtras(explore)
        } catch { self.error = "Explore needs setting up (supabase/followers_explore.sql)." }
    }

    private func notify(_ to: String, _ kind: String) {
        Task { _ = try? await api.call("/functions/v1/push", body: ["action": "notify", "to": to, "kind": kind, "text": ""] as JSON) }
    }
}
