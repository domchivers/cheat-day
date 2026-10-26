import Foundation

/// Family, by invitation: the helper asks a friend, and only once they tap Allow can the helper set their budget or
/// fix a food on their day. Either side can stop it any time. The server enforces the same (family_links, see README).
@Observable @MainActor
final class Family {
    static let shared = Family()

    struct Link: Identifiable, Equatable {
        let helper: String
        let member: String
        let status: String   // "asked" or "yes"
        var id: String { helper + "|" + member }
    }

    private(set) var links: [Link] = []
    private var api: Supabase { Supabase.shared }
    private var me: String { api.userId ?? "" }

    func load() async {
        guard api.userId != nil, let d = try? await api.rest("/rest/v1/family_links?select=*"),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] else { return }
        links = rows.map { Link(helper: str($0["helper"]), member: str($0["member"]), status: str($0["status"])) }
    }

    /// People I've asked or who said yes (I'm the helper).
    var mine: [Link] { links.filter { $0.helper == me } }
    /// Someone asking to help me, waiting for my answer.
    var asks: [Link] { links.filter { $0.member == me && $0.status == "asked" } }
    /// Who can set my budget.
    var helpers: [Link] { links.filter { $0.member == me && $0.status == "yes" } }

    func isFamily(_ id: String) -> Bool { mine.contains { $0.member == id && $0.status == "yes" } }
    func isAsked(_ id: String) -> Bool { mine.contains { $0.member == id && $0.status == "asked" } }

    func name(_ id: String) -> String { Friends.shared.people.first { $0.id == id }?.name ?? "A friend" }

    func ask(_ id: String) async throws {
        _ = try await api.rest("/rest/v1/family_links", method: "POST", body: [["helper": me, "member": id, "status": "asked"]])
        await load()
    }

    func answer(_ l: Link, yes: Bool) async {
        if yes { _ = try? await api.rest(path(l), method: "PATCH", body: ["status": "yes"]) }
        else { _ = try? await api.rest(path(l), method: "DELETE") }
        await load()
    }

    func remove(_ l: Link) async {
        _ = try? await api.rest(path(l), method: "DELETE")
        await load()
    }

    private func path(_ l: Link) -> String { "/rest/v1/family_links?helper=eq.\(l.helper)&member=eq.\(l.member)" }
}
