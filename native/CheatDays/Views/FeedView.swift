import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The friends feed: posts, reactions and comments, from the same tables as the website.
/// Time asked of the phone to finish something after the app's been left: held from when this is made until
/// `end()`, or until the phone says time's up.
@MainActor final class KeepAlive {
    private var id = UIBackgroundTaskIdentifier.invalid
    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in Task { @MainActor in self?.end() } }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id); id = .invalid
    }
}

@Observable @MainActor
final class Feed {
    /// What went wrong, to show under the stories; nothing for a load that was only called off (pulling to refresh
    /// again, or leaving the screen, stops the one in hand, and that showed as the word "cancelled").
    static func said(_ error: Error) -> String? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || (error as NSError).code == NSURLErrorCancelled { return nil }
        return error.localizedDescription
    }

    static let shared = Feed()
    static let reacts = ["❤️", "🔥", "😋", "💪", "👏"]   // ❤️ is the heart; the rest are a long press away
    private(set) var posts: [JSON] = []
    private(set) var reactions: [JSON] = []
    private(set) var comments: [JSON] = []
    private(set) var commentLikes: [JSON] = []
    private(set) var names: [String: String] = [:]
    private(set) var loading = false
    var error: String?
    private var api: Supabase { Supabase.shared }
    var me: String { api.userId ?? "" }

    private func rows(_ path: String) async throws -> [JSON] {
        let d = try await api.rest(path)
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            // friends, people I follow, and me: public profiles can be read by anyone now, and those belong in Explore
            if Friends.shared.people.isEmpty { await Friends.shared.load() }
            await Follows.shared.load()
            // real accounts only: the demo's made-up friends ("demo-alex") aren't ids the server can read
            let owners = Set([me] + Friends.shared.people.map(\.id) + Follows.shared.following).filter { UUID(uuidString: $0) != nil }
            guard !owners.isEmpty else { posts = []; return }
            let own: [JSON] = try await rows("/rest/v1/posts?owner=in.(\(owners.joined(separator: ",")))&select=*&order=created_at.desc&limit=40")
            posts = await withReposts(own, from: Array(owners))
            // your badges from before they went in stories: on your story now instead, once (Medal.carryOver)
            if posts.contains(where: { str($0["kind"]) == "moment" && str($0["owner"]) == me }) { Task { await Medal.carryOver() } }
            let ids = posts.map { str($0["id"]) }.joined(separator: ",")
            if !ids.isEmpty {
                async let rx = rows("/rest/v1/reactions?post_id=in.(\(ids))&select=post_id,user_id,emoji")
                async let cm = rows("/rest/v1/comments?post_id=in.(\(ids))&select=*&order=created_at.asc")
                reactions = try await rx; comments = try await cm
                // likes on comments: an empty list until the comment_likes table is set up
                let cids = comments.map { str($0["id"]) }.joined(separator: ",")
                commentLikes = cids.isEmpty ? [] : ((try? await rows("/rest/v1/comment_likes?comment_id=in.(\(cids))&select=comment_id,user_id")) ?? [])
            }
            await loadSaves(posts.map { str($0["id"]) })
            await loadReposts(posts.map { str($0["id"]) })
            let reposters: [String] = repostedBy.values.flatMap(\.who)
            let who = Set(posts.map { str($0["owner"]) } + comments.map { str($0["user_id"]) } + reposters + [me]).filter { !$0.isEmpty }
            await Profiles.shared.load(Array(who))
            if !who.isEmpty {
                for p in try await rows("/rest/v1/profiles?user_id=in.(\(who.joined(separator: ",")))&select=user_id,display_name") {
                    names[str(p["user_id"])] = str(p["display_name"])
                }
            }
        } catch { self.error = Feed.said(error) }
    }

    // MARK: saved posts (a bookmark, kept for yourself; supabase/post_saves.sql)

    /// The posts I've saved, and how many people have saved each post that's been looked up. Empty, and the
    /// bookmark does nothing but say so, until the table's set up.
    private(set) var saved: Set<String> = []
    private(set) var saveCounts: [String: Int] = [:]

    /// Which of mine, and the counts for these posts.
    func loadSaves(_ ids: [String]) async {
        let real = ids.filter { UUID(uuidString: $0) != nil }
        if let mine = try? await rows("/rest/v1/post_saves?user_id=eq.\(me)&select=post_id") { saved = Set(mine.map { str($0["post_id"]) }) }
        guard !real.isEmpty, let d = try? await api.rest("/rest/v1/rpc/post_save_counts", method: "POST", body: ["ids": real] as JSON),
              let got = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] else { return }
        for id in real { saveCounts[id] = nil }
        for r in got { saveCounts[str(r["post_id"])] = Int(num(r["n"]) ?? 0) }
    }

    /// Save a post, or take it out again. Shown at once, and put back if the server says no.
    func toggleSave(_ post: JSON) async {
        let id = str(post["id"]), was = saved.contains(id)
        if was { saved.remove(id) } else { saved.insert(id) }
        saveCounts[id] = max(0, (saveCounts[id] ?? 0) + (was ? -1 : 1))
        do {
            if was { _ = try await api.rest("/rest/v1/post_saves?post_id=eq.\(id)&user_id=eq.\(me)", method: "DELETE") }
            else { _ = try await api.rest("/rest/v1/post_saves", method: "POST", body: [["post_id": id, "user_id": me]], prefer: "resolution=ignore-duplicates") }
        } catch {
            if was { saved.insert(id) } else { saved.remove(id) }
            saveCounts[id] = max(0, (saveCounts[id] ?? 0) + (was ? 1 : -1))
            self.error = "Saving posts isn't set up yet."
        }
    }

    /// The posts I've saved, the latest saved first.
    func savedPosts() async -> [JSON] {
        guard let mine = try? await rows("/rest/v1/post_saves?user_id=eq.\(me)&select=post_id,created_at&order=created_at.desc&limit=90") else { return [] }
        let ids = mine.map { str($0["post_id"]) }
        saved = Set(ids)
        guard !ids.isEmpty, let got = try? await rows("/rest/v1/posts?id=in.(\(ids.joined(separator: ",")))&select=*") else { return [] }
        return ids.compactMap { id in got.first { str($0["id"]) == id } }
    }

    // MARK: reposts (23 Nov, design/repost-mockup.html; supabase/post_reposts.sql)

    /// The posts I've reposted, and how many people have reposted each post looked up. Empty, and the button says
    /// so, until the table's set up.
    private(set) var reposted: Set<String> = []
    private(set) var repostCounts: [String: Int] = [:]

    /// Who brought a post into the feed by reposting it (friends and people I follow, newest first), by post id.
    struct RepostNote: Equatable { var who: [String]; var at: String }
    private(set) var repostedBy: [String: RepostNote] = [:]

    /// A post that can be reposted: someone else's, from a public account, and not a badge moment (as with
    /// putting a post on your story; private accounts' posts stay with the people they chose).
    static func canRepost(_ p: JSON) -> Bool {
        let owner = str(p["owner"])
        guard owner != shared.me, str(p["kind"]) != "moment" else { return false }
        return Profiles.shared.all[owner].map { !$0.isPrivate } == true
    }

    func loadReposts(_ ids: [String]) async {
        let real = ids.filter { UUID(uuidString: $0) != nil }
        if let mine = try? await rows("/rest/v1/post_reposts?user_id=eq.\(me)&select=post_id") { reposted = Set(mine.map { str($0["post_id"]) }) }
        guard !real.isEmpty, let d = try? await api.rest("/rest/v1/rpc/post_repost_counts", method: "POST", body: ["ids": real] as JSON),
              let got = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] else { return }
        for id in real { repostCounts[id] = nil }
        for r in got { repostCounts[str(r["post_id"])] = Int(num(r["n"]) ?? 0) }
    }

    /// Repost a post, or take the repost back. Shown at once, put back if the server says no; its poster hears.
    func toggleRepost(_ post: JSON) async {
        let id = str(post["id"]), was = reposted.contains(id)
        if was { reposted.remove(id) } else { reposted.insert(id) }
        repostCounts[id] = max(0, (repostCounts[id] ?? 0) + (was ? -1 : 1))
        do {
            if was { _ = try await api.rest("/rest/v1/post_reposts?post_id=eq.\(id)&user_id=eq.\(me)", method: "DELETE") }
            else {
                _ = try await api.rest("/rest/v1/post_reposts", method: "POST", body: [["post_id": id, "user_id": me]], prefer: "resolution=ignore-duplicates")
                notify(str(post["owner"]), kind: "repost", text: str(post["name"]), extra: ["post": id])
            }
        } catch {
            if was { reposted.insert(id) } else { reposted.remove(id) }
            repostCounts[id] = max(0, (repostCounts[id] ?? 0) + (was ? 1 : -1))
            self.error = "Reposting isn't set up yet."
        }
    }

    /// The posts someone's reposted, the latest first (their profile's Reposts tab).
    func repostsOf(_ user: String) async -> [JSON] {
        guard UUID(uuidString: user) != nil,
              let theirs = try? await rows("/rest/v1/post_reposts?user_id=eq.\(user)&select=post_id,created_at&order=created_at.desc&limit=90") else { return [] }
        let ids = theirs.map { str($0["post_id"]) }
        guard !ids.isEmpty, let got = try? await rows("/rest/v1/posts?id=in.(\(ids.joined(separator: ",")))&select=*") else { return [] }
        return ids.compactMap { id in got.first { str($0["id"]) == id } }
    }

    /// Friends' and followed people's reposts put into the feed: a post reposted that isn't already here comes in
    /// at the time it was reposted, once however many reposted it ("Mark and 2 others reposted").
    private func withReposts(_ own: [JSON], from people: [String]) async -> [JSON] {
        let others = people.filter { $0 != me && !Profiles.shared.muted.contains($0) && !Follows.shared.blocked.contains($0) }
        guard !others.isEmpty,
              let rp = try? await rows("/rest/v1/post_reposts?user_id=in.(\(others.joined(separator: ",")))&select=post_id,user_id,created_at&order=created_at.desc&limit=40"),
              !rp.isEmpty else { repostedBy = [:]; return own }
        var notes: [String: RepostNote] = [:]
        for r in rp {
            let pid = str(r["post_id"]), who = str(r["user_id"])
            var n: RepostNote = notes[pid] ?? RepostNote(who: [], at: str(r["created_at"]))
            if !n.who.contains(who) { n.who.append(who) }
            notes[pid] = n
        }
        repostedBy = notes
        let have = Set(own.map { str($0["id"]) })
        let missing = notes.keys.filter { !have.contains($0) }
        var extra: [JSON] = []
        if !missing.isEmpty, let got = try? await rows("/rest/v1/posts?id=in.(\(missing.joined(separator: ",")))&select=*") { extra = got }
        func when(_ p: JSON) -> String {
            let id = str(p["id"])
            return have.contains(id) ? str(p["created_at"]) : (notes[id]?.at ?? str(p["created_at"]))
        }
        return (own + extra).sorted { when($0) > when($1) }
    }

    /// Reactions and comments for posts that aren't in the feed (Explore's), added to what's here.
    func loadExtras(_ more: [JSON]) async {
        Task { await loadSaves(more.map { str($0["id"]) }) }
        Task { await loadReposts(more.map { str($0["id"]) }) }
        let ids = more.map { str($0["id"]) }.filter { id in !posts.contains { str($0["id"]) == id } }
        guard !ids.isEmpty else { return }
        let list = ids.joined(separator: ",")
        let rx = (try? await rows("/rest/v1/reactions?post_id=in.(\(list))&select=post_id,user_id,emoji")) ?? []
        let cm = (try? await rows("/rest/v1/comments?post_id=in.(\(list))&select=*&order=created_at.asc")) ?? []
        let have = Set(ids)
        reactions.removeAll { have.contains(str($0["post_id"])) }; reactions += rx
        comments.removeAll { have.contains(str($0["post_id"])) }; comments += cm
        await Profiles.shared.load(cm.map { str($0["user_id"]) })
    }

    /// A post with a picture: an address, or (posts from the website) the picture kept in the row as data:image.
    /// The profile grid only knew addresses, so the ramen showed as an icon there and as a photo on the feed.
    /// A video post's clip (its photo is the first frame, for grids and while it loads).
    static func video(_ p: JSON) -> URL? {
        let v = str(dict(p["extra"])["video"])
        return v.hasPrefix("http") ? URL(string: v) : nil
    }

    static func hasPhoto(_ p: JSON) -> Bool { let s = str(p["photo"]); return s.hasPrefix("http") || s.hasPrefix("data:image") }

    func name(_ id: String) -> String {
        id == me ? "You" : ((names[id] ?? Profiles.shared.all[id]?.name ?? Friends.shared.people.first { $0.id == id }?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Someone")
    }

    /// The last like or unlike sent for each post and emoji: the next one waits for it, so quick taps reach the server in order.
    @ObservationIgnored private var reacting: [String: Task<Void, Never>] = [:]

    /// A like, on or off. It shows at once and is sent after (18 Nov): the heart waited for the server before, so each
    /// tap lagged by a round trip. If the server says no, it goes back as it was.
    func toggle(_ post: JSON, _ emoji: String) async {
        let id = str(post["id"]), key = id + "|" + emoji
        func isMine(_ r: JSON) -> Bool { str(r["post_id"]) == id && str(r["user_id"]) == me && str(r["emoji"]) == emoji }
        let mine = reactions.contains(where: isMine)
        if mine { reactions.removeAll(where: isMine) } else { reactions.append(["post_id": id, "user_id": me, "emoji": emoji]) }
        let before = reacting[key]
        let send = Task { @MainActor in
            await before?.value
            do {
                if mine {
                    let e = emoji.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? emoji
                    _ = try await api.rest("/rest/v1/reactions?post_id=eq.\(id)&user_id=eq.\(me)&emoji=eq.\(e)", method: "DELETE")
                } else {
                    _ = try await api.rest("/rest/v1/reactions", method: "POST", body: [["post_id": post["id"] ?? id, "user_id": me, "emoji": emoji]], prefer: "resolution=ignore-duplicates")
                    notify(str(post["owner"]), kind: "react", text: str(post["name"]), extra: ["emoji": emoji, "post": id])
                    Store.shared.perform(["type": "bump", "key": "reactCount"], syncAfter: 3)
                }
            } catch {
                // back as it was
                if mine { if !reactions.contains(where: isMine) { reactions.append(["post_id": id, "user_id": me, "emoji": emoji]) } }
                else { reactions.removeAll(where: isMine) }
                self.error = Feed.said(error)
            }
        }
        reacting[key] = send
        await send.value
    }

    /// A comment, or a reply to one (which its writer hears about too).
    func comment(_ post: JSON, _ text: String, replyTo: JSON? = nil) async {
        do {
            var row: JSON = ["post_id": post["id"] ?? "", "user_id": me, "text": text]
            if let r = replyTo { row["reply_to"] = r["id"] ?? NSNull() }
            let d = try await api.rest("/rest/v1/comments", method: "POST", body: [row], prefer: "return=representation")
            let made = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
            comments += made
            if let c = made.first { Moderation.shared.screen(kind: "comment", target: str(c["id"]), text: text) }
            notify(str(post["owner"]), kind: "comment", text: text, extra: ["post": str(post["id"])])
            if let r = replyTo, str(r["user_id"]) != str(post["owner"]) { notify(str(r["user_id"]), kind: "reply", text: text, extra: ["post": str(post["id"])]) }
            for who in Tagging.people(in: text) where who != me { await Messages.shared.send(to: who, text: "Mentioned you in a comment: " + String(text.prefix(140))) }
            Store.shared.perform(["type": "bump", "key": "commentCount"], syncAfter: 3)
        } catch { self.error = Feed.said(error) }
    }

    func likeComment(_ c: JSON) async {
        let cid = str(c["id"]), mine = commentLikes.contains { str($0["comment_id"]) == cid && str($0["user_id"]) == me }
        do {
            if mine {
                _ = try await api.rest("/rest/v1/comment_likes?comment_id=eq.\(cid)&user_id=eq.\(me)", method: "DELETE")
                commentLikes.removeAll { str($0["comment_id"]) == cid && str($0["user_id"]) == me }
            } else {
                _ = try await api.rest("/rest/v1/comment_likes", method: "POST", body: [["comment_id": cid, "user_id": me]], prefer: "resolution=ignore-duplicates")
                commentLikes.append(["comment_id": cid, "user_id": me])
            }
        } catch { self.error = "Comment likes aren't set up yet." }
    }

    /// Send a post to one friend: it's in their Activity, and they hear about it.
    func share(_ post: JSON, to friend: String, note: String) async {
        do {
            _ = try await api.rest("/rest/v1/post_shares", method: "POST", body: [["post_id": post["id"] ?? "", "from_user": me, "to_user": friend, "note": note]])
            // and in your chat with them, which is where they hear about it
            await Messages.shared.send(to: friend, kind: "post", payload: ["name": post["name"] ?? "", "kcal": post["kcal"] ?? 0, "photo": post["photo"] ?? "", "macros": post["macros"] ?? [:] as JSON, "post": post])
            if !note.isEmpty { await Messages.shared.send(to: friend, text: note) }
        } catch { self.error = "Sending posts isn't set up yet." }
    }

    func deleteComment(_ c: JSON) async {
        do { _ = try await api.rest("/rest/v1/comments?id=eq.\(str(c["id"]))&user_id=eq.\(me)", method: "DELETE"); comments.removeAll { str($0["id"]) == str(c["id"]) } }
        catch { self.error = Feed.said(error) }
    }

    /// Captions changed since a copy of the post was fetched (a profile keeps its own list), by post id.
    private(set) var edited: [String: String] = [:]
    func caption(_ post: JSON) -> String { edited[str(post["id"])] ?? str(post["caption"]) }

    /// Your own post's caption, changed. False when the server didn't take it.
    func edit(_ post: JSON, caption: String) async -> Bool {
        let id = str(post["id"])
        guard let d = try? await api.rest("/rest/v1/posts?id=eq.\(id)&owner=eq.\(me)", method: "PATCH", body: ["caption": caption] as JSON, prefer: "return=representation"),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON], !rows.isEmpty else { return false }
        edited[id] = caption
        for i in posts.indices where str(posts[i]["id"]) == id { posts[i]["caption"] = caption }
        return true
    }

    /// Posts of yours changed this session, as the server gave them back: a list with its own copy of one (a
    /// profile) swaps it in at once, before it fetches anything.
    private(set) var changed: [String: JSON] = [:]

    /// Goes up each time a post of yours is changed, for a list with its own copy of it to fetch it again.
    private(set) var revision = 0

    /// Your own post, changed: whichever of its fields are given. False when the server didn't take it.
    func update(_ post: JSON, change: JSON) async -> Bool {
        let id = str(post["id"])
        guard let d = try? await api.rest("/rest/v1/posts?id=eq.\(id)&owner=eq.\(me)", method: "PATCH", body: change, prefer: "return=representation"),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON], let row = rows.first else { return false }
        if let c = change["caption"] as? String { edited[id] = c }
        for i in posts.indices where str(posts[i]["id"]) == id { for (k, v) in row { posts[i][k] = v } }
        changed[id] = row
        revision += 1
        return true
    }

    /// A post on its way up: the sheet closes at once and this says how it's going (on the feed and your profile).
    struct Sending { var thumb: UIImage?; var state: State; var again: (() -> Void)?
        enum State: Equatable { case working, done, failed(String) } }
    private(set) var sending: Sending?

    /// Post in the background. Done shows for a moment; a failure stays, with Try again.
    func send(_ row: JSON, photo: UIImage?, video: URL?, filter: String, range: ClosedRange<Double>?, muted: Bool, crop: CGRect? = nil, overlay: UIImage? = nil, more: [UIImage] = [], turns: Int = 0, placed: ClipEdit? = nil, sent: @escaping () -> Void = {}) {
        let again: () -> Void = { [weak self] in self?.send(row, photo: photo, video: video, filter: filter, range: range, muted: muted, crop: crop, overlay: overlay, more: more, turns: turns, placed: placed, sent: sent) }
        withAnimation(.snappy) { sending = Sending(thumb: photo, state: .working, again: again) }
        // Leaving the app doesn't stop it: the phone is asked for time to finish (it gives about half a minute, enough
        // for most posts; a long video on a slow line can still be cut off, and then says so with Try again).
        let keep = KeepAlive("Posting")
        Task {
            defer { keep.end() }
            do {
                try await post(row, photo: photo, video: video, filter: filter, range: range, muted: muted, crop: crop, overlay: overlay, more: more, turns: turns, placed: placed)
                withAnimation(.snappy) { sending?.state = .done }
                sent()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await Task.sleep(for: .seconds(2.5))
                if sending?.state == .done { withAnimation(.snappy) { sending = nil } }
            } catch {
                withAnimation(.snappy) { sending?.state = .failed(error.localizedDescription) }
            }
        }
    }
    func clearSending() { withAnimation(.snappy) { sending = nil } }

    /// Posts deleted this session: gone at once from every list showing them (a profile keeps its own copy), not
    /// when the server has answered.
    private(set) var removed: Set<String> = []

    func delete(_ post: JSON) async {
        let id = str(post["id"]), before = posts
        withAnimation(.snappy) { removed.insert(id); posts.removeAll { str($0["id"]) == id } }
        do { _ = try await api.rest("/rest/v1/posts?id=eq.\(id)&owner=eq.\(me)", method: "DELETE") }
        catch {
            // it didn't go: back where it was, with why
            withAnimation(.snappy) { removed.remove(id); posts = before }
            self.error = "Couldn't delete that post: \(error.localizedDescription)"
        }
    }

    func post(_ row: JSON, photo: UIImage?, video: URL? = nil, filter: String = "Normal", range: ClosedRange<Double>? = nil, muted: Bool = false, crop: CGRect? = nil, overlay: UIImage? = nil, more: [UIImage] = [], turns: Int = 0, placed: ClipEdit? = nil) async throws {
        var r = row
        r["owner"] = me
        // The AI's look first (see Moderation): refused, it isn't posted and says why; unsure, it goes up and a person
        // is asked to look. A moment (a streak, a badge) is the app's own words.
        let words = [str(r["name"]), str(r["caption"])].filter { !$0.isEmpty }.joined(separator: "\n")
        var unsure = false
        if str(r["kind"]) != "moment" { unsure = try await Moderation.shared.gate(kind: "post", text: words, images: (photo.map { [$0] } ?? []) + more) }
        // a video: up to Stories.longest as mp4 into the same bucket as stories' videos; its first frame is the photo
        if let video {
            var x = dict(r["extra"])
            // with a song: the song into the video's own sound, one file (see SongMix). If that can't be done it goes
            // up as before, the song played beside it.
            var made: Data?
            if let song = Music.of(r), let mix = await SongMix.make(song, song: Music.mix(r).song, clip: Music.mix(r).clip) {
                made = try? await Stories.compress(video, filter: filter, range: range, muted: muted, crop: crop, overlay: overlay, turns: turns, placed: placed, mix: mix).0
                mix.done()
                if made != nil {
                    x["mixed"] = true
                    if !muted, let own = await Stories.soundOnly(video, range: range), let at = try? await api.upload(own, ext: "m4a", type: "video/mp4") { x["sound"] = at }
                }
            }
            let mp4: Data
            if let made { mp4 = made } else {
                mp4 = try await Stories.compress(video, filter: filter, range: range, muted: muted, crop: crop, overlay: overlay, turns: turns, placed: placed).0
            }
            x["video"] = try await api.upload(mp4, ext: "mp4", type: "video/mp4"); r["extra"] = x
        }
        if let photo, let jpeg = Self.prepare(photo) {
            r["photo"] = (try? await api.uploadPhoto(jpeg)) ?? NSNull()
            if let at = r["photo"] as? String { ImageStore.keep(photo, as: at); ImageStore.keepMaster(photo, as: at) }
        }
        // several photos: the first is the post's own, and all of them, in order, are listed beside it
        if !more.isEmpty, let first = r["photo"] as? String {
            var all = [first]
            for img in more {
                guard let jpeg = Self.prepare(img) else { continue }
                let at = try await api.uploadPhoto(jpeg)
                ImageStore.keepMaster(img, as: at)
                all.append(at)
            }
            var x = dict(r["extra"]); x["photos"] = all; r["extra"] = x
        }
        // a workout that's already on the feed (posted when it finished): add the photo and caption to that post instead
        if str(r["kind"]) == "workout", let existing = await sameWorkout(str(r["name"])) {
            var change: JSON = [:]
            if let ph = r["photo"], !(ph is NSNull) { change["photo"] = ph }
            if !str(r["caption"]).isEmpty { change["caption"] = r["caption"] }
            // the photo's workout sticker, to tap, and its shape, with what the post had already
            let add = dict(r["extra"])
            if add["live"] != nil || add["aspect"] != nil {
                var x = dict(existing["extra"])
                for k in ["live", "aspect"] { if let v = add[k] { x[k] = v } }
                change["extra"] = x
            }
            if !change.isEmpty { _ = try await api.rest("/rest/v1/posts?id=eq.\(str(existing["id"]))&owner=eq.\(me)", method: "PATCH", body: change) }
            await load()
            return
        }
        let made = try await api.rest("/rest/v1/posts", method: "POST", body: [r], prefer: "return=representation")
        if unsure, let id = ((try? JSONSerialization.jsonObject(with: made)) as? [JSON])?.first.map({ str($0["id"]) }) {
            await Moderation.shared.flag(kind: "post", target: id, text: words, media: str(r["photo"]), video: video != nil)
        }
        for who in Tagging.people(in: str(r["caption"])) where who != me { await Messages.shared.send(to: who, text: "Mentioned you in a post") }
        Store.shared.perform(["type": "bump", "key": "postCount"], syncAfter: 2)
        await load()
    }

    /// My workout post with this name from the last day, if there is one.
    private func sameWorkout(_ name: String) async -> JSON? {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))
        let n = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return try? await rows("/rest/v1/posts?owner=eq.\(me)&kind=eq.workout&name=eq.\(n)&created_at=gte.\(since)&select=id&order=created_at.desc&limit=1").first
    }

    /// A friend hears about it (the website's notifyFriend), if push is set up.
    private func notify(_ to: String, kind: String, text: String, extra: JSON = [:]) {
        guard !to.isEmpty, to != me else { return }
        var body: JSON = ["action": "notify", "to": to, "kind": kind, "text": text]
        body.merge(extra) { _, n in n }
        Task { _ = try? await api.call("/functions/v1/push", body: body) }
    }

    /// A post photo as edited: at most 1080 px wide, its own shape, about 250 KB. (At 0.75 it was about 150 KB and
    /// fine detail was already soft; edited and saved a second time at that, it showed.)
    static func prepare(_ img: UIImage) -> Data? {
        // in dots, not points (see PhotoEditor.shrink): 1,080 wide at most
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        return PhotoEditor.shrink(img, to: max(w, h) * min(1, 1080 / max(1, w))).jpegData(compressionQuality: 0.85)
    }

    /// Feed photos: a 640 px square, about 40 KB, like the website's thumbFromBig.
    static func square(_ img: UIImage) -> Data? {
        let side = min(img.size.width, img.size.height), size = CGSize(width: 640, height: 640)
        let crop = CGRect(x: (img.size.width - side) / 2, y: (img.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1   // 640 pixels, not 640 points at the screen's 3x
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            img.draw(in: CGRect(x: -crop.minX * 640 / side, y: -crop.minY * 640 / side, width: img.size.width * 640 / side, height: img.size.height * 640 / side))
        }
        return out.jpegData(compressionQuality: 0.72)
    }

    static func ago(_ iso: String) -> String {
        guard let d = ISO.date(iso) else { return "" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }; if s < 3600 { return "\(Int(s / 60)) min ago" }; if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86400); return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

/// The feed, as social apps do it now: friends' days as rings along the top, posts edge to edge with the numbers on
/// the photo, one heart (double-tap the photo; hold the heart for the rest), comments in their own sheet, and moments
/// (a streak, a badge, a rank up) that friends can cheer.
struct FeedView: View {
    /// A friend's ring tapped: their day, on People.
    var showPerson: (String) -> Void = { _ in }
    /// Just these posts (Explore's, from the one tapped on), without the rings or the +.
    var only: [JSON]? = nil
    /// The post to open on, from a profile's grid.
    var startAt: String? = nil
    @State private var recipe: JSON?
    @State private var flash: String?
    @State private var talking: PostBox?   // the post whose comments are open
    @State private var songOf: PostBox?   // the post whose song's card is open (its song line, under the name)
    @State private var sharing: PostBox?
    @State private var rewording: PostBox?   // your post whose caption is being changed
    @State private var reels: ReelStart?   // a video opened full screen
    @State private var picking: String?   // the post whose reactions are showing
    @State private var burst: String?   // the post a double-tap just liked
    @State private var deleting: PostBox?   // a post of yours, about to be deleted: asked first
    @State private var zoomed: String?   // the post whose picture two fingers have pinched bigger
    @State private var profileOf: String?
    @State private var taggedIn: TagBox?   // who is tagged in a post, from the person in its corner
    @State private var tagOf: String?   // a hashtag tapped in a caption: its posts open
    @State private var reportOf: ReportTarget?
    @State private var story: StoryStart?
    @State private var profileAfterStory: String?   // a name tapped in a story: their page opens once the story has closed
    @State private var posting = false   // making a story
    @State private var makingEdit = false   // Make an edit (EditFlow), from Your story
    @State private var askMine = false
    struct StoryStart: Identifiable { let id = UUID(); let people: [String]; let at: Int }
    private var feed: Feed { Feed.shared }
    private var friends: Friends { Friends.shared }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                if only == nil { ModerationNotices() }
                if only == nil { rings }
                if only == nil { PostingBanner().padding(.horizontal, 14).padding(.bottom, 8) }
                if let e = feed.error { Text(e).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 16).padding(.bottom, 8) }
                if only == nil && feed.posts.isEmpty && !feed.loading {
                    Text("Nothing in the feed yet. Share something, or add a friend.").foregroundStyle(.secondary).padding(.top, 40)
                }
                // badges and rank-ups go in stories now (17 Nov), so ones posted before don't show here
                ForEach(keyed((only ?? feed.posts).filter { str($0["kind"]) != "moment" && !feed.removed.contains(str($0["id"])) && !Profiles.shared.muted.contains(str($0["owner"])) && !Follows.shared.blocked.contains(str($0["owner"])) })) { entry in   // by post id: deleting one can't leave a row past the end
                    let pid = str(entry.item["id"])
                    postView(entry.item).id(pid)
                        .onAppear { Feed.warmAhead(pid, in: only ?? feed.posts) }   // its video and song, and the next two posts', fetched ahead
                        .zIndex(zoomed == pid ? 5 : 0)   // its picture, pinched bigger, goes over the posts around it
                        .background { if flash == pid { Theme.accent.opacity(0.12).allowsHitTesting(false) } }
                }
            }
            .padding(.bottom, 120)
        }
        .scrollDisabled(zoomed != nil)   // the list keeps still while a picture's being pinched
        // the made-up feed's scroll view named on itself, for the scrolling test (21 Nov: named only from outside, on
        // the whole FeedView, the name stopped reaching it in 1.4.9; why isn't known). A name for tests, never read out.
        .accessibilityIdentifier(only != nil ? "feedHarness" : "feed")
        .scrollIndicators(.hidden)
        .task(id: Nav.shared.focusPost) { await focus(proxy) }
        .task { if let startAt { try? await Task.sleep(for: .milliseconds(80)); proxy.scrollTo(startAt, anchor: .top) } }
        .onChange(of: feed.posts.count) { _, _ in Task { await focus(proxy) } }
        }
        .refreshable { if only == nil { await feed.load(); await Stories.shared.load() } }
        .task { if only == nil && feed.posts.isEmpty { await feed.load() } }
        .overlay(alignment: .top) { if only == nil && feed.loading && feed.posts.isEmpty { Skeleton.posts().padding(.top, 120).allowsHitTesting(false) } }
        // no floating + here (17 Nov): it didn't match the Food page's and a post is made from your profile's + or a workout
        .sheet(item: Binding(get: { recipe.map { PostBox(post: $0) } }, set: { recipe = $0?.post })) { b in PostRecipeSheet(post: b.post) }
        .sheet(item: $talking) { b in CommentsSheet(post: b.post) }
        .sheet(item: $songOf) { b in
            if let s = Music.of(b.post) {
                let key = "post:" + str(b.post["id"])
                SongCard(song: s, muted: Binding(get: { SongPlayer.shared.playing != key },
                                                 set: { _ in SongPlayer.shared.flip(s, key: key, volume: Music.mix(b.post).song, inVideo: Music.mixed(b.post)) }))
            }
        }
        .sheet(item: $sharing) { b in SharePostSheet(post: b.post).presentationDetents([.medium, .large]) }
        // deleting asks first: it was one tap in a menu, next to Edit, and there's no getting a post back
        .alert("Delete this post?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { b in
            Button("Delete", role: .destructive) { Task { await feed.delete(b.post) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("It will be gone for good, along with its likes and comments.") }
        .sheet(item: $rewording) { b in EditPostSheet(post: b.post) }
        .fullScreenCover(item: $reels) { r in ReelsView(posts: only ?? feed.posts, startAt: r.id) }
        .navigationDestination(item: $profileOf) { id in ProfileView(id: id) }
        .sheet(item: $taggedIn) { b in TaggedSheet(ids: b.ids) { id in profileOf = id } }
        .navigationDestination(item: $tagOf) { t in HashtagView(tag: t) }
        .reportDialog($reportOf)
        .fullScreenCover(item: $story, onDismiss: { if let p = profileAfterStory { profileAfterStory = nil; profileOf = p } }) { s in
            StoryView(people: s.people, at: s.at, onProfile: { profileAfterStory = $0 })
        }
        .fullScreenCover(isPresented: $posting) { StoryComposer() }
        .fullScreenCover(isPresented: $makingEdit) { EditFlow() }
        .task { if only == nil { await Stories.shared.load() } }
        .task { if only == nil { await Moderation.shared.load() } }
    }

    // MARK: friends' days along the top

    private var rings: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                // only friends with something today, the ones you haven't watched first
                let withStory = friends.people.filter { StoryView.has($0.id) }
                let order = withStory.filter { !StoryView.seen($0.id) } + withStory.filter { StoryView.seen($0.id) }
                // people you follow (not friends) who've posted a story: their snaps only, never their day
                let followed = Follows.shared.following.filter { f in !friends.people.contains { $0.id == f } && !Stories.shared.of(f).isEmpty }
                // one run of stories, in the order the rings are in: watching goes on from friends into the people you
                // follow (they were two separate runs, so it stopped at the last friend)
                let run = order.map(\.id) + followed
                // yours: your day as friends see it, or a new post when there's nothing yet
                let mine = StoryView.has(feed.me)
                Button { if mine { askMine = true } else { posting = true } } label: {
                    ring(feed.me, "Your story", new: mine && !Stories.shared.of(feed.me).isEmpty && !StoryView.seen(feed.me), tag: nil, plus: true)
                }
                .buttonStyle(.plain)
                .confirmationDialog("Your story", isPresented: $askMine) {
                    Button("Add to your story") { posting = true }
                    Button("Make an edit") { makingEdit = true }
                    // and on into everyone else's, as the rings go (it stopped at the end of yours, 17 Nov)
                    Button("View your story") { openStory { story = StoryStart(people: [feed.me] + run, at: 0) } }
                }
                ForEach(order.indices, id: \.self) { i in
                    let p = order[i]
                    Button { openStory { story = StoryStart(people: run, at: i) } } label: {
                        ring(p.id, p.name, new: !StoryView.seen(p.id), tag: p.streak > 1 ? "\(p.streak)" : nil, plus: false)
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(p.name)'s story")
                }
                ForEach(followed.indices, id: \.self) { i in
                    let f = followed[i]
                    Button { openStory { story = StoryStart(people: run, at: order.count + i) } } label: { ring(f, Feed.shared.name(f), new: Stories.shared.unwatched(f), tag: nil, plus: false) }
                        .buttonStyle(.plain).accessibilityLabel("\(Feed.shared.name(f))'s story")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private static let rim = [Color(red: 0.84, green: 0.92, blue: 1), Color(red: 0.56, green: 0.77, blue: 1), Color(red: 0.77, green: 0.63, blue: 1)]

    private func ring(_ who: String, _ name: String, new: Bool, tag: String?, plus: Bool) -> some View {
        VStack(spacing: 10) {
            ZStack {
                // the badge coins' rim: something logged today
                Circle().fill(new ? AnyShapeStyle(AngularGradient(colors: Self.rim + [Self.rim[0]], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
                                  : AnyShapeStyle(Color(.tertiarySystemFill)))
                // between the old 62 and Instagram's 86 (17 Nov: 86 felt a little big); the streak grows with it, the + and names don't
                Circle().fill(Theme.hero).padding(3.75)
                Avatar(id: who, size: 64)
            }
            .frame(width: 74, height: 74)
            .overlay(alignment: .bottomTrailing) {
                if plus {
                    Image(systemName: "plus").font(.system(size: 11, weight: .black)).foregroundStyle(Theme.onAccent)
                        .frame(width: 21, height: 21).background(Theme.accent, in: Circle()).overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                }
            }
            .overlay(alignment: .bottom) {
                if !plus, let tag {
                    // centred on the ring's bottom, no pill or outline: the flame and the number, with a dark glow so it reads over the ring
                    HStack(spacing: 1) { FluentIcon(emoji: "🔥", size: 15); Text(tag).font(.system(size: 14, weight: .black)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.36)) }
                        .shadow(color: Theme.bg, radius: 1.5).shadow(color: Theme.bg, radius: 3).shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                        // its middle on the ring's line (6 at the old 62 pt ring, scaled)
                        .offset(y: 7)
                        .accessibilityLabel("\(tag) day streak")
                }
            }
            Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 78)
        }
    }

    /// Scroll to the post a notification or Activity row pointed at (loading the feed first if it isn't there yet).
    private func focus(_ proxy: ScrollViewProxy) async {
        guard let id = Nav.shared.focusPost else { return }
        if !feed.posts.contains(where: { str($0["id"]) == id }) {
            if feed.loading { return }   // the count change brings us back
            await feed.load()
            guard feed.posts.contains(where: { str($0["id"]) == id }) else { Nav.shared.focusPost = nil; return }
        }
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
        Nav.shared.focusPost = nil
        flash = id
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.easeOut) { if flash == id { flash = nil } }
    }

    // MARK: a post

    private func postView(_ p: JSON) -> some View {
        let id = str(p["id"]), owner = str(p["owner"]), kind = str(p["kind"])
        let rx = feed.reactions.filter { str($0["post_id"]) == id }, cm = feed.comments.filter { str($0["post_id"]) == id }
        let photo = Feed.hasPhoto(p)
        return VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.4)
            // brought here by a repost: who, over the post (it stays its poster's, named under it as ever)
            if let note = feed.repostedBy[id], let first = note.who.first {
                repostLine(first, others: note.who.count - 1)
            }
            HStack(spacing: 10) {
                // their photo and name open their profile; the song at the end of the line plays it (a tap, not a
                // button around it all, so the song can be pressed on its own)
                HStack(spacing: 10) {
                    avatar(owner, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        if let h = Profiles.shared.all[owner]?.shownHonor, h.onFeed {
                            Text(feed.name(owner)).font(.subheadline.weight(.bold)).foregroundStyle(h.shade)
                        } else {
                            Text(feed.name(owner)).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                        }
                        // one line: what, when and who with (it took two, with room to spare); the song on its own
                        // line under it, as on stories and Instagram (19 Nov: it was squeezed onto the end of this one)
                        let with = (dict(p["extra"])["tags"] as? [String]).flatMap { $0.isEmpty ? nil : " · with " + TagPicker.names($0) } ?? ""
                        Text(Self.what(p) + " · " + Feed.ago(str(p["created_at"])) + with).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let s = Music.of(p) { songTag(s, post: p) }
                    }
                }
                .contentShape(Rectangle()).onTapGesture { profileOf = owner }
                .accessibilityAddTraits(.isButton)
                Spacer()
                // someone from Explore: follow them from here
                if owner != feed.me, !friends.people.contains(where: { $0.id == owner }) {
                    let st = Follows.shared.state(owner)
                    if st != .following {
                        Button(st == .requested ? "Requested" : "Follow") { Task { if st == .none { await Follows.shared.follow(owner) } else { await Follows.shared.unfollow(owner) } } }
                            .font(.caption.weight(.heavy)).buttonStyle(.borderedProminent).controlSize(.small)
                            .tint(st == .none ? Theme.accent : Color(.tertiarySystemFill)).foregroundStyle(st == .none ? Theme.onAccent : .primary)
                    }
                }
                Menu {
                    Button { sharing = PostBox(post: p) } label: { Label("Send to a friend", systemImage: "paperplane") }
                    if owner != feed.me {
                        Button { Profiles.shared.toggleMute(owner) } label: { Label("Hide posts from \(feed.name(owner))", systemImage: "eye.slash") }
                        Button { reportOf = ReportTarget(user: owner, what: "Post: \(str(p["id"]))", kind: "post", target: str(p["id"]),
                                                         text: [str(p["name"]), feed.caption(p)].filter { !$0.isEmpty }.joined(separator: "\n"), media: str(p["photo"]), video: Feed.video(p) != nil) } label: { Label("Report post", systemImage: "flag") }
                    }
                    if owner == feed.me {
                        Button { rewording = PostBox(post: p) } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = PostBox(post: p) } label: { Label("Delete post", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(10) }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            Group {
                if kind == "moment" { moment(p, rx: rx) }
                else if photo { photoView(p) }
                else { card(p) }
            }
            .onTapGesture(count: 2) { like(p, rx: rx) }
            // a video opens full screen, to swipe on through the others
            .onTapGesture { if Feed.video(p) != nil { reels = ReelStart(id: id) } }
            .overlay {
                if burst == id {
                    HeartBurst().transition(.identity)
                }
            }
            // two fingers on a photo or video make it bigger while they're on it, as Instagram's feed does
            .modifier(PinchToZoom(id: id, held: $zoomed, on: photo && kind != "moment"))

            actions(p, rx: rx, comments: cm.count)
            if photo && kind != "moment" && kind != "photo" { foodLine(p) }
            if !rx.isEmpty { likedBy(rx).padding(.horizontal, 14).padding(.top, 2) }
            if !feed.caption(p).isEmpty {
                (Text(feed.name(owner) + " ").bold() + Text(Tagging.styled(feed.caption(p)))).font(.subheadline).padding(.horizontal, 14).padding(.top, 4)
                    .tagLinks({ profileOf = $0 }, tag: { tagOf = $0 })
            }
            if !cm.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(keyed(Array(cm.suffix(2)))) { e in
                        (Text(feed.name(str(e.item["user_id"])) + " ").bold() + Text(str(e.item["text"]))).font(.subheadline).lineLimit(2)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 4)
                .contentShape(Rectangle()).onTapGesture { talking = PostBox(post: p) }
            }
            Button { talking = PostBox(post: p) } label: {
                Text(cm.isEmpty ? "Add a comment…" : cm.count <= 2 ? "Add a comment…" : "View all \(cm.count) comments")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 14)
        }
    }

    /// A post's song, on its own line under the name, as a story's is (19 Nov; the owner's mockup, option 1): bars
    /// that move while it plays (a crossed speaker while it's off), the artist or mood, the title, and a › for its
    /// card. The speaker on the picture is still the one way to turn it off and on.
    private func songTag(_ s: Song, post p: JSON) -> some View {
        let on = SongPlayer.shared.playing == "post:" + str(p["id"])
        return Button { songOf = PostBox(post: p) } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "waveform" : "speaker.slash.fill").font(.system(size: 10, weight: .bold))
                    .contentTransition(.identity).animation(nil, value: on)
                    .symbolEffect(.variableColor.iterative, isActive: on)
                HStack(spacing: 0) {
                    if !s.byline.isEmpty { Text(s.byline).fontWeight(.bold); Text(" · ") }
                    Marquee(text: s.title, maxWidth: 170)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .font(.caption).foregroundStyle(.primary)
            .padding(.top, 1).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Song: \(s.title)")
    }

    private func songLine(_ s: Song, post: String) -> some View {
        let on = SongPlayer.shared.playing == "post:" + post
        return Button { SongPlayer.shared.toggle(s, key: "post:" + post) } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "pause.fill" : "music.note").font(.system(size: 11, weight: .bold))
                Text(s.title).lineLimit(1)
                if on { Text("· playing").foregroundStyle(.secondary) }
            }
            .font(.caption.weight(.bold)).foregroundStyle(on ? Theme.accent : Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 6).background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
        .accessibilityLabel(on ? "Stop \(s.title)" : "Play \(s.title)")
    }

    /// "Lunch", "Push day", "Snack": what the post is.
    static func what(_ p: JSON) -> String {
        switch str(p["kind"]) {
        case "workout": return "Worked out"
        case "meal": return "Shared a meal"
        case "moment": return "A milestone"
        case "photo": return "Shared a photo"
        default: let m = str(dict(p["extra"])["meal"]); return m.isEmpty ? "Shared a food" : (m == "Snacks" ? "Snack" : m)
        }
    }

    private func numbers(_ p: JSON) -> (kcal: String, protein: String?) {
        let kcal = num(p["kcal"]) ?? 0, pr = num(dict(p["macros"])["p"])
        let each = str(p["kind"]) == "meal" ? " a portion" : ""
        return ("\(Fmt.int(kcal)) kcal\(each)", pr.map { "\(Int($0)) g protein" })
    }

    private func photoView(_ p: JSON) -> some View {
        let shape = num(dict(p["extra"])["aspect"]).map { min(1.91, max(0.75, $0)) }
        return PostPhotos(post: p)
            .frame(maxWidth: .infinity).frame(height: shape.map { (UIScreen.main.bounds.width / $0).rounded() } ?? 400)
            // (a mixed one has its levels in it already)
            .overlay { if let v = Feed.video(p) { FeedVideo(url: v, songKey: Music.of(p) != nil ? "post:" + str(p["id"]) : nil, clipVolume: Music.mixed(p) ? 1 : Music.mix(p).clip) } }   // under the name and numbers
            .clipped()
            .contentShape(Rectangle())
            // A workout sticker on it opens its workout (19 Nov). The sticker's drawn into the picture; this is the
            // same sticker, where it was put, all but see-through, to be tapped.
            .overlay {
                let live = list(dict(p["extra"])["live"])
                if !live.isEmpty {
                    StoryLayer(items: live, openWorkout: { o in recipe = StoryItem.workoutPost(o, owner: str(p["owner"])) }).opacity(0.02)
                }
            }
            // a photo with a song: its sound on and off at the bottom right, as Instagram has it
            .overlay {
                if let song = Music.of(p) { SongSwitch(song: song, key: "post:" + str(p["id"]), volume: Music.mix(p).song, inVideo: Music.mixed(p)) }
            }
            .overlay(alignment: .bottomLeading) {
                // someone tagged: a person in the corner, as Instagram has it, for who's in it (TaggedSheet)
                let tagged = (dict(p["extra"])["tags"] as? [String]) ?? []
                HStack(spacing: 8) {
                    if !tagged.isEmpty {
                        Button { taggedIn = TagBox(ids: tagged) } label: {
                            Image(systemName: "person.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 30, height: 30).background(.black.opacity(0.5), in: Circle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(tagged.count == 1 ? "Tagged: 1 person" : "Tagged: \(tagged.count) people")
                    }
                    // (25 Nov, design/feed-food-line-mockup.html A: the name, numbers and Have some left the photo for
                    // foodLine under the icons; on the photo's tag the name was cut short)
                }
                .padding(12)
            }
    }

    /// A photo post's food or workout, under the icons (25 Nov, feed-food-line-mockup A): the name in full, its kcal
    /// and protein, and Have some at the words' own size on the right.
    private func foodLine(_ p: JSON) -> some View {
        let n: (kcal: String, protein: String?) = numbers(p)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(str(p["name"])).font(.subheadline.weight(.bold)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(n.kcal).foregroundStyle(.secondary)
                    if let pr = n.protein {
                        Text("·").foregroundStyle(.secondary)
                        Text(pr).foregroundStyle(Theme.walk)
                    }
                }
                .font(.caption.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            haveSome(p)
        }
        .padding(.horizontal, 14).padding(.top, 4)
    }

    /// Have some (a meal or food: it opens to add it to your day), Recipe, or Do it (a workout), as a small button
    /// in the words' own size: on the end of a photo's tag, or on a card. Nothing for a photo or a badge moment.
    @ViewBuilder private func haveSome(_ p: JSON) -> some View {
        let kind = str(p["kind"])
        if kind != "moment" && kind != "photo" {
            let word = kind == "workout" ? "Do it" : kind == "meal" ? "Recipe" : "Have some"
            Button { recipe = p } label: {
                HStack(spacing: 3) {
                    Image(systemName: kind == "workout" ? "play.fill" : "plus").font(.system(size: 9, weight: .heavy))
                    Text(word).lineLimit(1).fixedSize()
                }
                .font(.caption.weight(.bold)).foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain).accessibilityLabel(word)
        }
    }

    /// No photo: the post as a card in the theme's colours, so the feed never looks empty.
    private func card(_ p: JSON) -> some View {
        let kind = str(p["kind"]), n = numbers(p)
        let lifts = list(dict(p["payload"])["lifts"])
        let kg = lifts.reduce(0.0) { $0 + (num($1["sets"]) ?? 0) * (num($1["reps"]) ?? 0) * (num($1["kg"]) ?? 0) }
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: kind == "workout" ? "Workout" : kind == "meal" ? "Meal" : Self.what(p), color: Theme.heroLabel)
            // the button beside the name, up clear of the sound button at the bottom right (23 Nov: on a workout with a
            // song, Do it sat under it)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(str(p["name"])).font(.title2.weight(.heavy)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                haveSome(p)
            }
            if kind == "workout" {
                // A, the scoreboard (16 Nov): three big numbers on one line with no boxes, then a bar of where the
                // weight went, exercise by exercise. No picture: the numbers carry it.
                let mins = Int(num(dict(p["extra"])["minutes"]) ?? 0)
                HStack(spacing: 0) {
                    score("\(mins)", mins == 1 ? "minute" : "minutes", line: false)
                    score("\(lifts.count)", lifts.count == 1 ? "exercise" : "exercises", line: true)
                    if kg > 0 { score(Fmt.int(kg), "kg lifted", line: true) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                if kg > 0 { weightBar(lifts, kg) }
            } else {
                HStack(spacing: 8) {
                    Text(n.kcal)
                    if let pr = n.protein { Text("·"); Text(pr).foregroundStyle(Theme.walk) }
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: kind == "workout" ? 190 : 140, alignment: .leading)
        .background(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if kind != "workout" { FoodDot(name: str(p["name"]), size: 110).opacity(0.28).offset(x: 18, y: -14) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // a card with a song (a workout's): its sound on and off at the bottom right, as a photo's is, and it plays
        // as it comes up the feed the same way (18 Nov: the song was named but couldn't be heard)
        .overlay { if let song = Music.of(p) { SongSwitch(song: song, key: "post:" + str(p["id"]), volume: Music.mix(p).song) } }
        .padding(.horizontal, 14)
    }

    /// One of a workout's big numbers, with a thin line before it when it isn't the first.
    private func score(_ value: String, _ label: String, line: Bool) -> some View {
        HStack(spacing: 0) {
            if line { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1).padding(.trailing, 14) }
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity)
    }

    /// Where a workout's weight went: one bar split by exercise (sets × reps × kg), biggest first, with the top
    /// three named under it.
    private func weightBar(_ lifts: [JSON], _ total: Double) -> some View {
        let parts = lifts.map { (str($0["exercise"]), (num($0["sets"]) ?? 0) * (num($0["reps"]) ?? 0) * (num($0["kg"]) ?? 0)) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let sum = max(1, parts.reduce(0) { $0 + $1.1 })
        let shade: (Int) -> Color = { Theme.accent.opacity(max(0.3, 1 - Double($0) * 0.18)) }
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                let room = g.size.width - CGFloat(max(0, parts.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        shade(i).frame(width: max(2, room * CGFloat(parts[i].1 / sum)))
                    }
                }
            }
            .frame(height: 10).clipShape(Capsule())
            HStack(spacing: 12) {
                ForEach(Array(parts.prefix(3).enumerated()), id: \.offset) { i, part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(shade(i)).frame(width: 8, height: 8)
                        Text(part.0).lineLimit(1)
                    }
                }
                if parts.count > 3 { Text("+\(parts.count - 3)").fixedSize() }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.weight(.bold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// A streak, a badge or a rank up, with a Cheer.
    private func moment(_ p: JSON, rx: [JSON]) -> some View {
        let x = dict(p["extra"]), cheered = rx.contains { str($0["emoji"]) == "🎉" && str($0["user_id"]) == feed.me }
        return HStack(spacing: 14) {
            FluentIcon(emoji: str(x["emoji"]).isEmpty ? "🏆" : str(x["emoji"]), size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(str(p["name"])).font(.headline)
                if !str(x["detail"]).isEmpty { Text(str(x["detail"])).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if str(p["owner"]) != feed.me {
                Button { Task { await feed.toggle(p, "🎉") } } label: {
                    HStack(spacing: 5) {
                        FluentIcon(emoji: "🎉", size: 17)   // the app's own icon, not the phone's emoji
                        Text(cheered ? "Cheered" : "Cheer").font(.subheadline.weight(.heavy)).foregroundStyle(.black)
                    }
                        .padding(.horizontal, 13).padding(.vertical, 8).background(Color.orange.opacity(cheered ? 0.55 : 1), in: Capsule())
                }
                .buttonStyle(.plain).sensoryFeedback(.success, trigger: cheered)
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Color.orange.opacity(0.28), Color.pink.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
    }

    // MARK: heart, comments, send, and what to do with it

    private func like(_ p: JSON, rx: [JSON]) {
        let id = str(p["id"])
        if !rx.contains(where: { str($0["emoji"]) == "❤️" && str($0["user_id"]) == feed.me }) { Task { await feed.toggle(p, "❤️") } }
        // tapped again while it's still up: a fresh one
        burst = nil
        DispatchQueue.main.async { burst = id }
        Task { try? await Task.sleep(for: .milliseconds(1000)); if burst == id { burst = nil } }
    }

    private func actions(_ p: JSON, rx: [JSON], comments: Int) -> some View {
        let id = str(p["id"]), kind = str(p["kind"])
        let mine = rx.filter { str($0["user_id"]) == feed.me }.map { str($0["emoji"]) }
        let hearted = mine.contains("❤️"), other = mine.first { $0 != "❤️" && $0 != "🎉" }
        let likes = Set(rx.map { str($0["user_id"]) }).count
        return VStack(alignment: .leading, spacing: 0) {
            if picking == id {
                HStack(spacing: 14) {
                    ForEach(Feed.reacts, id: \.self) { e in
                        Button { picking = nil; Task { await feed.toggle(p, e) } } label: {
                            Text(e).font(.system(size: 30)).scaleEffect(mine.contains(e) ? 1.2 : 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .padding(.horizontal, 10).padding(.top, 8)
                .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
            HStack(spacing: 16) {
                // the app's own heart, one of the set beside it (23 Nov, own-heart-mockup)
                GlyphIcon(glyph: .heart, size: 28, filled: hearted)
                    .foregroundStyle(hearted ? Color(red: 1, green: 0.3, blue: 0.4) : .primary)
                .contentShape(Rectangle())
                // a like, on or off. No row of other emoji here: those are for answering a story
                .onTapGesture { Task { await feed.toggle(p, "❤️") } }
                .sensoryFeedback(.selection, trigger: hearted)
                .accessibilityLabel(hearted ? "Unlike" : "Like").accessibilityAddTraits(.isButton)
                // how many, beside each, as Instagram shows them (none shown for none)
                // The counts always show whole. The row was a few points too wide for the screen with a like, a comment
                // and "Have some" all there, and the squeeze fell on a number, which lost half of itself.
                if likes > 0 { Text("\(likes)").font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize().padding(.leading, -10).accessibilityLabel("\(likes) likes") }
                // (23 Nov: the app's own icons, as on a reel, and Repost between Comment and Send, as Instagram's row)
                Button { talking = PostBox(post: p) } label: {
                    HStack(spacing: 6) {
                        GlyphIcon(glyph: .comment, size: 28)
                        if comments > 0 { Text("\(comments)").font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize() }
                    }
                }
                    .buttonStyle(.plain).accessibilityLabel(comments == 0 ? "Comment" : "\(comments) comments")
                if Feed.canRepost(p) {
                    let again = feed.reposted.contains(id), reposts = feed.repostCounts[id] ?? 0
                    Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); Task { await feed.toggleRepost(p) } } label: {
                        HStack(spacing: 6) {
                            GlyphIcon(glyph: .repost, size: 28).foregroundStyle(again ? Color.reposted : Color.primary)
                            if reposts > 0 { Text("\(reposts)").font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize() }
                        }
                    }
                    .buttonStyle(.plain).accessibilityLabel(again ? "Reposted, tap to take back" : "Repost")
                }
                Button { sharing = PostBox(post: p) } label: { GlyphIcon(glyph: .send, size: 28) }
                    .buttonStyle(.plain).accessibilityLabel("Send to a friend")
                Spacer(minLength: 0)
                // (Have some went onto the photo's tag, 23 Nov: the row is the icons alone, as Instagram's)
                // save it for yourself (only you see what you've saved; the number is how many have)
                let kept = feed.saved.contains(id), keeps = feed.saveCounts[id] ?? 0
                Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); Task { await feed.toggleSave(p) } } label: {
                    HStack(spacing: 5) {
                        if keeps > 0 { Text("\(keeps)").font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize() }
                        GlyphIcon(glyph: .save, size: 28, filled: kept)
                    }
                }
                .buttonStyle(.plain).accessibilityLabel(kept ? "Saved, tap to take out" : "Save")
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        }
    }

    /// "Mark reposted", or "Mark and 2 others reposted", over a post; the name opens their profile.
    private func repostLine(_ first: String, others: Int) -> some View {
        HStack(spacing: 6) {
            GlyphIcon(glyph: .repost, size: 14)
            Text(feed.name(first) + (others > 0 ? " and \(others) other\(others == 1 ? "" : "s")" : "") + " reposted")
                .font(.caption.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, -4)
        .contentShape(Rectangle()).onTapGesture { profileOf = first }
        .accessibilityAddTraits(.isButton)
    }

    /// Their faces, "Liked by Sam and 3 others", and the other reactions it got.
    private func likedBy(_ rx: [JSON]) -> some View {
        var people: [String] = []
        for r in rx { let u = str(r["user_id"]); if !people.contains(u) { people.append(u) } }
        let first = people.first { $0 != feed.me } ?? people[0]
        let others = people.count - 1
        return HStack(spacing: 6) {
            HStack(spacing: -7) { ForEach(people.prefix(3), id: \.self) { u in avatar(u, size: 20).overlay(Circle().stroke(Theme.bg, lineWidth: 2)) } }
            (Text("Liked by ") + Text(feed.name(first)).bold() + Text(others > 0 ? " and " : "") + Text(others > 0 ? "\(others) other\(others == 1 ? "" : "s")" : "").bold())
                .font(.subheadline).lineLimit(1)
        }
    }

    private func avatar(_ id: String, size: CGFloat) -> some View { Avatar(id: id, size: size) }
}

struct PostBox: Identifiable { let post: JSON; var id: String { str(post["id"]) } }

/// A post's comments: likes and replies, one-tap quick replies, and the box at the bottom.
struct CommentsSheet: View {
    let post: JSON
    @State private var text = ""
    @State private var replying: JSON?
    @State private var profile: String?   // someone tagged in a comment, tapped: their page opens here
    @State private var hashtag: String?   // a hashtag in a comment, tapped: its posts open here
    @State private var reportOf: ReportTarget?
    @FocusState private var typing: Bool
    @State private var detent: PresentationDetent = .medium
    private var feed: Feed { Feed.shared }
    private var id: String { str(post["id"]) }
    private static let quick = ["🔥", "😋", "💪", "Recipe?", "Looks good!"]

    var body: some View {
        let all = feed.comments.filter { str($0["post_id"]) == id }
        let top = all.filter { c in str(c["reply_to"]).isEmpty || !all.contains { str($0["id"]) == str(c["reply_to"]) } }
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if all.isEmpty { Text("No comments yet. Say something nice.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 24) }
                        ForEach(keyed(top)) { e in
                            row(e.item, reply: false)
                            ForEach(keyed(all.filter { str($0["reply_to"]) == str(e.item["id"]) })) { r in row(r.item, reply: true) }
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                // the box pinned to the sheet's foot, where the keyboard lifts it: as a plain row under the list it
                // was sometimes left behind the keyboard when Reply opened it (17 Nov)
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
            .navigationTitle("Comments").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $profile) { id in ProfileView(id: id) }
            .navigationDestination(item: $hashtag) { t in HashtagView(tag: t) }
            .reportDialog($reportOf)
            .onAppear { KeyboardDone.quiet = true }
            .onDisappear { KeyboardDone.quiet = false }
            // the box tapped straight into at half height goes full height too
            .onChange(of: typing) { _, now in if now, detent != .large { withAnimation(.snappy) { detent = .large } } }
        }
        // full height before the keyboard comes up: growing from half height while the keyboard rose is the likely
        // way the box got left under it
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    /// Open the box to type: the sheet goes full height first, then the keyboard.
    private func startTyping() {
        if detent == .large { typing = true; return }
        withAnimation(.snappy) { detent = .large }
        Task { try? await Task.sleep(for: .milliseconds(350)); typing = true }
    }

    private var composer: some View {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Self.quick, id: \.self) { q in
                                // put into the box to be sent with whatever else is written, not sent on the spot (a slip
                                // of the thumb posted a comment)
                                Button {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    let gap = text.isEmpty || text.hasSuffix(" ") ? "" : " "
                                    text += gap + q
                                    startTyping()
                                } label: { Text(q).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7).background(Color(.tertiarySystemFill), in: Capsule()) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    if let r = replying {
                        HStack {
                            Text("Replying to \(feed.name(str(r["user_id"])))").font(.caption).foregroundStyle(.secondary)
                            Button { replying = nil } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    TagSuggestions(text: $text)
                    HStack(spacing: 8) {
                        TextField(replying == nil ? "Add a comment for \(feed.name(str(post["owner"])))…" : "Your reply…", text: $text, axis: .vertical)
                            .lineLimit(1...4).focused($typing).submitLabel(.send).onSubmit { send(text) }
                        Button { send(text) } label: {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onAccent)
                                .frame(width: 32, height: 32).background(Theme.accent.opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1), in: Circle())
                        }
                        .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityLabel("Send")
                    }
                    .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                    .composerGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
                .composerBar()
    }

    private func row(_ c: JSON, reply: Bool) -> some View {
        let cid = str(c["id"]), who = str(c["user_id"])
        let likes = feed.commentLikes.filter { str($0["comment_id"]) == cid }
        let liked = likes.contains { str($0["user_id"]) == feed.me }
        return HStack(alignment: .top, spacing: 10) {
            Avatar(id: who, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                (Text(feed.name(who) + " ").bold() + Text(Tagging.styled(str(c["text"])))).font(.subheadline)
                    .tagLinks({ profile = $0 }, tag: { hashtag = $0 })
                HStack(spacing: 14) {
                    Text(Feed.ago(str(c["created_at"])))
                    if !likes.isEmpty { Text(likes.count == 1 ? "1 like" : "\(likes.count) likes") }
                    Button("Reply") { replying = reply ? (feed.comments.first { str($0["id"]) == str(c["reply_to"]) } ?? c) : c; startTyping() }.buttonStyle(.plain).fontWeight(.semibold)
                    if who == feed.me { Button("Delete") { Task { await feed.deleteComment(c) } }.buttonStyle(.plain) }
                    else { Button("Report") { reportOf = ReportTarget(user: who, what: "Comment: \(cid) \"\(String(str(c["text"]).prefix(140)))\"", kind: "comment", target: cid, text: str(c["text"])) }.buttonStyle(.plain) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { Task { await feed.likeComment(c) } } label: {
                Image(systemName: liked ? "heart.fill" : "heart").font(.caption).foregroundStyle(liked ? Color(red: 1, green: 0.3, blue: 0.4) : .secondary).padding(6)
            }
            .buttonStyle(.plain).sensoryFeedback(.selection, trigger: liked).accessibilityLabel(liked ? "Unlike comment" : "Like comment")
        }
        .padding(.leading, reply ? 40 : 0)
    }

    private func send(_ t: String) {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let to = replying
        text = ""; replying = nil
        Task { await feed.comment(post, String(s.prefix(300)), replyTo: to) }
    }
}

/// Send a post to one friend, with a note: it's in their Activity, and a tap opens it.
struct SharePostSheet: View {
    let post: JSON
    @Environment(\.dismiss) private var dismiss
    @State private var resharing = false
    /// Your own posts, and anyone's public post, can go on your story (not a badge moment, which has its own).
    private var canReshare: Bool {
        let owner = str(post["owner"])
        guard str(post["kind"]) != "moment" else { return false }
        return owner == Feed.shared.me || Profiles.shared.all[owner].map { !$0.isPrivate } == true
    }
    var body: some View {
        SendToSheet(exclude: str(post["owner"]), send: { friend, note in await Feed.shared.share(post, to: friend, note: note) },
                    addToStory: canReshare ? { resharing = true } : nil)
            .fullScreenCover(isPresented: $resharing) { PostReshare(post: post, done: { dismiss() }) }
    }
}


/// Share something: one of today's foods, a saved meal or today's workout, with a caption and an optional photo.
/// A video post on the feed: plays on a loop while it's on screen, muted until the speaker's tapped.
/// A photo that has a song: the song starts as the photo comes up the feed (most of it on screen) and stops as it
/// leaves, and the speaker at its bottom right turns the sound off and on, for every photo from then on.
struct SongSwitch: View {
    let song: Song
    let key: String
    var volume: Float = 1
    /// The song's mixed into the post's video: the video's own sound is it (see SongMix).
    var inVideo = false
    var body: some View {
        let on = SongPlayer.shared.playing == key
        // the size of the photo, to know when most of it is showing; only the speaker takes touches
        Color.clear
            .overlay(alignment: .bottomTrailing) {
                Button { SongPlayer.shared.flip(song, key: key, volume: volume, inVideo: inVideo) } label: {
                    Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .contentTransition(.identity).animation(nil, value: on)
                        .frame(width: 32, height: 32).background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain).padding(10)
                .accessibilityLabel(on ? "Sound off" : "Sound on")
            }
            .modifier(MostlyShowing { showing in
                if showing { SongPlayer.shared.arrive(song, key: key, volume: volume, inVideo: inVideo) } else { SongPlayer.shared.leave(key) }
            })
            .onDisappear { SongPlayer.shared.leave(key) }
    }
}

/// Tells when most of a view (six tenths) has come onto the screen in a scrolling list, and when it's gone again.
/// On iOS 17, which can't measure that, it's when the view arrives in the list and leaves it: a little early, but
/// the same idea.
struct MostlyShowing: ViewModifier {
    let changed: (Bool) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.6) { changed($0) }
        } else {
            content.onAppear { changed(true) }.onDisappear { changed(false) }
        }
    }
}

struct FeedVideo: View {
    let url: URL
    /// The post has a song, known to the song player by this name. The two are heard together, as Instagram blends
    /// them: the clip's own sound is on whenever its song is playing, and the one speaker (SongSwitch) is for both.
    var songKey: String? = nil
    var clipVolume: Float = 1
    @State private var muted = true
    @State private var showing = false
    @State private var mostly = false   // most of it on the screen (for the volume buttons)
    var body: some View {
        LoopingVideo(url: url, paused: !showing, muted: songKey.map { SongPlayer.shared.playing != $0 } ?? muted, volume: clipVolume)
            .allowsHitTesting(false)
            .onAppear { showing = true }
            .onDisappear { showing = false; if !muted { muted = true; loud(false) } }
            // one without a song, mostly on the screen: the volume buttons turn its sound on
            .modifier(MostlyShowing { mostly = $0 })
            .onReceive(NotificationCenter.default.publisher(for: .soundOn)) { _ in if songKey == nil, mostly, muted { muted = false; loud(true) } }
            .overlay(alignment: .topTrailing) {
                if songKey == nil {
                Button { muted.toggle(); loud(!muted) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .contentTransition(.identity).animation(nil, value: muted)
                        .frame(width: 32, height: 32).background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain).padding(10).accessibilityLabel(muted ? "Sound on" : "Sound off")
                }
            }
    }
}

extension FeedVideo {
    /// Sound they turned on is heard with the ringer off too (the song button was; the video's speaker button wasn't,
    /// so it looked broken on a silenced phone). Turned off again, the app goes back to respecting the switch.
    func loud(_ on: Bool) {
        // (switched away from the screen: see Sound)
        if on { Sound.on(.moviePlayback) } else if SongPlayer.shared.playing == nil { Sound.off() }
    }
}

struct ComposeSheet: View {
    var preset: JSON? = nil
    /// A new post starts as the picker, in this same sheet (not the write-up with the picker coming up over it a
    /// moment later). Not when it's of a workout or food already, or there are drafts to carry on with.
    @State private var firstPick: Bool
    /// A video to post (an edit, from Make an edit): it opens in the video editor straight away, as one picked would.
    private let startVideo: URL?
    /// Share tapped (not cancelled, not saved as a draft), and then it's up on the feed.
    private let shared: (() -> Void)?
    private let sent: () -> Void
    @State private var importFailure: ImportFailure?
    @State private var startedVideo = false
    init(preset: JSON? = nil, video: URL? = nil, shared: (() -> Void)? = nil, sent: @escaping () -> Void = {}) {
        self.preset = preset
        self.startVideo = video
        self.shared = shared
        self.sent = sent
        _firstPick = State(initialValue: preset == nil && video == nil && Drafts.all().isEmpty)
    }
    @Environment(\.dismiss) private var dismiss
    @State private var what: JSON?
    @State private var caption = ""
    @State private var editing: EditBox?
    /// A photo post's pictures, in order (up to ten): each as it came, to edit again from, and as edited.
    @State private var shots: [Shot] = []
    @State private var showing = 0   // which of them is in the big tile
    @State private var movie: URL?   // a video post: the clip
    @State private var poster: UIImage?   // and its cover, exactly as it will be posted
    @State private var clip = ClipEdit()   // what the editor did to it
    @State private var cutting: ClipBox?   // a clip in the editor
    @State private var multi: ClipsBox?   // several clips being made into one video (MultiClipEditor)
    @State private var choosingCover = false
    @State private var picked: [PhotosPickerItem] = []
    // drafts: the ones kept on this phone, the one this post was opened from, and ✕ asking what to do with it
    @State private var drafts: [JSON] = []
    @State private var draftID: String?
    @State private var leaving = false
    @State private var triedPoster = false
    /// A photo of the post: as it was picked, as it was finished, and the editor as it was left (to open it again with
    /// its text, stickers, drawing and look still there to change).
    private struct Shot: Identifiable { let id = UUID(); var source: UIImage; var out: UIImage; var edit: ClipEdit? = nil }
    @State private var leftEdit: ClipEdit?   // the editor as it's just been left, on its way to the photo it was for
    /// The picture in the tile: the video's cover, or the photo picked from the row.
    private var photo: UIImage? { movie != nil ? poster : (shots.indices.contains(showing) ? shots[showing].out : shots.first?.out) }
    private var firstShape: CGFloat? { shots.first.map { $0.out.size.width / max($0.out.size.height, 1) } }
    private var started: Bool { !shots.isEmpty || movie != nil || !tags.isEmpty || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (what != nil && preset == nil) || song != nil }
    @State private var camera = false
    @State private var library = false
    @State private var picking = false   // the app's own picker: the one chosen big, recents under it
    @State private var opened = false
    /// Where a photo post is: 0, its pictures with the tools under them (Instagram's middle screen); 1, writing it up.
    @State private var stage = 1
    private var inHub: Bool { stage == 0 && movie == nil && !shots.isEmpty }
    @State private var pickerFirst = false   // the picker is what New post opened on: closing it closes New post
    @State private var attaching = false   // the list of foods, meals and workouts is open
    @State private var song: Song?
    @State private var choosingSong = false
    @State private var songVol = 1.0   // how loud the song is, and the video's own sound against it
    @State private var clipVol = 1.0
    @State private var tags: [String] = []   // friends in the post
    @State private var tagging = false
    @FocusState private var writing: Bool
    @State private var busy = false
    @State private var problem: String?
    @State private var shelf = 0   // Foods, Meals, Workouts: one list at a time, or all three when searching
    private var store: Store { Store.shared }

    var body: some View {
        ZStack {
            form
            if firstPick && !started {
                PostPicker(room: 10, photosOnly: false,
                           done: { images, video in took(images, video, wait: false) },
                           // several with a video among them: into the multi-clip editor, made into one video
                           clips: { c in multi = ClipsBox(clips: c) },
                           // the camera, the system's picker and the video editor come up over the picker, which is
                           // still there if they're backed out of; it goes once there's something in the post
                           camera: { camera = true },
                           allPhotos: { library = true },
                           noPhoto: { firstPick = false },
                           close: { dismiss() })
                    .background(Theme.bg.ignoresSafeArea())
            }
        }
        // an edit to post: into the video editor with it, once
        .onAppear { if let v = startVideo, !startedVideo { startedVideo = true; took([], v, wait: false) } }
    }

    private var form: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if !started && preset == nil && !drafts.isEmpty { draftList.padding(.horizontal, 14).padding(.top, 14) }
                    // The picture small beside the caption, then what can go with the post in rounded groups, as
                    // Instagram's share screen has it. (The picture took half the page, the caption had no place
                    // of its own, the lines between rows ran off the right edge and song ideas sat loose among them.)
                    HStack(alignment: .top, spacing: 14) {
                        picture
                        TextField("Write a caption…", text: $caption, axis: .vertical).lineLimit(4...8).focused($writing)
                            .font(.body).padding(.top, 6)
                            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
                            .contentShape(Rectangle()).onTapGesture { writing = true }
                    }
                    .padding(.horizontal, 16).padding(.top, 14).id("caption")
                    TagSuggestions(text: $caption).padding(.horizontal, 16)
                    // A workout or a meal with no picture yet: Camera and Library, one tap each (A, 16 Nov). The only way
                    // was the small + in the tile's corner, which went unseen. Gone once there's a picture.
                    if what != nil, photo == nil, movie == nil {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add a photo or video").font(.subheadline.weight(.bold))
                            Text("Optional").font(.footnote).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                addButton("Camera") { camera = true }
                                addButton("Library") { picking = true }
                            }
                            .padding(.top, 10)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 14).padding(.top, 14)
                    }
                    if movie != nil {
                        Text("Up to \(Int(Stories.longest)) seconds are posted.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 8)
                    }
                    Text("ADD TO YOUR POST").font(.caption.weight(.bold)).kerning(1).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 8)
                    attachment.modifier(FormGroup())
                    VStack(spacing: 0) {
                        songRow
                        if song != nil {
                            // a video's song is set against its own sound in the editor (Audio), with the video
                            // playing; here just the song's own level, for a photo
                            Group {
                                if movie == nil { MixSliders(song: $songVol, clip: $clipVol, hasClip: false) }
                                else { Text("To set how loud the song and the video are, edit the video and tap Audio.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            .padding(.leading, 56).padding(.trailing, 14).padding(.bottom, 12)
                        }
                        Divider().padding(.leading, 56)
                        tagRow
                    }
                    .modifier(FormGroup()).padding(.top, 12)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 8) }
                }
                .padding(.bottom, 44)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: writing) { _, on in
                if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(.snappy) { proxy.scrollTo("caption", anchor: .center) } } }
            }
            }
            // to every edge and under the keyboard: the sheet's own grey showed in the strip behind Done
            .background(Theme.bg.ignoresSafeArea().importFailed($importFailure))
            .presentationBackground(Theme.bg)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let ready = what != nil || photo != nil || movie != nil
                if !writing && !inHub {
                Button { post() } label: {
                    Text("Share").font(.headline.weight(.heavy)).foregroundStyle(ready ? Theme.onAccent : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(ready ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                }
                .buttonStyle(.plain).disabled(!ready || busy)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10).background(Theme.bg)
                }
            }
            .keyboardDone()
            .overlay { if inHub { hub.background(Theme.bg.ignoresSafeArea()).transition(.opacity) } }
            .onAppear {
                if what == nil, let preset { what = preset }
                drafts = Drafts.all()
                // a new post starts by choosing its picture, as Instagram's does (unless it's of a workout or food
                // already, or there are drafts to carry on with); closing the picker leaves the post to be written without one
                opened = true
            }
            .fullScreenCover(isPresented: $picking) {
                PostPicker(room: max(1, 10 - shots.count), photosOnly: !shots.isEmpty,
                           done: { images, video in pickerFirst = false; picking = false; took(images, video) },
                           // (a post with photos in it shows only photos here, so this is only ever a new post's)
                           clips: { c in pickerFirst = false; picking = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { multi = ClipsBox(clips: c) } },
                           camera: { pickerFirst = false; picking = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { camera = true } },
                           allPhotos: { pickerFirst = false; picking = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { library = true } },
                           // only while nothing's been started: a post of a meal or a workout alone, written up without a picture
                           noPhoto: started ? nil : { pickerFirst = false; picking = false },
                           // X on the picker New post opened with closes New post: the empty write-up screen behind it was a dead end
                           close: { if pickerFirst && !started { dismiss() } else { picking = false } })
            }
            .interactiveDismissDisabled(started)
            // a box in the middle (18 Nov): as a confirmation dialog, iOS 26 popped it out of the ✕, over the photo
            .alert("Keep this post to finish later?", isPresented: $leaving) {
                Button("Save draft") { saveDraft() }
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            // a song being listened to here stops when another screen comes up over this one (it used to play on
            // through choosing a cover, the editor and the rest)
            .onChange(of: choosingCover || cutting != nil || editing != nil || picking || tagging || attaching || camera || library) { _, away in
                if away { SongPlayer.shared.stop() }
            }
            .sheet(isPresented: $choosingCover) {
                if let movie { CoverPicker(url: movie, edit: clip, start: poster) { at, still in clip.cover = at; if let still { poster = still } } }
            }
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // from the write-up, back to the pictures; from there (or with none), out
                    let back = stage == 1 && movie == nil && !shots.isEmpty
                    Button {
                        writing = false
                        if back { withAnimation(.snappy(duration: 0.25)) { stage = 0 } } else if started { leaving = true } else { dismiss() }
                    } label: { Image(systemName: back ? "chevron.left" : "xmark") }
                    .accessibilityLabel(back ? "Back" : "Cancel")
                }
                // while the keyboard's up, Share is here
                if writing && (what != nil || photo != nil || movie != nil) {
                    ToolbarItem(placement: .topBarTrailing) { Button(busy ? "Sharing…" : "Share") { writing = false; post() }.fontWeight(.bold).disabled(busy) }
                }
            }
            .sheet(isPresented: $attaching) { AttachPicker(start: shelf) { what = $0 } }
            .sheet(isPresented: $choosingSong) { SongPicker { song = $0 } }
            .sheet(isPresented: $tagging) { TagPicker(picked: $tags) }
            .photosPicker(isPresented: $library, selection: $picked, maxSelectionCount: max(1, 10 - shots.count), selectionBehavior: .ordered, matching: shots.isEmpty ? PHPickerFilter.any(of: [.images, .videos]) : PHPickerFilter.images)
            // several picked with a video among them: made into one video first (MultiClipEditor), then edited as one
            .fullScreenCover(item: $multi) { b in
                MultiClipEditor(clips: b.clips, close: { multi = nil }, done: { url in multi = nil; took([], url) })
            }
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = EditBox(image: img) } } }.ignoresSafeArea() }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    let movies = items.filter { $0.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) }.count
                    if shots.isEmpty, items.count > 1, movies > 0 {
                        // several with a video among them: one video made of them all
                        library = false; picked = []
                        await loadSeveral(items)
                        return
                    }
                    if shots.isEmpty, let first = items.first, first.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
                       let m = try? await first.loadTransferable(type: PickedMovie.self) {
                        library = false
                        took([], m.url)
                    } else {
                        var got: [UIImage] = []
                        for item in items { if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { got.append(img) } }
                        library = false
                        took(got, nil)
                    }
                    picked = []
                }
            }
            .fullScreenCover(item: $cutting) { c in
                StoryEditor(image: nil, video: c.url, close: { cutting = nil }, finishVideo: { e in
                    var e = e
                    // the cover picked before stays, if that moment is still in the part kept
                    if movie == c.url, let at = clip.cover, e.range.map({ $0.contains(at) }) ?? true { e.cover = at }
                    clip = e; movie = c.url; shots = []; poster = nil; triedPoster = false; cutting = nil; firstPick = false
                    Task { poster = await e.still(c.url) }
                }, startShape: clip.shape, startPoster: c.first, startEdit: movie == c.url ? clip : nil, postSong: $song, postSongVol: $songVol, postClipVol: $clipVol)
            }
            // the story editor, in the feed's 4:5: text, stickers, drawing and filters baked into the photo
            .fullScreenCover(item: $editing) { e in
                // any photo but the first keeps the first one's shape, as the feed shows them all in it
                let later = e.index.map { $0 > 0 } ?? !shots.isEmpty
                // one already in the post opens whole, in the shape it has; a new one in the feed's 4:5
                let own = min(1.91, max(0.75, e.image.size.width / max(e.image.size.height, 1)))
                StoryEditor(image: e.image, video: nil, aspect: later ? (firstShape ?? 4.0 / 5.0) : (e.index != nil ? own : 4.0 / 5.0), close: { editing = nil }, finish: { out in
                    movie = nil; poster = nil
                    // the editor as it was left goes with the photo, when it was opened from the photo as picked (opened
                    // from the finished picture, with everything already part of it, there's nothing to keep apart)
                    let kept = e.whole ? leftEdit : nil
                    if let i = e.index, shots.indices.contains(i) { shots[i].out = out; if e.whole { shots[i].edit = kept } }
                    else if shots.count < 10 { shots.append(Shot(source: e.image, out: out, edit: kept)); showing = shots.count - 1; stage = 0; firstPick = false }
                    leftEdit = nil
                    editing = nil
                }, startShape: later ? nil : e.edit?.shape, lockShape: later, startTool: e.tool, startEdit: e.edit,
                   startItems: e.edit == nil && e.index == nil && shots.isEmpty ? workoutSticker : [], photoKept: { leftEdit = $0 })
            }
        }
    }

    /// What was picked, from the app's picker or the system's. A video (only as the post's one picture) goes into
    /// the editor first, to trim it, filter it, write on it; one photo goes straight into the editor too; several go
    /// in at once in the first one's shape, each to be edited by tapping it.
    private func took(_ images: [UIImage], _ video: URL?, wait: Bool = true) {
        Task {
            if let video, shots.isEmpty {
                if wait { try? await Task.sleep(for: .milliseconds(550)) }   // for a picker over this to have gone
                cutting = ClipBox(url: video, first: images.first)
            } else if !images.isEmpty {
                // photos: onto the screen with the tools under them (one or several), in the first one's shape
                movie = nil; poster = nil
                let from = shots.count
                for img in images where shots.count < 10 { let s = Self.sized(img); shots.append(Shot(source: s, out: Self.fitted(s, to: firstShape))) }
                showing = min(from, max(0, shots.count - 1)); stage = 0; firstPick = false
            }
        }
    }

    /// A photo no bigger than it needs to be kept at: ten camera photos at full size is more than the phone has room for.
    private static func sized(_ img: UIImage) -> UIImage {
        let long = max(img.size.width, img.size.height)
        guard long > 2400 else { return img }
        return img.preparingThumbnail(of: CGSize(width: img.size.width * 2400 / long, height: img.size.height * 2400 / long)) ?? img
    }
    /// A photo added without editing: its middle, in the first photo's shape (its own, within what the feed shows, when it is the first).
    private static func fitted(_ img: UIImage, to shape: CGFloat?) -> UIImage {
        let own = img.size.width / max(img.size.height, 1), want = shape ?? min(1.91, max(0.75, own))
        let w = own > want ? img.size.height * want : img.size.width, h = own > want ? img.size.height : img.size.width / want
        let k = min(1, 1440 / max(w, h, 1))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: (w * k).rounded(), height: (h * k).rounded()), format: format).image { _ in
            img.draw(in: CGRect(x: -(img.size.width - w) / 2 * k, y: -(img.size.height - h) / 2 * k, width: img.size.width * k, height: img.size.height * k))
        }
    }

    // MARK: drafts

    private func saveDraft() {
        let id = draftID ?? UUID().uuidString
        var meta: JSON = ["caption": caption]
        if let what { meta["what"] = what }
        if let song { meta["song"] = song.id; if let at = song.start { meta["songStart"] = at } }
        meta["mix"] = [songVol, clipVol]
        if !tags.isEmpty { meta["tags"] = tags }
        let pics = shots.map { ($0.source, $0.out) }, movie = movie, clip = clip, poster = poster
        SongPlayer.shared.stop()
        Task.detached(priority: .userInitiated) { Drafts.save(id, meta: meta, shots: pics, movie: movie, clip: clip, poster: poster) }
        dismiss()
    }

    private func open(_ d: JSON) {
        let got = Drafts.load(d)
        draftID = str(d["id"]); caption = str(d["caption"])
        if let w = d["what"] as? JSON { what = w }
        song = Music.all.first { $0.id == str(d["song"]) }
        song?.start = num(d["songStart"])
        tags = d["tags"] as? [String] ?? []
        if let m = d["mix"] as? [Double], m.count == 2 { songVol = m[0]; clipVol = m[1] }
        shots = got.shots.map { Shot(source: $0.0, out: $0.1) }; showing = 0
        movie = got.movie; clip = got.clip; poster = got.poster; triedPoster = false; stage = 1
        if let m = got.movie, got.poster == nil { Task { poster = await got.clip.still(m) } }
    }

    /// Posts kept to finish later, above an empty new one: tap to carry on with it.
    private var draftList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DRAFTS").font(.caption.weight(.heavy)).foregroundStyle(.secondary).padding(.leading, 6)
            VStack(spacing: 0) {
                ForEach(drafts.indices, id: \.self) { i in
                    let d = drafts[i], n = Int(num(d["shots"]) ?? 0), words = str(d["caption"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let kind = !str(d["movie"]).isEmpty ? "Video" : n > 1 ? "\(n) photos" : n == 1 ? "Photo" : str(dict(d["what"])["name"])
                    if i > 0 { Divider().padding(.leading, 74) }
                    HStack(spacing: 12) {
                        Group {
                            if let t = Drafts.thumb(d) { Image(uiImage: t).resizable().scaledToFill() }
                            else { LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                        }
                        .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(words.isEmpty ? "No caption yet" : words).font(.body.weight(.semibold)).foregroundStyle(words.isEmpty ? .secondary : .primary).lineLimit(1)
                            Text(kind.isEmpty ? Drafts.when(d) : "\(kind) · \(Drafts.when(d))").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button(role: .destructive) { Drafts.delete(str(d["id"])); withAnimation(.snappy) { drafts = Drafts.all() } } label: { Label("Delete draft", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(.secondary).frame(width: 36, height: 36).contentShape(Rectangle())
                        }
                        .accessibilityLabel("More")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { open(d) } }
                    .accessibilityAddTraits(.isButton)
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: the pictures and their tools

    /// Instagram's middle screen: the photo big (swipe between several), the tools named in a row under it, the
    /// photos small at the bottom left with a + for another, and Next at the bottom right. Each tool opens the
    /// editor on that tool, with the photo as it stands, so what's done to it adds up.
    private var hub: some View {
        VStack(spacing: 12) {
            TabView(selection: $showing) {
                ForEach(Array(shots.enumerated()), id: \.element.id) { i, shot in
                    // The size it is in the editor: the whole width, the same corners. It was set in from the sides
                    // here with "Add a song" above it taking the room, so it was smaller than in the editor a tap
                    // away and seemed to jump. Audio in the row below adds the song; once there is one it's named
                    // on the picture, as the editor names it.
                    Image(uiImage: shot.out).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .top) {
                if let song {
                    Button { choosingSong = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
                            Text(song.title).font(.footnote.weight(.bold)).lineLimit(1)
                        }
                        .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 34).background(.black.opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain).padding(.top, 12).accessibilityLabel("Song: " + song.title + ". Change it")
                }
            }
            .padding(.top, 4)
            if shots.count > 1 {
                HStack(spacing: 5) {
                    ForEach(shots.indices, id: \.self) { i in Circle().fill(Color.primary.opacity(i == showing ? 0.9 : 0.25)).frame(width: 6, height: 6) }
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    hubTool("music.note", "Audio") { choosingSong = true }
                    hubTool("textformat", "Text") { edit("text") }
                    hubTool("face.smiling", "Stickers") { edit("stickers") }
                    hubTool("scribble.variable", "Draw") { edit("draw") }
                    hubTool("camera.filters", "Filter") { edit("filters") }
                    hubTool("slider.horizontal.3", "Adjust") { edit("adjust") }
                    hubTool("crop", "Crop") { edit(nil) }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(shots.enumerated()), id: \.element.id) { i, shot in
                            Button { withAnimation(.snappy(duration: 0.2)) { showing = i } } label: {
                                Image(uiImage: shot.out).resizable().scaledToFill().frame(width: 44, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(i == showing ? Color.primary : .clear, lineWidth: 2).padding(-3))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Photo \(i + 1)")
                            .contextMenu {
                                if i > 0 { Button { move(i, to: 0) } label: { Label("Make it first", systemImage: "arrow.left.to.line") } }
                                if i > 0 { Button { move(i, to: i - 1) } label: { Label("Move left", systemImage: "arrow.left") } }
                                if i < shots.count - 1 { Button { move(i, to: i + 1) } label: { Label("Move right", systemImage: "arrow.right") } }
                                Button { editing = EditBox(image: shot.source, index: i) } label: { Label("Start again from the original", systemImage: "arrow.counterclockwise") }
                                Button(role: .destructive) { drop(i) } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                        if shots.count < 10 {
                            Button { picking = true } label: {
                                Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(.primary)
                                    .frame(width: 44, height: 56).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain).accessibilityLabel("Add another photo")
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 3)
                }
                .scrollIndicators(.hidden)
                Button { withAnimation(.snappy(duration: 0.25)) { stage = 1 } } label: {
                    HStack(spacing: 6) { Text("Next"); Image(systemName: "arrow.right") }
                        .font(.headline.weight(.heavy)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 20).frame(height: 48).background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    private func hubTool(_ symbol: String, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(height: 22)
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.primary).frame(width: 64, height: 56)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The photo showing, into the editor on one of its tools, as it stands now.
    private func edit(_ tool: String?) {
        guard shots.indices.contains(showing) else { return }
        // with how it was left when there is one (its text and stickers still to change); else the finished picture
        let shot = shots[showing]
        editing = shot.edit != nil ? EditBox(image: shot.source, index: showing, tool: tool, edit: shot.edit)
                                   : EditBox(image: shot.out, index: showing, tool: tool, whole: false)
    }

    /// A few songs to pick with one tap, under Add a song.
    private var songIdeas: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(Music.all.prefix(8))) { s in
                    Button { song = s } label: {
                        Label(s.title, systemImage: "music.note").font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            .padding(.horizontal, 12).frame(height: 34).background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden).padding(.top, 2).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 18) }
    }

    // MARK: several photos

    /// The post's photos in a row under the big one: tap one to show it, hold it to edit, move or remove it, and
    /// + to add another (up to ten).
    private var strip: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(shots.enumerated()), id: \.element.id) { i, shot in
                        Button { withAnimation(.snappy(duration: 0.2)) { showing = i } } label: {
                            Image(uiImage: shot.out).resizable().scaledToFill().frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(i == showing ? Theme.accent : .clear, lineWidth: 2.5).padding(-3.5))
                                .overlay(alignment: .bottomLeading) {
                                    if shots.count > 1 {
                                        Text("\(i + 1)").font(.caption2.weight(.heavy)).monospacedDigit().foregroundStyle(.white)
                                            .frame(width: 18, height: 18).background(.black.opacity(0.6), in: Circle()).padding(3)
                                    }
                                }
                        }
                        .buttonStyle(.plain).accessibilityLabel("Photo \(i + 1)")
                        .contextMenu {
                            Button { editing = EditBox(image: shot.source, index: i, edit: shot.edit) } label: { Label("Edit", systemImage: "crop.rotate") }
                            if i > 0 { Button { move(i, to: 0) } label: { Label("Make it first", systemImage: "arrow.left.to.line") } }
                            if i > 0 { Button { move(i, to: i - 1) } label: { Label("Move left", systemImage: "arrow.left") } }
                            if i < shots.count - 1 { Button { move(i, to: i + 1) } label: { Label("Move right", systemImage: "arrow.right") } }
                            Button(role: .destructive) { drop(i) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    if shots.count < 10 {
                        Menu {
                            Button { camera = true } label: { Label("Take a photo", systemImage: "camera") }
                            Button { picking = true } label: { Label("Choose from library", systemImage: "photo.on.rectangle") }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent)
                                .frame(width: 54, height: 54).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .menuOrder(.fixed).accessibilityLabel("Add another photo")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 5)
                .frame(minWidth: UIScreen.main.bounds.width)
            }
            .scrollIndicators(.hidden)
            if shots.count > 1 { Text("Hold a photo to move, edit or remove it.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func move(_ i: Int, to j: Int) {
        guard shots.indices.contains(i), shots.indices.contains(j) else { return }
        withAnimation(.snappy) { let s = shots.remove(at: i); shots.insert(s, at: j); showing = j }
    }
    private func drop(_ i: Int) {
        guard shots.indices.contains(i) else { return }
        withAnimation(.snappy) { shots.remove(at: i); showing = min(showing, max(0, shots.count - 1)) }
    }

    // MARK: the picture

    /// The post's picture, tall and centred, in the feed's 4:5: the photo or video; without one, what's attached
    /// drawn as a card; with neither, Camera and Library to add one. Once there's something in it, a small button
    /// in the corner drops a menu to edit, change or remove (the whole tile as a menu's label made iOS 26 swallow
    /// it into a blob and put the menu on top of it).
    private var picture: some View {
        Group {
            if photo != nil || movie != nil { pictureTile }
            else if let w = what {
                // no photo: what it's of, and its calories
                VStack(spacing: 2) {
                    // a workout by its name, no picture (16 Nov); food keeps its own
                    if str(w["kind"]) == "workout" {
                        Text(str(w["name"]).replacingOccurrences(of: "Workout: ", with: "").uppercased()).font(.caption2.weight(.heavy)).tracking(0.8)
                            .foregroundStyle(Theme.accent).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 6).padding(.bottom, 4)
                    } else { FoodDot(name: str(w["name"]), size: 40) }
                    Text(Fmt.int(num(w["kcal"]) ?? 0)).font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
                    Text("kcal").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                Button { picking = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 20, weight: .bold))
                        Text("Photo or video").font(.caption2.weight(.bold)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.secondarySystemGroupedBackground))
                }
                .buttonStyle(.plain)
            }
        }
            .frame(width: 96, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if photo != nil || what != nil {
                    Menu {
                        if movie == nil, shots.indices.contains(showing) { Button { editing = EditBox(image: shots[showing].source, index: showing, edit: shots[showing].edit) } label: { Label("Edit photo", systemImage: "crop.rotate") } }
                        if let movie {
                            Button { cutting = ClipBox(url: movie) } label: { Label("Edit video", systemImage: "scissors") }
                            Button { choosingCover = true } label: { Label("Choose cover", systemImage: "photo") }
                        }
                        if shots.count < 10 {
                            Button { camera = true } label: { Label(photo == nil ? "Take a photo" : movie != nil ? "Take a photo instead" : "Take another", systemImage: "camera") }
                            Button { picking = true } label: { Label(photo == nil ? "Choose from library" : movie != nil ? "Choose something else" : "Add from library", systemImage: "photo.on.rectangle") }
                        }
                        if movie != nil { Button(role: .destructive) { movie = nil; poster = nil; clip = ClipEdit() } label: { Label("Remove", systemImage: "trash") } }
                        else if !shots.isEmpty { Button(role: .destructive) { drop(showing) } label: { Label("Remove", systemImage: "trash") } }
                    } label: {
                        Image(systemName: photo == nil ? "plus" : "pencil").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(.black.opacity(0.55), in: Circle())
                            .padding(5).contentShape(Rectangle())
                    }
                    .menuOrder(.fixed)
                    .accessibilityLabel(photo == nil ? "Add a photo or video" : "Change the photo")
                }
            }
            .overlay(alignment: .topLeading) {
                if movie != nil {
                    Image(systemName: "video.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(.black.opacity(0.55), in: Circle()).padding(5)
                } else if shots.count > 1 {
                    Text("\(min(showing, shots.count - 1) + 1)/\(shots.count)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 22).background(.black.opacity(0.55), in: Capsule()).padding(5)
                }
            }
    }

    @ViewBuilder private var pictureTile: some View {
        if let movie {
            // Its cover, exactly as it will be posted: the look, the part kept and what's written on it. While its
            // song is playing here, the video itself plays in its place with its own sound, each as loud as its
            // slider says: the way to hear the two together and set one against the other before posting.
            Color.black.opacity(0.35).overlay {
                if let song, SongPlayer.shared.playing == "new:" + song.id {
                    // framed as the cover is (it filled the tile before, so the picture jumped when play was pressed)
                    PlacedClip(url: movie, edit: clip, volume: Float(clipVol))
                } else if let poster { Image(uiImage: poster).resizable().scaledToFit() } else { ProgressView() }
            }
        } else if let photo {
            // whole, in the shape picked for it (square, wide), on the tile's dark ground
            Color.black.opacity(0.35).overlay { Image(uiImage: photo).resizable().scaledToFit() }
        } else if let w = what {
            // no photo: its numbers are the picture, as the feed's card is
            VStack(alignment: .leading, spacing: 2) {
                Spacer(minLength: 0)
                Text(str(w["name"]).uppercased()).font(.caption2.weight(.heavy)).foregroundStyle(.secondary).lineLimit(2)
                Text(Fmt.int(num(w["kcal"]) ?? 0)).font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                Text(str(w["kind"]) == "workout" ? "kcal · \(Int(num(dict(w["extra"])["minutes"]) ?? 0)) min" : "kcal").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            VStack(spacing: 10) {
                Text("Add a photo or video").font(.subheadline.weight(.bold))
                Text("Optional").font(.footnote).foregroundStyle(.secondary)
                // one tap each, no menu
                VStack(spacing: 8) {
                    tileButton("camera.fill", "Camera") { camera = true }
                    tileButton("photo.on.rectangle", "Library") { picking = true }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
        }
    }

    private func addButton(_ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func tileButton(_ symbol: String, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Theme.accent).frame(width: 130, height: 40).background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: what's attached

    /// A food, meal or workout going with the post, or the two ways to add one.
    private var attachment: some View {
        VStack(spacing: 0) {
            if let w = what {
                let kind = str(w["kind"]), protein = num(dict(w["macros"])["p"])
                HStack(spacing: 12) {
                    FoodDot(name: kind == "workout" ? "Workout" : str(w["name"]), size: 26)
                        .frame(width: 30, height: 30).background((kind == "workout" ? Color.blue : Color.orange).opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(str(w["name"])).font(.body.weight(.semibold)).lineLimit(1)
                        Text(kind == "workout" ? "\(Int(num(dict(w["extra"])["minutes"]) ?? 0)) min · \(Fmt.int(num(w["kcal"]) ?? 0)) kcal"
                             : "\(Fmt.int(num(w["kcal"]) ?? 0)) kcal\(protein.map { " · \(Int($0)) g protein" } ?? "")").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button("Remove") { withAnimation(.snappy) { what = nil } }.font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            } else {
                attachRow(rowPicture("🍽️", .orange), "Food or meal") { shelf = 0; attaching = true }
                Divider().padding(.leading, 56)
                attachRow(rowPicture("🏋️", .blue), "Workout") { shelf = 2; attaching = true }
            }
        }
    }

    /// A song for the post: the way to add one, or the one picked with a play button.
    private var songRow: some View {
        VStack(spacing: 0) {
            if let s = song {
                let on = SongPlayer.shared.playing == "new:" + s.id
                HStack(spacing: 12) {
                    Button { if on { SongPlayer.shared.stop() } else { SongPlayer.shared.play(s, key: "new:" + s.id, loop: movie != nil, volume: Float(songVol)) } } label: {
                        Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.purple)
                            .frame(width: 30, height: 30).background(Color.purple.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain).accessibilityLabel(on ? "Stop the song" : "Play the song")
                    Button { writing = false; choosingSong = true } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("Song · tap to change").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button("Remove") { SongPlayer.shared.stop(); withAnimation(.snappy) { song = nil } }.font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                // which part of the song plays
                SongScrub(song: Binding(get: { song ?? s }, set: { song = $0 })) { SongPlayer.shared.play($0, key: "new:" + $0.id, loop: movie != nil, volume: Float(songVol)) }
                    .padding(.horizontal, 14).padding(.bottom, 12)
            } else {
                attachRow(rowIcon("music.note", .purple), "Song") { writing = false; choosingSong = true }
            }
        }
        .onDisappear { SongPlayer.shared.stop() }
    }

    /// The friends in the post: the way to tag some, or who's tagged.
    private var tagRow: some View {
        Button { writing = false; tagging = true } label: {
            HStack(spacing: 12) {
                rowIcon("person.crop.square", .teal)
                Text("Tag people").font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if !tags.isEmpty { Text(TagPicker.names(tags)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func attachRow<Icon: View>(_ icon: Icon, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                icon
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A row's sign: a symbol on a soft square of its own colour.
    private func rowIcon(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 30, height: 30).background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    /// The same with one of the app's own pictures (the plate, the weight-lifter).
    private func rowPicture(_ emoji: String, _ tint: Color) -> some View {
        Group {
            if let img = UIImage(named: FoodEmoji.asset(emoji)) { Image(uiImage: img).resizable().scaledToFit().padding(5) }
            else { Text(emoji).font(.system(size: 16)) }
        }
        .frame(width: 30, height: 30).background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// A video's first frame, the right way up.
    static func firstFrame(_ url: URL, at seconds: Double = 0) async -> UIImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 1440, height: 1440)
        guard let (cg, _) = try? await g.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A finished workout as a post.
    static func workoutPost(_ w: JSON) -> JSON {
        // macros as an empty list, never nothing: the posts table won't take a post without them, and a workout
        // sent with none failed with "null value in column macros"
        ["kind": "workout", "name": w["name"] ?? "", "kcal": w["kcal"] ?? 0, "macros": [:] as JSON,
         "payload": ["minutes": w["minutes"] ?? 0, "lifts": w["lifts"] ?? [Any]()] as JSON, "extra": ["minutes": w["minutes"] ?? 0] as JSON]
    }

    /// Sharing a workout with a photo (19 Nov): the photo's first edit starts with the workout's sticker on it, low
    /// down, to move, size or take off. Nothing for a post that isn't of a workout.
    private var workoutSticker: [JSON] {
        guard let w = what, str(w["kind"]) == "workout" else { return [] }
        let pay = dict(w["payload"])
        var s = StoryItem.workoutSticker(["name": w["name"] ?? "", "minutes": pay["minutes"] ?? 0, "lifts": pay["lifts"] ?? [Any]()])
        s["id"] = String(UUID().uuidString.prefix(8)).lowercased()
        s["x"] = 0.5; s["y"] = 0.8; s["scale"] = 0.75; s["rotation"] = 0.0
        return [s]
    }

    /// Several picked from the system's picker with a video among them: on to be made into one, or what failed said.
    private func loadSeveral(_ items: [PhotosPickerItem]) async {
        try? await Task.sleep(for: .milliseconds(450))   // for the picker to have gone
        let loaded: (clips: [Clip], failed: [Int]) = await MultiClipEditor.load(items)
        let got: [Clip] = loaded.clips
        let go: () -> Void = {
            if got.count > 1 { multi = ClipsBox(clips: got) } else if let only = got.first { took([], only.source) }
        }
        if loaded.failed.isEmpty { go(); return }
        importFailure = ImportFailure(total: items.count, failed: loaded.failed, retry: { Task { await loadSeveral(items) } },
                                      carryOn: got.isEmpty ? nil : go)
    }

    private func post() {
        // nothing attached: a photo or video on its own (a progress photo, say), with no numbers to show
        var row = what ?? ["kind": "photo", "name": "", "kcal": 0, "macros": [:] as JSON, "payload": [:] as JSON, "extra": [:] as JSON]
        guard what != nil || photo != nil || movie != nil else { return }
        // a video whose cover is still being made: wait for it, once (without it the post has no picture)
        if let movie, poster == nil, !triedPoster {
            triedPoster = true; busy = true
            Task { poster = await clip.still(movie); busy = false; post() }
            return
        }
        let face = movie != nil ? poster : shots.first?.out
        for k in ["macros", "payload", "extra"] where row[k] == nil || row[k] is NSNull { row[k] = [:] as JSON }
        if row["kcal"] == nil || row["kcal"] is NSNull { row["kcal"] = 0 }
        row["caption"] = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if let song {
            var x = dict(row["extra"]); x["song"] = song.tag
            if songVol < 0.995 || clipVol < 0.995 { x["mix"] = ["song": songVol, "clip": clipVol] as JSON }
            row["extra"] = x
        } else if movie != nil, clipVol < 0.995 {
            // a video turned down with no song on it: its level goes with the post all the same
            var x = dict(row["extra"]); x["mix"] = ["song": 1.0, "clip": clipVol] as JSON
            row["extra"] = x
        }
        if !tags.isEmpty { var x = dict(row["extra"]); x["tags"] = tags; row["extra"] = x }
        // a workout sticker stays something to tap on the feed (19 Nov): where it is on the picture, and its workout
        let placed = (movie != nil ? clip.kept?.items : shots.first?.edit?.kept?.items) ?? []
        let live = placed.filter { str($0["type"]) == "workout" }
        if !live.isEmpty { var x = dict(row["extra"]); x["live"] = live; row["extra"] = x }
        // the picture's shape, for the feed to show it whole (a video's is its first frame's)
        if let face { var x = dict(row["extra"]); x["aspect"] = Double(face.size.width / max(face.size.height, 1)); row["extra"] = x }
        SongPlayer.shared.stop()
        // it goes up after the sheet has closed: a line on the feed says posting, then posted
        Feed.shared.send(row, photo: face, video: movie.map { Drafts.release($0) }, filter: clip.look, range: clip.range, muted: clip.muted, crop: clip.crop,
                         overlay: clip.overlay, more: movie == nil ? shots.dropFirst().map { $0.out } : [], turns: clip.turns, placed: clip, sent: sent)
        if let draftID { Drafts.delete(draftID) }
        shared?()
        dismiss()
    }
}

/// A post on its way up, at the top of the feed and your profile: its picture, "Posting…" with a spinner, then
/// "Posted" for a moment; if it didn't go, why, with Try again and a way to drop it.
struct PostingBanner: View {
    private var feed: Feed { Feed.shared }
    var body: some View {
        if let s = feed.sending {
            HStack(spacing: 12) {
                // its picture, when it has one; without, nothing (a fork and knife stood in, for a workout too, 16 Nov)
                if let t = s.thumb {
                    Image(uiImage: t).resizable().scaledToFill()
                        .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                switch s.state {
                case .working:
                    Text("Posting…").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    ProgressView()
                case .done:
                    Text("Posted").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.walk)
                case .failed(let why):
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Couldn't post").font(.subheadline.weight(.semibold))
                        Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button("Try again") { s.again?() }.font(.subheadline.weight(.bold)).buttonStyle(.plain).foregroundStyle(Theme.accent)
                    Button { feed.clearSending() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 28, height: 28) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// A post to take for yourself: a meal's recipe to save or have, a food to add, or a workout to do.
struct PostRecipeSheet: View {
    let post: JSON
    /// Who it's from, when it isn't a feed post (a workout in a friend's day).
    var by: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var asking = false
    private var store: Store { Store.shared }

    var body: some View {
        let kind = str(post["kind"]), m = dict(post["payload"]), macros = dict(post["macros"])
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(str(post["name"])).font(.title2.bold())
                        Text("Shared by \(by ?? Feed.shared.name(str(post["owner"])))").font(.caption).foregroundStyle(.secondary)
                        Text("\(Fmt.int(num(post["kcal"]) ?? 0)) kcal\(num(macros["p"]).map { " · P \(Int($0.rounded()))g C \(Int((num(macros["c"]) ?? 0).rounded()))g F \(Int((num(macros["f"]) ?? 0).rounded()))g" } ?? "")").font(.subheadline.weight(.semibold))
                    }
                }
                if kind == "meal" {
                    Section("Ingredients") {
                        ForEach(list(m["items"]).indices, id: \.self) { i in
                            let it = list(m["items"])[i]
                            HStack { Text(str(it["name"])); Spacer(); Text("\(num(it["grams"]).map { "\(Fmt.int($0)) g · " } ?? "")\(Fmt.int(num(it["kcal"]) ?? 0))").foregroundStyle(.secondary).monospacedDigit() }.font(.subheadline)
                        }
                    }
                    let steps = m["steps"] as? [String] ?? []
                    if !steps.isEmpty { Section("Method") { ForEach(steps.indices, id: \.self) { i in Text("\(i + 1). \(steps[i])").font(.subheadline) } } }
                    Section {
                        Button(saved ? "Saved to your meals" : "Save to my meals") { store.perform(["type": "saveMeal", "meal": copy(m)]); saved = true }.disabled(saved)
                        Button("Have a portion today") { let c = copy(m); store.add(store.mealBasis(c), kcal: num(post["kcal"]) ?? 0, meal: Meals.now); dismiss() }
                    }
                } else if kind == "workout" {
                    Section("Exercises") {
                        ForEach(list(m["lifts"]).indices, id: \.self) { i in
                            let l = list(m["lifts"])[i]
                            Text("\(str(l["exercise"])) · \(Int(num(l["sets"]) ?? 3))×\(Int(num(l["reps"]) ?? 8))\((num(l["kg"]) ?? 0) > 0 ? " @ \(Fmt.kg(num(l["kg"]) ?? 0)) kg" : "")").font(.subheadline)
                        }
                    }
                    let exercises = list(m["lifts"]).map { ["exercise": $0["exercise"] ?? "", "sets": $0["sets"] ?? 3, "reps": $0["reps"] ?? 8, "kg": $0["kg"] ?? 0] as JSON }
                    Section {
                        Button("Start this workout") {
                            store.startSession(["name": post["name"] ?? "", "exercises": exercises])
                            dismiss()
                        }
                        .disabled(store.session != nil || exercises.isEmpty)
                        Button(saved ? "Saved to your routines" : "Save to my routines") { store.saveRoutine(name: str(post["name"]), exercises: exercises); saved = true }
                            .disabled(saved || exercises.isEmpty)
                    } footer: { if store.session != nil { Text("Finish your current session first.") } }
                } else {
                    Section {
                        Button("Add it to today") {
                            var b = m; if b.isEmpty { b = ["name": post["name"] ?? "", "kcalPerServing": post["kcal"] ?? 0, "unitLabel": "portion"] }
                            store.add(b, kcal: num(post["kcal"]) ?? 0, meal: Meals.now); dismiss()
                        }
                        Button("Make me a recipe like this") { asking = true }
                    } footer: { Text("This was shared as a food, so there's no recipe with it. The assistant can make one with about the same calories.") }
                }
            }
            .navigationTitle(kind == "workout" ? "Workout" : "Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $asking) {
                AssistantView(meal: Meals.now, firstQuestion: "Give me a recipe for \(str(post["name"])), about \(Fmt.int(num(post["kcal"]) ?? 0)) kcal a portion\(num(macros["p"]).map { " with around \(Int($0)) g protein" } ?? "").")
            }
        }
    }

    private func copy(_ m: JSON) -> JSON {
        ["id": uid(), "name": str(m["name"]).isEmpty ? str(post["name"]) : str(m["name"]), "portions": m["portions"] ?? 1,
         "items": list(m["items"]).map { it -> JSON in var c = it; c["id"] = uid(); return c }, "steps": m["steps"] ?? [Any](),
         "saved": true, "copiedFrom": "post:\(str(post["id"]))", "updatedAt": ISO.now()]
    }
}

private struct EditBox: Identifiable { let id = UUID(); let image: UIImage; var index: Int? = nil; var tool: String? = nil; var edit: ClipEdit? = nil
    /// Opened from the photo as it was picked (so what's put on it is kept apart from it), not from a finished picture.
    var whole = true }
private struct ClipBox: Identifiable { let id = UUID(); let url: URL; var first: UIImage? = nil }
/// Clips on their way into the multi-clip editor.
struct ClipsBox: Identifiable { let id = UUID(); let clips: [Clip] }

/// A post's picture. SwiftUI's AsyncImage stays blank for good if scrolling cancels its download, as a long feed does;
/// this one is kept once loaded, tries again when it comes back on screen, and retries a failed download.
struct FeedPhoto: View {
    let src: String
    var fill = false
    @State private var image: UIImage?

    init(src: String, fill: Bool = false) {
        self.src = src; self.fill = fill
        _image = State(initialValue: ImageStore.cached(src))   // one already here shows at once, with no placeholder first
    }

    var body: some View {
        Group {
            if let image {
                if fill { Image(uiImage: image).resizable().scaledToFill() } else { Image(uiImage: image).resizable().scaledToFit() }
            } else if fill { Theme.hero.shimmering() } else { Theme.hero.frame(height: 300).shimmering() }
        }
        .task(id: src) { await load() }
    }

    private func load() async {
        // The picture for this address and no other. This view is kept when what it shows changes (the next slide of a
        // story is the same view with another address), and a picture already held was left up whenever the new one
        // was here too: watched a second time, every slide of a story showed the one picture. A new address not yet
        // here shows the plain ground until it arrives, never the last picture.
        image = ImageStore.cached(src)
        if image != nil { return }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            if Task.isCancelled { return }
            if let got = await ImageStore.load(src) { image = got; return }
        }
    }
}

/// Photos kept in memory and on the phone, so profile pictures and posts show straight away, even after the app's
/// been closed (they were only kept in memory, so every launch fetched every face again).
enum ImageStore {
    private static let memory = NSCache<NSString, UIImage>()
    private static let folder: URL = {
        let f = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()
    private static func file(_ src: String) -> URL {
        // a stable name from the address (Swift's own hash changes every launch)
        var h: UInt64 = 1469598103934665603
        for b in src.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return folder.appendingPathComponent(String(h, radix: 36) + ".img")
    }

    /// A picture made on this phone and just uploaded, kept under its new address: whatever shows that address
    /// has it at once, with nothing to fetch (an edited post's photo took a while to turn up on the profile).
    static func keep(_ img: UIImage, as src: String) { if src.hasPrefix("http") { memory.setObject(img, forKey: src as NSString) } }

    // Your own posts' photos as they were before being squeezed to send, kept on this phone (the newest 150):
    // what Edit post starts from. Starting from the posted copy, an edited photo was squeezed a second time and
    // came out visibly worse; from this it's squeezed once, like a new post. Never sent anywhere.
    private static let masters: URL = {
        let f = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("masters", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()
    private static func masterFile(_ src: String) -> URL { masters.appendingPathComponent(file(src).deletingPathExtension().lastPathComponent + ".jpg") }

    static func keepMaster(_ img: UIImage, as src: String) {
        guard src.hasPrefix("http") else { return }
        let to = masterFile(src), dir = masters
        Task.detached(priority: .utility) {
            guard let d = img.jpegData(compressionQuality: 0.97) else { return }
            try? d.write(to: to, options: .atomic)
            let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            guard all.count > 150 else { return }
            let byAge = all.sorted { a, b in
                let x = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let y = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return x > y
            }
            for old in byAge.dropFirst(150) { try? FileManager.default.removeItem(at: old) }
        }
    }

    static func master(_ src: String) async -> UIImage? {
        let from = masterFile(src)
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let d = try? Data(contentsOf: from) else { return nil }
            return UIImage(data: d)
        }.value
    }

    /// Only what's in memory: for drawing straight away.
    static func cached(_ src: String) -> UIImage? { src.isEmpty ? nil : memory.object(forKey: src as NSString) }

    /// Memory, then the phone, then the internet (kept on the phone after).
    static func load(_ src: String) async -> UIImage? {
        if let m = cached(src) { return m }
        if src.hasPrefix("data:image"), let comma = src.firstIndex(of: ","), let d = Data(base64Encoded: String(src[src.index(after: comma)...])), let img = UIImage(data: d) {
            memory.setObject(img, forKey: src as NSString); return img
        }
        guard src.hasPrefix("http"), let url = URL(string: src) else { return nil }
        let path = file(src)
        if let img = await Task.detached(priority: .userInitiated, operation: { () -> UIImage? in
            guard let d = try? Data(contentsOf: path) else { return nil }
            return UIImage(data: d)?.preparingForDisplay()
        }).value {
            memory.setObject(img, forKey: src as NSString); return img
        }
        guard let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d) else { return nil }
        memory.setObject(img, forKey: src as NSString)
        Task.detached(priority: .utility) { try? d.write(to: path, options: .atomic) }
        return img
    }
}

/// A group of rows on the write-up screen: one rounded card, set in from the sides.
struct FormGroup: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
    }
}
