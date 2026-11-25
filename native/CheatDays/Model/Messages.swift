import SwiftUI

/// One-to-one chats between friends: text, a photo, a post or a food (with ＋ to add it), reactions, and "Seen". And
/// group chats (25 Nov, design/group-chats-mockup.html, supabase/group_chats.sql): a group's chat id is "g:" and its
/// id, its messages carry group_id, and when I last read it is on my member row.
@Observable @MainActor
final class Messages {
    static let shared = Messages()

    struct Chat: Identifiable {
        let id: String   // the friend's user id, or "g:" and the group's id
        var last: JSON
        var unread: Int
        var isGroup: Bool { id.hasPrefix("g:") }
    }

    private(set) var groups: [JSON] = []    // the groups I'm in
    private(set) var members: [JSON] = []   // everyone in those groups (group_id, user_id, seen_at, muted)

    static func groupId(_ chat: String) -> String? { chat.hasPrefix("g:") ? String(chat.dropFirst(2)) : nil }
    func group(_ id: String) -> JSON? { groups.first { str($0["id"]) == id } }
    func people(in group: String) -> [JSON] { members.filter { str($0["group_id"]) == group }.sorted { str($0["joined_at"]) < str($1["joined_at"]) } }
    func myRow(in group: String) -> JSON? { members.first { str($0["group_id"]) == group && str($0["user_id"]) == me } }
    /// A group's name, or a friend's.
    func title(_ chat: String) -> String {
        if let g = Self.groupId(chat) { return group(g).map { str($0["name"]) } ?? "Group" }
        return Feed.shared.name(chat)
    }

    private(set) var recent: [JSON] = []   // my latest messages both ways, newest first
    private(set) var thread: [JSON] = []   // the open chat, oldest first
    private(set) var reactions: [JSON] = []
    private(set) var open: String?
    private(set) var loaded = false   // the list of chats has come down (or been tried) at least once
    var error: String?
    private var api: Supabase { Supabase.shared }
    var me: String { api.userId ?? "" }

    private func rows(_ path: String) async throws -> [JSON] {
        let d = try await api.rest(path)
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    /// One row per friend I've talked to, newest first.
    var chats: [Chat] {
        var seen: [String: Chat] = [:], order: [String] = []
        for m in recent {
            let g = str(m["group_id"])
            let other = !g.isEmpty ? "g:" + g : str(m["from_user"]) == me ? str(m["to_user"]) : str(m["from_user"])
            if !g.isEmpty && group(g) == nil { continue }   // a group I've left
            // a group's: someone else's, since I last read it
            let unread = !g.isEmpty ? (str(m["from_user"]) != me && str(m["created_at"]) > str(myRow(in: g)?["seen_at"]) ? 1 : 0)
                : (str(m["to_user"]) == me && str(m["seen_at"]).isEmpty ? 1 : 0)
            if var c = seen[other] { c.unread += unread; seen[other] = c } else { seen[other] = Chat(id: other, last: m, unread: unread); order.append(other) }
        }
        var out = order.compactMap { seen[$0] }
        // a group with nothing said yet, at the top: just made, or just joined
        for g in groups where seen["g:" + str(g["id"])] == nil {
            out.insert(Chat(id: "g:" + str(g["id"]), last: ["created_at": g["created_at"] ?? "", "text": "New group", "group_id": str(g["id"])], unread: 0), at: 0)
        }
        return out
    }
    var unread: Int { chats.filter { $0.unread > 0 }.count }

    func load() async {
        defer { loaded = true }   // signed out too: nothing's coming, so the list says so and doesn't shimmer for ever
        guard !me.isEmpty else { return }
        do {
            recent = try await rows("/rest/v1/messages?select=*&order=created_at.desc&limit=200")
            error = nil
            await loadGroups()
            await Profiles.shared.load(chats.filter { !$0.isGroup }.map(\.id) + members.map { str($0["user_id"]) })
        } catch { self.error = "Messages need setting up (supabase/profiles_messages.sql)." }
    }

    /// My groups and who's in them (none until supabase/group_chats.sql has been run: one-to-one carries on).
    func loadGroups() async {
        guard let g = try? await rows("/rest/v1/chat_groups?select=*&order=created_at.desc") else { return }
        let mine = Set((try? await rows("/rest/v1/chat_group_members?user_id=eq.\(me)&select=group_id"))?.map { str($0["group_id"]) } ?? [])
        groups = g.filter { mine.contains(str($0["id"])) }
        let ids = groups.map { str($0["id"]) }.joined(separator: ",")
        members = ids.isEmpty ? [] : (try? await rows("/rest/v1/chat_group_members?group_id=in.(\(ids))&select=*")) ?? members
    }

    /// A new group: me, then the people picked (the database checks each is a friend or a mutual follow). Its chat id.
    func makeGroup(_ name: String, people: [String]) async -> String? {
        do {
            let d = try await api.rest("/rest/v1/chat_groups", method: "POST", body: [["name": String(name.prefix(60)), "created_by": me]], prefer: "return=representation")
            guard let g = ((try? JSONSerialization.jsonObject(with: d)) as? [JSON])?.first else { throw APIError(status: 0, message: "") }
            let id = str(g["id"])
            _ = try await api.rest("/rest/v1/chat_group_members", method: "POST", body: [["group_id": id, "user_id": me, "added_by": me, "seen_at": ISO.now()]], prefer: "return=minimal")
            if !people.isEmpty { await add(people, to: id) }
            await loadGroups()
            return "g:" + id
        } catch {
            self.error = "Couldn't make the group. Group chats need setting up (supabase/group_chats.sql)."
            return nil
        }
    }

    func add(_ people: [String], to group: String) async {
        let rows: [JSON] = people.map { ["group_id": group, "user_id": $0, "added_by": me] }
        do { _ = try await api.rest("/rest/v1/chat_group_members?on_conflict=group_id,user_id", method: "POST", body: rows, prefer: "resolution=ignore-duplicates,return=minimal") }
        catch { self.error = "Couldn't add everyone: you can add friends, or people you follow who follow you back." }
        await loadGroups()
    }

    /// Leave a group (me), or, whoever made it, take someone out.
    func remove(_ user: String, from group: String) async {
        _ = try? await api.rest("/rest/v1/chat_group_members?group_id=eq.\(group)&user_id=eq.\(user)", method: "DELETE")
        await loadGroups()
    }

    func rename(_ group: String, to name: String) async {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !n.isEmpty else { return }
        _ = try? await api.rest("/rest/v1/chat_groups?id=eq.\(group)", method: "PATCH", body: ["name": n] as JSON, prefer: "return=minimal")
        await loadGroups()
    }

    func setMuted(_ group: String, _ on: Bool) async {
        _ = try? await api.rest("/rest/v1/chat_group_members?group_id=eq.\(group)&user_id=eq.\(me)", method: "PATCH", body: ["muted": on] as JSON, prefer: "return=minimal")
        await loadGroups()
    }

    /// Join by an invite code or link ("cheatdays://group/ab12cd34ef"): the group's chat id, or nil.
    func join(_ code: String) async -> String? {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last.map(String.init) ?? ""
        guard !c.isEmpty, let d = try? await api.rest("/rest/v1/rpc/join_group", method: "POST", body: ["code": c] as JSON),
              let id = (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? String, !id.isEmpty else {
            error = "That invite didn't work. Check the code and try again."
            return nil
        }
        await load()
        return "g:" + id
    }

    static func inviteLink(_ g: JSON) -> String { "cheatdays://group/" + str(g["invite"]) }

    /// The chat with one friend, marked as seen.
    func openChat(_ friend: String) async {
        open = friend
        await refresh()
    }
    func closeChat() { open = nil; thread = [] }

    func refresh() async {
        guard let f = open, !me.isEmpty else { return }
        if let g = Self.groupId(f) { await refreshGroup(g, chat: f); return }
        let q = "or=(and(from_user.eq.\(me),to_user.eq.\(f)),and(from_user.eq.\(f),to_user.eq.\(me)))"
        guard let got = try? await rows("/rest/v1/messages?\(q)&select=*&order=created_at.desc&limit=150") else { return }
        if open == f { thread = got.reversed() }
        let ids = got.map { str($0["id"]) }.joined(separator: ",")
        // a reaction just chosen isn't undone by a fetch that set off before it reached the server, and a fetch that
        // failed leaves what's showing alone
        let before = reacted
        if !ids.isEmpty, let rx = try? await rows("/rest/v1/message_reactions?message_id=in.(\(ids))&select=*"), reacted == before, sending == 0 { reactions = rx }
        if got.contains(where: { str($0["to_user"]) == me && str($0["seen_at"]).isEmpty }) {
            _ = try? await api.rest("/rest/v1/messages?to_user=eq.\(me)&from_user=eq.\(f)&seen_at=is.null", method: "PATCH", body: ["seen_at": ISO.now()])
            await load()
        }
    }

    /// A group's chat, newest last, and read up to now.
    private func refreshGroup(_ g: String, chat: String) async {
        guard let got = try? await rows("/rest/v1/messages?group_id=eq.\(g)&select=*&order=created_at.desc&limit=150") else { return }
        if open == chat { thread = got.reversed() }
        let ids = got.map { str($0["id"]) }.joined(separator: ",")
        let before = reacted
        if !ids.isEmpty, let rx = try? await rows("/rest/v1/message_reactions?message_id=in.(\(ids))&select=*"), reacted == before, sending == 0 { reactions = rx }
        if let newest = got.first, str(newest["created_at"]) > str(myRow(in: g)?["seen_at"]) {
            let now = ISO.now()
            _ = try? await api.rest("/rest/v1/chat_group_members?group_id=eq.\(g)&user_id=eq.\(me)", method: "PATCH", body: ["seen_at": now] as JSON, prefer: "return=minimal")
            if let i = members.firstIndex(where: { str($0["group_id"]) == g && str($0["user_id"]) == me }) { members[i]["seen_at"] = now }
        }
    }

    /// Text, or a photo, GIF, post or food with its details in payload. To a friend, or a group ("g:" and its id).
    func send(to friend: String, text: String = "", kind: String = "text", payload: JSON = [:]) async {
        let gid = Self.groupId(friend)
        let row: JSON = gid.map { ["from_user": me, "group_id": $0, "kind": kind, "text": text, "payload": payload] }
            ?? ["from_user": me, "to_user": friend, "kind": kind, "text": text, "payload": payload]
        do {
            let d = try await api.rest("/rest/v1/messages", method: "POST", body: [row], prefer: "return=representation")
            let made = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
            if open == friend { thread += made }
            recent.insert(contentsOf: made, at: 0)
            let preview = kind == "text" ? text : kind == "photo" ? "Sent a photo" : kind == "gif" ? "Sent a GIF" : kind == "post" ? "Sent a post: \(str(payload["name"]))" : kind == "story" ? (str(payload["reaction"]).isEmpty && str(payload["reply"]).isEmpty ? "Sent a story" : text) : "Sent food: \(str(payload["name"]))"
            if let gid {
                // everyone else in it who hasn't muted it (the push function checks I'm in the group)
                Task { _ = try? await api.call("/functions/v1/push", body: ["action": "group", "group": gid, "text": preview] as JSON) }
            } else {
                Task { _ = try? await api.call("/functions/v1/push", body: ["action": "notify", "to": friend, "kind": "message", "text": preview, "post": "chat:\(me)"] as JSON) }
            }
        } catch { self.error = gid == nil ? "Couldn't send: messages need setting up, or you're not friends." : "Couldn't send to the group. Check your connection." }
    }

    func sendPhoto(to friend: String, _ img: UIImage) async {
        guard let jpeg = Feed.prepare(img), let url = try? await api.uploadPhoto(jpeg) else { error = "Couldn't send the photo."; return }
        await send(to: friend, kind: "photo", payload: ["photo": url])
    }

    private var reacted = 0   // goes up with every reaction chosen
    private var sending = 0   // reactions on their way to the server

    /// One emoji of yours on a message: shown at once, then sent. The same one again takes it off.
    func react(_ m: JSON, _ emoji: String) async {
        let id = str(m["id"]), had = reactions
        let off = reactions.contains { str($0["message_id"]) == id && str($0["user_id"]) == me && str($0["emoji"]) == emoji }
        reactions.removeAll { str($0["message_id"]) == id && str($0["user_id"]) == me }
        if !off { reactions.append(["message_id": id, "user_id": me, "emoji": emoji]) }
        reacted += 1; sending += 1
        defer { sending -= 1 }
        do {
            if off { _ = try await api.rest("/rest/v1/message_reactions?message_id=eq.\(id)&user_id=eq.\(me)", method: "DELETE") }
            else {
                // one request: yours on this message is put in, or changed if there was one
                _ = try await api.rest("/rest/v1/message_reactions?on_conflict=message_id,user_id", method: "POST", body: [["message_id": id, "user_id": me, "emoji": emoji]], prefer: "resolution=merge-duplicates,return=minimal")
            }
        } catch {
            // not taken: put it back as it was and say so, not leave an emoji showing that nobody else sees
            reactions = had; reacted += 1
            self.error = "Couldn't react to that. Check your connection and try again."
        }
    }

    /// Your own text message, reworded; payload.edited marks it. False when the server didn't take it.
    func edit(_ m: JSON, text: String) async -> Bool {
        let id = str(m["id"])
        var p = dict(m["payload"]); p["edited"] = true
        guard let d = try? await api.rest("/rest/v1/messages?id=eq.\(id)&from_user=eq.\(me)", method: "PATCH", body: ["text": text, "payload": p] as JSON, prefer: "return=representation"),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON], !rows.isEmpty else { error = "Couldn't edit that message."; return false }
        for i in thread.indices where str(thread[i]["id"]) == id { thread[i]["text"] = text; thread[i]["payload"] = p }
        for i in recent.indices where str(recent[i]["id"]) == id { recent[i]["text"] = text; recent[i]["payload"] = p }
        return true
    }

    func delete(_ m: JSON) async {
        _ = try? await api.rest("/rest/v1/messages?id=eq.\(str(m["id"]))&from_user=eq.\(me)", method: "DELETE")
        thread.removeAll { str($0["id"]) == str(m["id"]) }
        recent.removeAll { str($0["id"]) == str(m["id"]) }
    }

    static func preview(_ m: JSON, me: String) -> String {
        let mine = str(m["from_user"]) == me, p = dict(m["payload"])
        // a group with nothing said yet; in a group, who said it
        if !str(m["group_id"]).isEmpty && str(m["from_user"]).isEmpty { return str(m["text"]) }
        let who: String = str(m["group_id"]).isEmpty ? "" : (mine ? "You: " : Feed.shared.name(str(m["from_user"])) + ": ")
        let body = switch str(m["kind"]) {
        case "photo": "Sent a photo"
        case "gif": "Sent a GIF"
        case "post": "Sent a post: \(str(p["name"]))"
        case "food": "Sent food: \(str(p["name"]))"
        default: str(m["text"])
        }
        return who.isEmpty ? (mine ? "You: " : "") + body : who + body
    }
}
