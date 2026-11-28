import UIKit

/// Ask chats shared with the team during the test, so the cards that come out wrong can be found and fixed without anyone
/// pasting them in (28 Nov). Only when they've turned on Settings › Assistant › Share my chats: off until then.
/// Each chat is one row in chat_shares (supabase/chat_shares.sql), sent again as it grows; the photos only with Include
/// photos on too, into the private chat-photos bucket. "Looks wrong?" under a card is a row in chat_flags.
@MainActor
enum ChatShare {
    static let onKey = "share.chats", photosKey = "share.chatPhotos"
    static var on: Bool { UserDefaults.standard.bool(forKey: onKey) }
    static var photos: Bool { UserDefaults.standard.bool(forKey: photosKey) }

    /// The reasons on the sheet, and what each is stored as.
    static let reasons: [(id: String, name: String)] = [("too_high", "Too high"), ("too_low", "Too low"), ("wrong_food", "Wrong food"),
                                                         ("missed", "Missed something"), ("odd_reply", "Odd reply")]

    /// A turn's photos once they're up, so a chat sent again doesn't send them again.
    private static var sent: [UUID: [String]] = [:]
    private static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// The chat as it is now, to the team: the text report (what every check did to each card) and the saved record.
    static func send(chatId: String, turns: [Assistant.Turn], record: JSON) {
        guard on, Supabase.shared.userId != nil, !turns.isEmpty else { return }
        Task { await upload(chatId: chatId, turns: turns, record: record) }
    }

    @discardableResult
    private static func upload(chatId: String, turns: [Assistant.Turn], record: JSON) async -> Bool {
        guard let me = Supabase.shared.userId else { return false }
        var shots: [String] = []
        if photos {
            for t in turns where t.me && !t.images.isEmpty {
                if let done = sent[t.id] { shots += done; continue }
                var paths: [String] = []
                for img in t.images {
                    guard let jpg = img.jpegData(compressionQuality: 0.6),
                          let p = try? await Supabase.shared.upload(jpg, ext: "jpg", type: "image/jpeg", bucket: "chat-photos") else { continue }
                    paths.append(p)
                }
                sent[t.id] = paths; shots += paths
            }
        }
        // a record that can't be written as JSON would stop the app, not just this send
        let chat: Any = JSONSerialization.isValidJSONObject(record) ? record : [String: Any]()
        let row: JSON = ["user_id": me, "chat_id": chatId, "app_version": version, "report": Assistant.report(turns),
                         "chat": chat, "photos": shots, "updated_at": ISO.now()]
        return (try? await Supabase.shared.rest("/rest/v1/chat_shares?on_conflict=user_id,chat_id", method: "POST", body: [row], prefer: "resolution=merge-duplicates")) != nil
    }

    /// "Looks wrong?": the chat sent as it is, then the report on that card. False when it couldn't be sent.
    static func flag(chatId: String, turns: [Assistant.Turn], record: JSON, turn: UUID, reason: String, note: String) async -> Bool {
        guard let me = Supabase.shared.userId else { return false }
        guard await upload(chatId: chatId, turns: turns, record: record) else { return false }
        let at = turns.firstIndex { $0.id == turn } ?? -1
        let row: JSON = ["user_id": me, "chat_id": chatId, "turn": at, "reason": reason, "note": note, "app_version": version]
        return (try? await Supabase.shared.rest("/rest/v1/chat_flags", method: "POST", body: [row])) != nil
    }

    /// Everything they've shared, gone: the reports, the chats and the photos. False when some of it couldn't be deleted.
    static func deleteAll() async -> Bool {
        guard let me = Supabase.shared.userId else { return false }
        let api = Supabase.shared
        var ok = (try? await api.rest("/rest/v1/chat_flags?user_id=eq.\(me)", method: "DELETE")) != nil
        ok = (try? await api.rest("/rest/v1/chat_shares?user_id=eq.\(me)", method: "DELETE")) != nil && ok
        // the photos, a page at a time from their own folder
        while true {
            guard let d = try? await api.rest("/storage/v1/object/list/chat-photos", method: "POST", body: ["prefix": me, "limit": 100] as JSON),
                  let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] else { ok = false; break }
            let names = rows.map { str($0["name"]) }.filter { !$0.isEmpty }.map { "\(me)/\($0)" }
            if names.isEmpty { break }
            guard (try? await api.rest("/storage/v1/object/chat-photos", method: "DELETE", body: ["prefixes": names] as JSON)) != nil else { ok = false; break }
        }
        sent = [:]
        return ok
    }
}
