import PhotosUI
import SwiftUI

/// The friends feed: posts, reactions and comments, from the same tables as the website.
@Observable @MainActor
final class Feed {
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
            posts = try await rows("/rest/v1/posts?owner=in.(\(owners.joined(separator: ",")))&select=*&order=created_at.desc&limit=40")
            let ids = posts.map { str($0["id"]) }.joined(separator: ",")
            if !ids.isEmpty {
                async let rx = rows("/rest/v1/reactions?post_id=in.(\(ids))&select=post_id,user_id,emoji")
                async let cm = rows("/rest/v1/comments?post_id=in.(\(ids))&select=*&order=created_at.asc")
                reactions = try await rx; comments = try await cm
                // likes on comments: an empty list until the comment_likes table is set up
                let cids = comments.map { str($0["id"]) }.joined(separator: ",")
                commentLikes = cids.isEmpty ? [] : ((try? await rows("/rest/v1/comment_likes?comment_id=in.(\(cids))&select=comment_id,user_id")) ?? [])
            }
            let who = Set(posts.map { str($0["owner"]) } + comments.map { str($0["user_id"]) } + [me]).filter { !$0.isEmpty }
            await Profiles.shared.load(Array(who))
            if !who.isEmpty {
                for p in try await rows("/rest/v1/profiles?user_id=in.(\(who.joined(separator: ",")))&select=user_id,display_name") {
                    names[str(p["user_id"])] = str(p["display_name"])
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Reactions and comments for posts that aren't in the feed (Explore's), added to what's here.
    func loadExtras(_ more: [JSON]) async {
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

    func name(_ id: String) -> String {
        id == me ? "You" : ((names[id] ?? Profiles.shared.all[id]?.name ?? Friends.shared.people.first { $0.id == id }?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Someone")
    }

    func toggle(_ post: JSON, _ emoji: String) async {
        let id = str(post["id"]), mine = reactions.contains { str($0["post_id"]) == id && str($0["user_id"]) == me && str($0["emoji"]) == emoji }
        do {
            if mine {
                let e = emoji.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? emoji
                _ = try await api.rest("/rest/v1/reactions?post_id=eq.\(id)&user_id=eq.\(me)&emoji=eq.\(e)", method: "DELETE")
                reactions.removeAll { str($0["post_id"]) == id && str($0["user_id"]) == me && str($0["emoji"]) == emoji }
            } else {
                _ = try await api.rest("/rest/v1/reactions", method: "POST", body: [["post_id": post["id"] ?? id, "user_id": me, "emoji": emoji]], prefer: "resolution=ignore-duplicates")
                reactions.append(["post_id": id, "user_id": me, "emoji": emoji])
                notify(str(post["owner"]), kind: "react", text: str(post["name"]), extra: ["emoji": emoji, "post": id])
                Store.shared.perform(["type": "bump", "key": "reactCount"], syncAfter: 3)
            }
        } catch { self.error = error.localizedDescription }
    }

    /// A comment, or a reply to one (which its writer hears about too).
    func comment(_ post: JSON, _ text: String, replyTo: JSON? = nil) async {
        do {
            var row: JSON = ["post_id": post["id"] ?? "", "user_id": me, "text": text]
            if let r = replyTo { row["reply_to"] = r["id"] ?? NSNull() }
            let d = try await api.rest("/rest/v1/comments", method: "POST", body: [row], prefer: "return=representation")
            comments += (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
            notify(str(post["owner"]), kind: "comment", text: text, extra: ["post": str(post["id"])])
            if let r = replyTo, str(r["user_id"]) != str(post["owner"]) { notify(str(r["user_id"]), kind: "reply", text: text, extra: ["post": str(post["id"])]) }
            Store.shared.perform(["type": "bump", "key": "commentCount"], syncAfter: 3)
        } catch { self.error = error.localizedDescription }
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

    /// A streak, a badge or a rank up, once they've said yes to sharing it.
    func postMoment(emoji: String, title: String, detail: String, type: String) async {
        try? await post(["kind": "moment", "name": title, "kcal": 0, "macros": [:] as JSON, "payload": [:] as JSON,
                         "extra": ["emoji": emoji, "detail": detail, "type": type] as JSON], photo: nil)
    }

    func deleteComment(_ c: JSON) async {
        do { _ = try await api.rest("/rest/v1/comments?id=eq.\(str(c["id"]))&user_id=eq.\(me)", method: "DELETE"); comments.removeAll { str($0["id"]) == str(c["id"]) } }
        catch { self.error = error.localizedDescription }
    }

    func delete(_ post: JSON) async {
        do { _ = try await api.rest("/rest/v1/posts?id=eq.\(str(post["id"]))&owner=eq.\(me)", method: "DELETE"); posts.removeAll { str($0["id"]) == str(post["id"]) } }
        catch { self.error = error.localizedDescription }
    }

    func post(_ row: JSON, photo: UIImage?) async throws {
        var r = row
        r["owner"] = me
        if let photo, let jpeg = Self.prepare(photo) { r["photo"] = (try? await api.uploadPhoto(jpeg)) ?? NSNull() }
        // a workout that's already on the feed (posted when it finished): add the photo and caption to that post instead
        if str(r["kind"]) == "workout", let existing = await sameWorkout(str(r["name"])) {
            var change: JSON = [:]
            if let ph = r["photo"], !(ph is NSNull) { change["photo"] = ph }
            if !str(r["caption"]).isEmpty { change["caption"] = r["caption"] }
            if !change.isEmpty { _ = try await api.rest("/rest/v1/posts?id=eq.\(str(existing["id"]))&owner=eq.\(me)", method: "PATCH", body: change) }
            await load()
            return
        }
        _ = try await api.rest("/rest/v1/posts", method: "POST", body: [r], prefer: "return=representation")
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

    /// A post photo as edited: at most 1080 px wide, its own shape, about 150 KB.
    static func prepare(_ img: UIImage) -> Data? {
        PhotoEditor.shrink(img, to: max(img.size.width, img.size.height) * min(1, 1080 / max(1, img.size.width))).jpegData(compressionQuality: 0.75)
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
    @State private var composing = false
    @State private var recipe: JSON?
    @State private var flash: String?
    @State private var talking: PostBox?   // the post whose comments are open
    @State private var sharing: PostBox?
    @State private var picking: String?   // the post whose reactions are showing
    @State private var burst: String?   // the post a double-tap just liked
    @State private var profileOf: String?
    @State private var story: StoryStart?
    struct StoryStart: Identifiable { let id = UUID(); let people: [String]; let at: Int }
    private var feed: Feed { Feed.shared }
    private var friends: Friends { Friends.shared }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                if only == nil { rings }
                if let e = feed.error { Text(e).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 16).padding(.bottom, 8) }
                if only == nil && feed.posts.isEmpty && !feed.loading {
                    Text("Nothing in the feed yet. Share something, or add a friend.").foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(keyed((only ?? feed.posts).filter { !Profiles.shared.muted.contains(str($0["owner"])) && !Follows.shared.blocked.contains(str($0["owner"])) })) { entry in   // by post id: deleting one can't leave a row past the end
                    let pid = str(entry.item["id"])
                    postView(entry.item).id(pid)
                        .background { if flash == pid { Theme.accent.opacity(0.12).allowsHitTesting(false) } }
                }
            }
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .task(id: Nav.shared.focusPost) { await focus(proxy) }
        .onChange(of: feed.posts.count) { _, _ in Task { await focus(proxy) } }
        }
        .refreshable { if only == nil { await feed.load() } }
        .task { if only == nil && feed.posts.isEmpty { await feed.load() } }
        .overlay { if only == nil && feed.loading && feed.posts.isEmpty { ProgressView() } }
        .overlay(alignment: .bottomTrailing) {
            if only == nil {
            Button { composing = true } label: {
                Image(systemName: "plus").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .frame(width: 58, height: 58).background(Theme.accent, in: Circle()).shadow(color: .black.opacity(0.35), radius: 10, y: 5)
            }
            .buttonStyle(.plain).accessibilityLabel("New post")
            .padding(.trailing, 18).padding(.bottom, 12)   // just above the tab bar
            }
        }
        .sheet(isPresented: $composing) { ComposeSheet() }
        .sheet(item: Binding(get: { recipe.map { PostBox(post: $0) } }, set: { recipe = $0?.post })) { b in PostRecipeSheet(post: b.post) }
        .sheet(item: $talking) { b in CommentsSheet(post: b.post).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(item: $sharing) { b in SharePostSheet(post: b.post).presentationDetents([.medium, .large]) }
        .navigationDestination(item: $profileOf) { id in ProfileView(id: id) }
        .fullScreenCover(item: $story) { s in StoryView(people: s.people, at: s.at) }
    }

    // MARK: friends' days along the top

    private var rings: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                // yours: your day as friends see it, or a new post when there's nothing yet
                let mine = StoryView.has(feed.me)
                Button { if mine { story = StoryStart(people: [feed.me], at: 0) } else { composing = true } } label: {
                    ring(feed.me, "Your story", new: mine && !StoryView.seen(feed.me), tag: nil, plus: true)
                }
                .buttonStyle(.plain)
                // only friends with something today, the ones you haven't watched first
                let withStory = friends.people.filter { StoryView.has($0.id) }
                let order = withStory.filter { !StoryView.seen($0.id) } + withStory.filter { StoryView.seen($0.id) }
                ForEach(order.indices, id: \.self) { i in
                    let p = order[i]
                    Button { story = StoryStart(people: order.map(\.id), at: i) } label: {
                        ring(p.id, p.name, new: !StoryView.seen(p.id), tag: p.streak > 1 ? "\(p.streak)" : nil, plus: false)
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(p.name)'s story")
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
                Circle().fill(Theme.hero).padding(3.5)
                Avatar(id: who, size: 53)
            }
            .frame(width: 62, height: 62)
            .overlay(alignment: .bottomTrailing) {
                if plus {
                    Image(systemName: "plus").font(.system(size: 11, weight: .black)).foregroundStyle(Theme.onAccent)
                        .frame(width: 21, height: 21).background(Theme.accent, in: Circle()).overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                }
            }
            .overlay(alignment: .bottom) {
                if !plus, let tag {
                    // centred on the ring's bottom, no pill or outline: the flame and the number, with a dark glow so it reads over the ring
                    HStack(spacing: 1) { FluentIcon(emoji: "🔥", size: 13); Text(tag).font(.system(size: 12, weight: .black)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.36)) }
                        .shadow(color: Theme.bg, radius: 1.5).shadow(color: Theme.bg, radius: 3).shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                        // its middle on the ring's line, not just below it
                        .alignmentGuide(.bottom) { $0[VerticalAlignment.center] }
                        .offset(y: -2)
                        .accessibilityLabel("\(tag) day streak")
                }
            }
            Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 66)
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
        let photo = str(p["photo"]).hasPrefix("http") || str(p["photo"]).hasPrefix("data:image")
        return VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 10) {
                Button { profileOf = owner } label: {
                    HStack(spacing: 10) {
                        avatar(owner, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feed.name(owner)).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                            Text(Self.what(p) + " · " + Feed.ago(str(p["created_at"]))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
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
                        Button { Task { await Profiles.shared.report(owner, reason: "Post: \(str(p["id"]))") } } label: { Label("Report post", systemImage: "flag") }
                    }
                    if owner == feed.me { Button(role: .destructive) { Task { await feed.delete(p) } } label: { Label("Delete post", systemImage: "trash") } }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(10) }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            Group {
                if kind == "moment" { moment(p, rx: rx) }
                else if photo { photoView(p) }
                else { card(p) }
            }
            .onTapGesture(count: 2) { like(p, rx: rx) }
            .overlay {
                if burst == id {
                    Image(systemName: "heart.fill").font(.system(size: 96)).foregroundStyle(.white).shadow(radius: 12)
                        .transition(.scale(scale: 0.4).combined(with: .opacity)).allowsHitTesting(false)
                }
            }

            actions(p, rx: rx, comments: cm.count)
            if !rx.isEmpty { likedBy(rx).padding(.horizontal, 14).padding(.top, 2) }
            if !str(p["caption"]).isEmpty {
                (Text(feed.name(owner) + " ").bold() + Text(str(p["caption"]))).font(.subheadline).padding(.horizontal, 14).padding(.top, 4)
            }
            Button { talking = PostBox(post: p) } label: {
                Text(cm.isEmpty ? "Add a comment…" : cm.count == 1 ? "View 1 comment" : "View all \(cm.count) comments")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 14)
        }
    }

    /// "Lunch", "Push day", "Snack": what the post is.
    static func what(_ p: JSON) -> String {
        switch str(p["kind"]) {
        case "workout": return "Worked out"
        case "meal": return "Shared a meal"
        case "moment": return "A milestone"
        default: let m = str(dict(p["extra"])["meal"]); return m.isEmpty ? "Shared a food" : (m == "Snacks" ? "Snack" : m)
        }
    }

    private func numbers(_ p: JSON) -> (kcal: String, protein: String?) {
        let kcal = num(p["kcal"]) ?? 0, pr = num(dict(p["macros"])["p"])
        let each = str(p["kind"]) == "meal" ? " a portion" : ""
        return ("\(Fmt.int(kcal)) kcal\(each)", pr.map { "\(Int($0)) g protein" })
    }

    private func photoView(_ p: JSON) -> some View {
        let n = numbers(p)
        return FeedPhoto(src: str(p["photo"]), fill: true)
            .frame(maxWidth: .infinity).frame(height: 400).clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 8) {
                    Text(str(p["name"])).lineLimit(1)
                    Text(n.kcal).foregroundStyle(.secondary)
                    if let pr = n.protein { Text(pr).foregroundStyle(Theme.walk) }
                }
                .font(.caption.weight(.bold)).padding(.horizontal, 11).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule()).environment(\.colorScheme, .dark)
                .padding(12)
            }
    }

    /// No photo: the post as a card in the theme's colours, so the feed never looks empty.
    private func card(_ p: JSON) -> some View {
        let kind = str(p["kind"]), n = numbers(p)
        let lifts = list(dict(p["payload"])["lifts"])
        let kg = lifts.reduce(0.0) { $0 + (num($1["sets"]) ?? 0) * (num($1["reps"]) ?? 0) * (num($1["kg"]) ?? 0) }
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: kind == "workout" ? "Workout" : kind == "meal" ? "Meal" : Self.what(p), color: Theme.heroLabel)
            Text(str(p["name"])).font(.title2.weight(.heavy)).multilineTextAlignment(.leading)
            if kind == "workout" {
                HStack(spacing: 8) {
                    tile("\(Int(num(dict(p["extra"])["minutes"]) ?? 0)) min", "time")
                    tile("\(lifts.count)", lifts.count == 1 ? "exercise" : "exercises")
                    if kg > 0 { tile(Fmt.int(kg), "kg lifted") }
                }
                .padding(.top, 4)
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
                FoodDot(name: kind == "workout" ? "Workout" : str(p["name"]), size: 110).opacity(0.28).offset(x: 18, y: -14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
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
                    Text(cheered ? "🎉 Cheered" : "🎉 Cheer").font(.subheadline.weight(.heavy)).foregroundStyle(.black)
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { burst = id }
        Task { try? await Task.sleep(for: .milliseconds(750)); withAnimation(.easeOut(duration: 0.25)) { if burst == id { burst = nil } } }
    }

    private func actions(_ p: JSON, rx: [JSON], comments: Int) -> some View {
        let id = str(p["id"]), kind = str(p["kind"])
        let mine = rx.filter { str($0["user_id"]) == feed.me }.map { str($0["emoji"]) }
        let hearted = mine.contains("❤️"), other = mine.first { $0 != "❤️" && $0 != "🎉" }
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
            HStack(spacing: 18) {
                Group {
                    if let other, !hearted { Text(other).font(.system(size: 22)) }
                    else { Image(systemName: hearted ? "heart.fill" : "heart").foregroundStyle(hearted ? Color(red: 1, green: 0.3, blue: 0.4) : .primary) }
                }
                .font(.system(size: 23, weight: .medium))
                .contentShape(Rectangle())
                .onTapGesture { if picking == id { withAnimation(.snappy) { picking = nil } } else { Task { await feed.toggle(p, (hearted ? nil : other) ?? "❤️") } } }
                .onLongPressGesture(minimumDuration: 0.3) { withAnimation(.snappy) { picking = picking == id ? nil : id } }
                .sensoryFeedback(.selection, trigger: hearted)
                .accessibilityLabel(hearted ? "Unlike" : "Like").accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "More reactions") { picking = id }
                Button { talking = PostBox(post: p) } label: { Image(systemName: "bubble.right").font(.system(size: 22, weight: .medium)) }
                    .buttonStyle(.plain).accessibilityLabel(comments == 0 ? "Comment" : "\(comments) comments")
                Button { sharing = PostBox(post: p) } label: { Image(systemName: "paperplane").font(.system(size: 21, weight: .medium)) }
                    .buttonStyle(.plain).accessibilityLabel("Send to a friend")
                Spacer()
                if kind != "moment" {
                    Button { recipe = p } label: {
                        Label(kind == "workout" ? "Do it" : kind == "meal" ? "Recipe" : "Have some", systemImage: kind == "workout" ? "play.fill" : "plus")
                            .font(.subheadline.weight(.bold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 13).padding(.vertical, 7).background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        }
    }

    /// Their faces, "Liked by Sam and 3 others", and the other reactions it got.
    private func likedBy(_ rx: [JSON]) -> some View {
        var people: [String] = []
        for r in rx { let u = str(r["user_id"]); if !people.contains(u) { people.append(u) } }
        let first = people.first { $0 != feed.me } ?? people[0]
        let others = people.count - 1
        var emojis: [String] = []
        for r in rx { let e = str(r["emoji"]); if !emojis.contains(e) { emojis.append(e) } }
        return HStack(spacing: 6) {
            HStack(spacing: -7) { ForEach(people.prefix(3), id: \.self) { u in avatar(u, size: 20).overlay(Circle().stroke(Theme.bg, lineWidth: 2)) } }
            (Text("Liked by ") + Text(feed.name(first)).bold() + Text(others > 0 ? " and " : "") + Text(others > 0 ? "\(others) other\(others == 1 ? "" : "s")" : "").bold())
                .font(.subheadline).lineLimit(1)
            Text(emojis.prefix(4).joined()).font(.caption)
        }
    }

    private func avatar(_ id: String, size: CGFloat) -> some View { Avatar(id: id, size: size) }
}

/// A badge just earned: "Share it with your friends?" Moments only go on the feed when they say yes.
struct MomentAsk: ViewModifier {
    @Binding var badge: Badge?
    func body(content: Content) -> some View {
        content.alert("Share it with your friends?", isPresented: Binding(get: { badge != nil }, set: { if !$0 { badge = nil } }), presenting: badge) { b in
            Button("Share") { Task { await Feed.shared.postMoment(emoji: b.icon, title: "Earned \(b.name)", detail: b.how, type: "badge") } }
            Button("Not now", role: .cancel) {}
        } message: { b in Text("\(b.icon) \(b.name): \(b.how). It goes on the feed for friends to cheer.") }
    }
}

struct PostBox: Identifiable { let post: JSON; var id: String { str(post["id"]) } }

/// A post's comments: likes and replies, one-tap quick replies, and the box at the bottom.
struct CommentsSheet: View {
    let post: JSON
    @State private var text = ""
    @State private var replying: JSON?
    @FocusState private var typing: Bool
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
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Self.quick, id: \.self) { q in
                                Button { send(q) } label: { Text(q).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7).background(Color(.tertiarySystemFill), in: Capsule()) }
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
            .navigationTitle("Comments").navigationBarTitleDisplayMode(.inline)
            .onAppear { KeyboardDone.quiet = true }
            .onDisappear { KeyboardDone.quiet = false }
        }
    }

    private func row(_ c: JSON, reply: Bool) -> some View {
        let cid = str(c["id"]), who = str(c["user_id"])
        let likes = feed.commentLikes.filter { str($0["comment_id"]) == cid }
        let liked = likes.contains { str($0["user_id"]) == feed.me }
        return HStack(alignment: .top, spacing: 10) {
            Avatar(id: who, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                (Text(feed.name(who) + " ").bold() + Text(str(c["text"]))).font(.subheadline)
                HStack(spacing: 14) {
                    Text(Feed.ago(str(c["created_at"])))
                    if !likes.isEmpty { Text(likes.count == 1 ? "1 like" : "\(likes.count) likes") }
                    Button("Reply") { replying = reply ? (feed.comments.first { str($0["id"]) == str(c["reply_to"]) } ?? c) : c; typing = true }.buttonStyle(.plain).fontWeight(.semibold)
                    if who == feed.me { Button("Delete") { Task { await feed.deleteComment(c) } }.buttonStyle(.plain) }
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
    @State private var note = ""
    @State private var sent: Set<String> = []
    private var feed: Feed { Feed.shared }

    var body: some View {
        NavigationStack {
            List {
                Section { TextField("Add a note (optional)", text: $note) }
                Section("Send to") {
                    if Friends.shared.people.isEmpty { Text("Add a friend first.").foregroundStyle(.secondary) }
                    ForEach(Friends.shared.people.filter { $0.id != str(post["owner"]) }) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            Button(sent.contains(p.id) ? "Sent" : "Send") {
                                sent.insert(p.id)
                                Task { await feed.share(post, to: p.id, note: note.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small).foregroundStyle(Theme.onAccent).disabled(sent.contains(p.id))
                        }
                    }
                }
                if let e = feed.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
            }
            .navigationTitle("Send \(str(post["name"]))").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}


/// Share something: one of today's foods, a saved meal or today's workout, with a caption and an optional photo.
struct ComposeSheet: View {
    var preset: JSON? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var what: JSON?
    @State private var caption = ""
    @State private var editing: EditBox?
    @State private var source: UIImage?   // the photo before editing, to edit again from
    @State private var photo: UIImage?
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
    @State private var busy = false
    @State private var problem: String?
    @State private var search = ""
    private var store: Store { Store.shared }

    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }
    /// The last 30 days, newest first: today's, then History's.
    private var days: [(date: String, items: [JSON], workouts: [JSON])] {
        let since = DayKey.shift(store.today, days: -30)
        let past = list(store.doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < store.today }
            .map { (date: str($0["date"]), items: list($0["items"]), workouts: list($0["workouts"])) }.sorted { $0.date > $1.date }
        return [(date: store.today, items: store.todayItems, workouts: store.todayWorkouts)] + past
    }
    /// Each food once, the latest time it was had.
    private var recentFoods: [JSON] {
        var seen = Set<String>(), out: [JSON] = []
        for d in days { for it in d.items.reversed() where matches(str(it["name"])) && seen.insert(str(it["name"]).lowercased()).inserted { var x = it; x["_date"] = d.date; out.append(x) } }
        return Array(out.prefix(search.isEmpty ? 25 : 60))
    }
    private var savedMeals: [JSON] {
        Array(list(store.doc["meals"]).filter { $0["saved"] as? Bool == true && matches(str($0["name"])) }.prefix(search.isEmpty ? 12 : 60))
    }
    private var recentWorkouts: [JSON] {
        var out: [JSON] = []
        for d in days { for w in d.workouts.reversed() where matches(str(w["name"])) { var x = w; x["_date"] = d.date; out.append(x) } }
        return Array(out.prefix(search.isEmpty ? 12 : 40))
    }
    private func when(_ v: Any?) -> String {
        let d = str(v)
        if d == store.today { return "today" }
        if d == DayKey.shift(store.today, days: -1) { return "yesterday" }
        return DayKey.date(d).formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        NavigationStack {
            List {
                if let w = what {
                    Section {
                        HStack { FoodDot(name: str(w["name"]), size: 34); Text(str(w["name"])).font(.headline); Spacer(); Button("Change") { what = nil }.font(.subheadline) }
                        TextField("Say something about it", text: $caption, axis: .vertical).lineLimit(2...5)
                    }
                    Section {
                        if let photo {
                            Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 320).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 14))
                            Button { editing = EditBox(image: source ?? photo) } label: { Label("Edit photo", systemImage: "crop.rotate") }.buttonStyle(.borderless)
                        }
                        HStack(spacing: 18) {
                            Button { camera = true } label: { Label(photo == nil ? "Snap a pic" : "Retake", systemImage: "camera.fill") }.buttonStyle(.borderless)
                            PhotosPicker(selection: $picked, matching: .images) { Label("Library", systemImage: "photo") }.buttonStyle(.borderless)
                            if photo != nil { Button("Remove", role: .destructive) { photo = nil }.buttonStyle(.borderless) }
                        }
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
                } else {
                    // anything from the last month, not just today: foods, meals and recipes, workouts; search to narrow it
                    let items = recentFoods, meals = savedMeals, wos = recentWorkouts
                    if !items.isEmpty {
                        Section("Foods") { ForEach(items.indices, id: \.self) { i in pickRow(str(items[i]["name"]), "\(Int(num(items[i]["kcal"]) ?? 0)) kcal · \(when(items[i]["_date"]))") { what = food(items[i]) } } }
                    }
                    if !meals.isEmpty {
                        Section("Meals and recipes") { ForEach(meals.indices, id: \.self) { i in let m = meals[i]; pickRow(str(m["name"]), "\(Fmt.int(num(store.mealBasis(m)["kcalPerServing"]) ?? 0)) kcal a portion") { what = meal(m) } } }
                    }
                    if !wos.isEmpty {
                        Section("Workouts") { ForEach(wos.indices, id: \.self) { i in pickRow(str(wos[i]["name"]), "\(Int(num(wos[i]["minutes"]) ?? 0)) min · \(when(wos[i]["_date"]))") { what = workout(wos[i]) } } }
                    }
                    if items.isEmpty && meals.isEmpty && wos.isEmpty {
                        Text(search.isEmpty ? "Log a food, save a meal or finish a workout, then share it here." : "Nothing called that.").foregroundStyle(.secondary)
                    }
                }
            }
            .keyboardDone()
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods, meals and workouts")
            .onAppear { if what == nil, let preset { what = preset } }
            .navigationTitle(what == nil ? "What are you sharing?" : "New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if what != nil { ToolbarItem(placement: .topBarTrailing) { Button(busy ? "Posting…" : "Post") { post() }.fontWeight(.bold).disabled(busy) } }
            }
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = EditBox(image: img) } } }.ignoresSafeArea() }
            .onChange(of: picked) { _, item in Task { if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { editing = EditBox(image: img) } } }
            .fullScreenCover(item: $editing) { e in PhotoEditor(image: e.image) { photo = $0; source = e.image } }
        }
    }

    private func pickRow(_ name: String, _ detail: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                FoodDot(name: name, size: 30)
                VStack(alignment: .leading, spacing: 1) { Text(name).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }

    private func food(_ it: JSON) -> JSON {
        let m = store.macros([it]), k = num(it["kcal"]) ?? 0
        return ["kind": "food", "name": it["name"] ?? "", "kcal": Int(k), "macros": ["p": Int(m.p), "c": Int(m.c), "f": Int(m.f)] as JSON,
                "payload": FoodMath.basisOf(it), "extra": ["grams": it["grams"] ?? NSNull(), "unit": it["unit"] ?? "g", "meal": Meals.of(it)] as JSON]
    }
    private func meal(_ m: JSON) -> JSON {
        let b = store.mealBasis(m), n = num(m["portions"]) ?? 1
        return ["kind": "meal", "name": m["name"] ?? "", "kcal": Int((num(b["kcalPerServing"]) ?? 0).rounded()),
                "macros": ["p": Int(num(b["pServ"]) ?? 0), "c": Int(num(b["cServ"]) ?? 0), "f": Int(num(b["fServ"]) ?? 0)] as JSON,
                "payload": ["name": m["name"] ?? "", "portions": n, "items": m["items"] ?? [Any](), "steps": m["steps"] ?? [Any]()] as JSON, "extra": ["portions": n] as JSON]
    }
    private func workout(_ w: JSON) -> JSON { Self.workoutPost(w) }

    /// A finished workout as a post.
    static func workoutPost(_ w: JSON) -> JSON {
        ["kind": "workout", "name": w["name"] ?? "", "kcal": w["kcal"] ?? 0, "macros": NSNull(),
         "payload": ["minutes": w["minutes"] ?? 0, "lifts": w["lifts"] ?? [Any]()] as JSON, "extra": ["minutes": w["minutes"] ?? 0] as JSON]
    }

    private func post() {
        guard var row = what else { return }
        row["caption"] = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; problem = nil
        Task {
            defer { busy = false }
            do { try await Feed.shared.post(row, photo: photo); dismiss() }
            catch { problem = "Couldn't post: \(error.localizedDescription)" }
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
                        Text("\(Fmt.int(num(post["kcal"]) ?? 0)) kcal\(num(macros["p"]).map { " · P \(Int($0))g C \(Int(num(macros["c"]) ?? 0))g F \(Int(num(macros["f"]) ?? 0))g" } ?? "")").font(.subheadline.weight(.semibold))
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

private struct EditBox: Identifiable { let id = UUID(); let image: UIImage }

/// A post's picture. SwiftUI's AsyncImage stays blank for good if scrolling cancels its download, as a long feed does;
/// this one is kept once loaded, tries again when it comes back on screen, and retries a failed download.
struct FeedPhoto: View {
    let src: String
    var fill = false
    @State private var image: UIImage?
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if let image {
                if fill { Image(uiImage: image).resizable().scaledToFill() } else { Image(uiImage: image).resizable().scaledToFit() }
            } else if fill { Theme.hero } else { Theme.hero.frame(height: 300) }
        }
        .task(id: src) { await load() }
    }

    private func load() async {
        if let kept = Self.cache.object(forKey: src as NSString) { image = kept; return }
        guard let url = URL(string: src) else { return }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            if Task.isCancelled { return }
            if let (data, _) = try? await URLSession.shared.data(from: url), let got = UIImage(data: data) {
                Self.cache.setObject(got, forKey: src as NSString)
                image = got
                return
            }
        }
    }
}
