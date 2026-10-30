import SwiftUI

/// Everything friends did that concerns you, newest first: reactions and comments on your posts, food sent to you,
/// friend requests, and friends' new posts (workouts, meals, photos). The bell in Friends shows how many are new.
@Observable @MainActor
final class FriendActivity {
    static let shared = FriendActivity()

    struct Item: Identifiable {
        enum Kind { case reaction, comment, sent, post, request }
        let id: String
        let kind: Kind
        let who: String
        let at: Date
        let text: String
        let detail: String
        let photo: String?
        var post: String? = nil
    }

    private(set) var items: [Item] = []
    private var sample: Item?   // from Settings' test button, until Activity is opened
    private(set) var loading = false
    private var api: Supabase { Supabase.shared }
    private var seenAt: Date = (UserDefaults.standard.object(forKey: "activity.seen") as? Date) ?? .distantPast
    var seen: Date {
        get { seenAt }
        set { UserDefaults.standard.set(newValue, forKey: "activity.seen"); seenAt = newValue }
    }
    var unread: Int { items.filter { $0.at > seen }.count }

    private func rows(_ path: String) async -> [JSON] {
        guard let d = try? await api.rest(path) else { return [] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    func load() async {
        guard let me = api.userId else { return }
        loading = true; defer { loading = false }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-14 * 86400))
        async let postsQ = rows("/rest/v1/posts?select=*&created_at=gte.\(since)&order=created_at.desc&limit=60")
        async let sendsQ = rows("/rest/v1/sends?to_user=eq.\(me)&select=*&order=created_at.desc&limit=30")
        let posts = await postsQ, sends = await sendsQ
        let mine = posts.filter { str($0["owner"]) == me }
        let myIds = mine.map { str($0["id"]) }.joined(separator: ",")
        var reactions: [JSON] = [], comments: [JSON] = []
        if !myIds.isEmpty {
            async let r = rows("/rest/v1/reactions?post_id=in.(\(myIds))&select=*")
            async let c = rows("/rest/v1/comments?post_id=in.(\(myIds))&select=*&order=created_at.desc")
            reactions = await r; comments = await c
        }
        // names for everyone involved
        var names = Dictionary(uniqueKeysWithValues: Friends.shared.people.map { ($0.id, $0.name) })
        let who = Set(posts.map { str($0["owner"]) } + reactions.map { str($0["user_id"]) } + comments.map { str($0["user_id"]) } + sends.map { str($0["from_user"]) })
            .filter { !$0.isEmpty && $0 != me && names[$0] == nil }
        if !who.isEmpty {
            for p in await rows("/rest/v1/profiles?user_id=in.(\(who.joined(separator: ",")))&select=user_id,display_name") { names[str(p["user_id"])] = str(p["display_name"]) }
        }
        func name(_ id: String) -> String { names[id].flatMap { $0.isEmpty ? nil : $0 } ?? "A friend" }
        func date(_ v: Any?) -> Date { ISO.date(str(v)) ?? .distantPast }
        let postName = Dictionary(uniqueKeysWithValues: mine.map { (str($0["id"]), str($0["name"])) })
        let postAt = Dictionary(uniqueKeysWithValues: mine.map { (str($0["id"]), date($0["created_at"])) })

        var out: [Item] = []
        for r in reactions where str(r["user_id"]) != me {
            let pid = str(r["post_id"])
            out.append(Item(id: "r-\(pid)-\(str(r["user_id"]))-\(str(r["emoji"]))", kind: .reaction, who: name(str(r["user_id"])),
                            at: r["created_at"] != nil ? date(r["created_at"]) : (postAt[pid] ?? .distantPast),
                            text: "reacted \(str(r["emoji"])) to your post", detail: postName[pid] ?? "", photo: nil, post: pid))
        }
        for c in comments where str(c["user_id"]) != me {
            out.append(Item(id: "c-\(str(c["id"]))", kind: .comment, who: name(str(c["user_id"])), at: date(c["created_at"]),
                            text: "commented on \(postName[str(c["post_id"])] ?? "your post")", detail: "“\(str(c["text"]))”", photo: nil, post: str(c["post_id"])))
        }
        for s in sends {
            out.append(Item(id: "s-\(str(s["id"]))", kind: .sent, who: name(str(s["from_user"])), at: date(s["created_at"]),
                            text: "sent you \(str(s["name"]))", detail: "\(Int(num(s["kcal"]) ?? 0)) kcal\(str(s["status"]) == "new" ? " · waiting on Today" : "")", photo: nil))
        }
        for p in posts where str(p["owner"]) != me {
            let kind = str(p["kind"])
            let what = kind == "workout" ? "logged a workout" : kind == "meal" ? "shared a meal" : "had"
            let extra = dict(p["extra"])
            let detail = kind == "workout" ? "\(str(p["name"])) · \(Int(num(extra["minutes"]) ?? 0)) min" : "\(str(p["name"])) · \(Int(num(p["kcal"]) ?? 0)) kcal"
            out.append(Item(id: "p-\(str(p["id"]))", kind: .post, who: name(str(p["owner"])), at: date(p["created_at"]),
                            text: what, detail: (str(p["caption"]).isEmpty ? "" : "“\(str(p["caption"]))” · ") + detail,
                            photo: str(p["photo"]).hasPrefix("http") ? str(p["photo"]) : nil, post: str(p["id"])))
        }
        for r in Friends.shared.requests {
            out.append(Item(id: "q-\(r.id)", kind: .request, who: r.name, at: Date(), text: "wants to be friends", detail: "", photo: nil))
        }
        if let x = sample { out.append(x) }
        items = out.sorted { $0.at > $1.at }
    }

    /// A pretend item so the bell's count can be seen; gone once Activity is opened.
    func addSample() {
        let x = Item(id: "test-\(UUID().uuidString)", kind: .reaction, who: "Cheat Days", at: Date(), text: "sent a test notification",
                     detail: "This is how new activity looks. It goes once you've opened this.", photo: nil)
        sample = x
        items.insert(x, at: 0)
    }
    func clearSample() { sample = nil }
}

struct ActivityView: View {
    @Environment(\.dismiss) private var dismiss
    private var activity: FriendActivity { FriendActivity.shared }
    @State private var lastSeen = FriendActivity.shared.seen

    var body: some View {
        NavigationStack {
            List {
                if activity.items.isEmpty && !activity.loading {
                    Text("Nothing yet. Reactions, comments, food sent to you and friends' posts show up here.").foregroundStyle(.secondary)
                }
                ForEach(activity.items) { it in
                    Button { go(it) } label: { row(it) }
                        .buttonStyle(.plain)
                        .listRowBackground(it.at > lastSeen ? Theme.hero : Color(.secondarySystemGroupedBackground))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.bold) } }
            .refreshable { await activity.load() }
            .task { await activity.load(); activity.seen = Date(); activity.clearSample() }   // opening it marks everything as seen
        }
    }

    private func go(_ it: FriendActivity.Item) {
        if it.id.hasPrefix("test-") { return }
        dismiss()
        switch it.kind {
        case .sent: Nav.shared.today()
        case .request: Nav.shared.people()
        case .post, .reaction, .comment: Nav.shared.feed(post: it.post)
        }
    }

    private func row(_ it: FriendActivity.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(it.kind)).font(.subheadline.weight(.bold)).foregroundStyle(tint(it.kind))
                .frame(width: 34, height: 34).background(tint(it.kind).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                (Text(it.who).bold() + Text(" " + it.text)).font(.subheadline)
                if !it.detail.isEmpty { Text(it.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(it.at.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if !it.id.hasPrefix("test-") { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 10) }
            if let p = it.photo, let url = URL(string: p) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Theme.hero }
                    .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 3)
    }

    private func symbol(_ k: FriendActivity.Item.Kind) -> String {
        switch k { case .reaction: return "heart.fill"; case .comment: return "bubble.left.fill"; case .sent: return "paperplane.fill"; case .post: return "photo.on.rectangle"; case .request: return "person.badge.plus" }
    }
    private func tint(_ k: FriendActivity.Item.Kind) -> Color {
        switch k { case .reaction: return .pink; case .comment: return Theme.accent; case .sent: return .green; case .post: return Theme.warn; case .request: return .purple }
    }
}
