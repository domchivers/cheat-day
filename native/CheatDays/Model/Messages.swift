import SwiftUI

/// One-to-one chats between friends: text, a photo, a post or a food (with ＋ to add it), reactions, and "Seen".
@Observable @MainActor
final class Messages {
    static let shared = Messages()

    struct Chat: Identifiable {
        let id: String   // the friend's user id
        var last: JSON
        var unread: Int
    }

    private(set) var recent: [JSON] = []   // my latest messages both ways, newest first
    private(set) var thread: [JSON] = []   // the open chat, oldest first
    private(set) var reactions: [JSON] = []
    private(set) var open: String?
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
            let other = str(m["from_user"]) == me ? str(m["to_user"]) : str(m["from_user"])
            let unread = str(m["to_user"]) == me && str(m["seen_at"]).isEmpty ? 1 : 0
            if var c = seen[other] { c.unread += unread; seen[other] = c } else { seen[other] = Chat(id: other, last: m, unread: unread); order.append(other) }
        }
        return order.compactMap { seen[$0] }
    }
    var unread: Int { chats.filter { $0.unread > 0 }.count }

    func load() async {
        guard !me.isEmpty else { return }
        do {
            recent = try await rows("/rest/v1/messages?select=*&order=created_at.desc&limit=200")
            error = nil
            await Profiles.shared.load(chats.map(\.id))
        } catch { self.error = "Messages need setting up (supabase/profiles_messages.sql)." }
    }

    /// The chat with one friend, marked as seen.
    func openChat(_ friend: String) async {
        open = friend
        await refresh()
    }
    func closeChat() { open = nil; thread = [] }

    func refresh() async {
        guard let f = open, !me.isEmpty else { return }
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

    /// Text, or a photo, GIF, post or food with its details in payload.
    func send(to friend: String, text: String = "", kind: String = "text", payload: JSON = [:]) async {
        let row: JSON = ["from_user": me, "to_user": friend, "kind": kind, "text": text, "payload": payload]
        do {
            let d = try await api.rest("/rest/v1/messages", method: "POST", body: [row], prefer: "return=representation")
            let made = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
            if open == friend { thread += made }
            recent.insert(contentsOf: made, at: 0)
            let preview = kind == "text" ? text : kind == "photo" ? "Sent a photo" : kind == "gif" ? "Sent a GIF" : kind == "post" ? "Sent a post: \(str(payload["name"]))" : kind == "story" ? (str(payload["reaction"]).isEmpty && str(payload["reply"]).isEmpty ? "Sent a story" : text) : "Sent food: \(str(payload["name"]))"
            Task { _ = try? await api.call("/functions/v1/push", body: ["action": "notify", "to": friend, "kind": "message", "text": preview, "post": "chat:\(me)"] as JSON) }
        } catch { self.error = "Couldn't send: messages need setting up, or you're not friends." }
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
        let body = switch str(m["kind"]) {
        case "photo": "Sent a photo"
        case "gif": "Sent a GIF"
        case "post": "Sent a post: \(str(p["name"]))"
        case "food": "Sent food: \(str(p["name"]))"
        default: str(m["text"])
        }
        return (mine ? "You: " : "") + body
    }
}
