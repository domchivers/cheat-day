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
        var user: String? = nil   // whose it is: their photo on the row, and Follow back
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
    var unread: Int { items.filter { $0.at > seen }.count + Follows.shared.requests.count }

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
        await Follows.shared.load()
        async let sharesQ = rows("/rest/v1/post_shares?to_user=eq.\(me)&select=*&order=created_at.desc&limit=30")   // empty until set up
        let posts = await postsQ, sends = await sendsQ, shares = await sharesQ
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
        let who = Set(posts.map { str($0["owner"]) } + reactions.map { str($0["user_id"]) } + comments.map { str($0["user_id"]) } + sends.map { str($0["from_user"]) } + shares.map { str($0["from_user"]) } + Follows.shared.ofMe.map { str($0["follower"]) })
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
                            text: "reacted \(str(r["emoji"])) to your post", detail: postName[pid] ?? "", photo: nil, post: pid, user: str(r["user_id"])))
        }
        for c in comments where str(c["user_id"]) != me {
            out.append(Item(id: "c-\(str(c["id"]))", kind: .comment, who: name(str(c["user_id"])), at: date(c["created_at"]),
                            text: "commented on \(postName[str(c["post_id"])] ?? "your post")", detail: "“\(str(c["text"]))”", photo: nil, post: str(c["post_id"]), user: str(c["user_id"])))
        }
        for s in sends {
            out.append(Item(id: "s-\(str(s["id"]))", kind: .sent, who: name(str(s["from_user"])), at: date(s["created_at"]),
                            text: "sent you \(str(s["name"]))", detail: "\(Int(num(s["kcal"]) ?? 0)) kcal\(str(s["status"]) == "new" ? " · waiting on Today" : "")", photo: nil, user: str(s["from_user"])))
        }
        for s in shares {
            let pid = str(s["post_id"]), p = posts.first { str($0["id"]) == pid }
            out.append(Item(id: "f-\(str(s["id"]))", kind: .post, who: name(str(s["from_user"])), at: date(s["created_at"]),
                            text: "sent you a post", detail: str(s["note"]).isEmpty ? str(p?["name"]) : "“\(str(s["note"]))”",
                            photo: p.map(Feed.hasPhoto) == true ? str(p?["photo"]) : nil, post: pid, user: str(s["from_user"])))
        }
        let close = Set(Friends.shared.people.map(\.id) + Follows.shared.following)   // not every public post there is
        for f in Follows.shared.followers {
            out.append(Item(id: "fo-\(str(f["follower"]))", kind: .request, who: name(str(f["follower"])), at: date(f["created_at"]), text: "started following you", detail: "", photo: nil, user: str(f["follower"])))
        }
        for p in posts where str(p["owner"]) != me && close.contains(str(p["owner"])) {
            let kind = str(p["kind"])
            let what = kind == "workout" ? "logged a workout" : kind == "meal" ? "shared a meal" : kind == "moment" ? "hit a milestone" : kind == "photo" ? "shared a photo" : "had"
            let extra = dict(p["extra"])
            let detail = kind == "workout" ? "\(str(p["name"])) · \(Int(num(extra["minutes"]) ?? 0)) min"
                : kind == "moment" ? str(p["name"]) : kind == "photo" ? str(p["caption"]) : "\(str(p["name"])) · \(Int(num(p["kcal"]) ?? 0)) kcal"
            out.append(Item(id: "p-\(str(p["id"]))", kind: .post, who: name(str(p["owner"])), at: date(p["created_at"]),
                            text: what, detail: (str(p["caption"]).isEmpty ? "" : "“\(str(p["caption"]))” · ") + detail,
                            photo: Feed.hasPhoto(p) ? str(p["photo"]) : nil, post: str(p["id"]), user: str(p["owner"])))
        }
        for r in Friends.shared.requests {
            out.append(Item(id: "q-\(r.id)", kind: .request, who: r.name, at: Date(), text: "wants to be friends", detail: "", photo: nil, user: r.from))
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
    private var follows: Follows { Follows.shared }
    @State private var lastSeen = FriendActivity.shared.seen
    @State private var tab: Tab = .all
    @State private var profileOf: String?

    /// Tabs along the top (18 Nov), so a busy Activity can be read a kind at a time.
    enum Tab: String, CaseIterable { case all = "All", follows = "Follows", likes = "Likes", comments = "Comments", sent = "Sent to you", posts = "Friends' posts" }

    /// A row: a follow request (Accept and ✕) or anything else that happened.
    enum Entry: Identifiable {
        case ask(String, Date)
        case item(FriendActivity.Item)
        var id: String {
            switch self { case .ask(let who, _): return "ask-" + who; case .item(let it): return it.id }
        }
        var at: Date {
            switch self { case .ask(_, let at): return at; case .item(let it): return it.at }
        }
    }

    private func tabOf(_ it: FriendActivity.Item) -> Tab {
        switch it.kind {
        case .reaction: return .likes
        case .comment: return .comments
        case .sent: return .sent
        case .request: return .follows
        case .post: return it.id.hasPrefix("f-") ? .sent : .posts   // a post sent to you, or a friend's own
        }
    }

    private func entries(_ t: Tab) -> [Entry] {
        var out: [Entry] = []
        if t == .all || t == .follows {
            for r in follows.requests {
                let at = ISO.date(str(r["created_at"])) ?? Date()
                out.append(.ask(str(r["follower"]), at))
            }
        }
        for it in activity.items where t == .all || tabOf(it) == t { out.append(.item(it)) }
        return out.sorted { $0.at > $1.at }
    }

    private func isNew(_ e: Entry) -> Bool {
        switch e { case .ask: return true; case .item(let it): return it.at > lastSeen }
    }

    struct DayGroup: Identifiable { let id: String; var rows: [Entry] }

    /// Today, Yesterday, This week, Earlier: in that order, only those with something in them.
    private func sections(_ list: [Entry]) -> [DayGroup] {
        let cal = Calendar.current, weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date())) ?? Date()
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            return d >= weekAgo ? "This week" : "Earlier"
        }
        var out: [DayGroup] = []
        for e in list {
            let b = bucket(e.at)
            if let i = out.firstIndex(where: { $0.id == b }) { out[i].rows.append(e) } else { out.append(DayGroup(id: b, rows: [e])) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                    // The tabs, as the list's first row (18 Nov). Above the list, and then pinned as the bar's own,
                    // they came out blank both times, the space there and the tabs not, with a blurred band over the
                    // first post. Likely (unproven): on iOS 26 the bar took their own sideways scroll view for the
                    // page's and faded it out. In the list, the list is the page's scroll view.
                    chips
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    let list = entries(tab)
                    if list.isEmpty && !activity.loading {
                        Text(tab == .all ? "Nothing yet. Reactions, comments, food sent to you and friends' posts show up here." : "Nothing here yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sections(list)) { section in
                        Section {
                            ForEach(section.rows) { e in entryRow(e) }
                        } header: {
                            Text(section.id).font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                        }
                    }
                }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationDestination(item: $profileOf) { id in ProfileView(id: id) }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.bold) } }
            .refreshable { await activity.load() }
            .task { await activity.load(); activity.seen = Date(); activity.clearSample() }   // opening it marks everything as seen
        }
    }

    /// All, then only the tabs with something in them, each with how many are new.
    private var chips: some View {
        let shown = Tab.allCases.filter { $0 == .all || !entries($0).isEmpty }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(shown, id: \.self) { t in
                    let fresh = t == .all ? 0 : entries(t).filter(isNew).count
                    Button { withAnimation(.snappy) { tab = t } } label: { chip(t.rawValue, on: tab == t, count: fresh) }
                        .buttonStyle(.plain).accessibilityIdentifier("activity-tab-" + t.rawValue)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .onChange(of: shown) { _, now in if !now.contains(tab) { tab = .all } }
    }

    private func chip(_ title: String, on: Bool, count: Int) -> some View {
        let fill: Color = on ? Theme.accent : Color(.secondarySystemGroupedBackground)
        let ink: Color = on ? Theme.onAccent : .primary
        return HStack(spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(ink)
            if count > 0 {
                Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.red, in: Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(fill, in: Capsule())
    }

    @ViewBuilder private func entryRow(_ e: Entry) -> some View {
        switch e {
        case .ask(let who, let at):
            HStack(spacing: 12) {
                NavigationLink { ProfileView(id: who) } label: {
                    HStack(spacing: 12) {
                        badged(who, kind: .request)
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(Feed.shared.name(who)).bold() + Text(" wants to follow you")).font(.subheadline)
                            Text(at.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 4)
                Button("Accept") { Task { await follows.accept(who) } }.buttonStyle(.borderedProminent).controlSize(.small).foregroundStyle(Theme.onAccent)
                Button { Task { await follows.remove(who) } } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).controlSize(.small).accessibilityLabel("Decline")
            }
            .listRowBackground(Theme.hero)
        case .item(let it):
            let back: Color = it.at > lastSeen ? Theme.hero : Color(.secondarySystemGroupedBackground)
            if it.id.hasPrefix("fo-") {
                // Follow back is its own button: the row isn't one, so a tap on it can't also open the profile
                row(it).contentShape(Rectangle())
                    .onTapGesture { if let u = it.user, !u.isEmpty { profileOf = u } }
                    .listRowBackground(back)
            } else {
                Button { go(it) } label: { row(it) }
                    .buttonStyle(.plain)
                    .listRowBackground(back)
            }
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

    /// Their photo with a small badge for what it was; the kind's own icon when there's no one (the test item).
    @ViewBuilder private func badged(_ user: String?, kind: FriendActivity.Item.Kind) -> some View {
        if let user, !user.isEmpty {
            Avatar(id: user, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: symbol(kind)).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 19, height: 19).background(tint(kind), in: Circle())
                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
        } else {
            Image(systemName: symbol(kind)).font(.subheadline.weight(.bold)).foregroundStyle(tint(kind))
                .frame(width: 44, height: 44).background(tint(kind).opacity(0.15), in: Circle())
        }
    }

    private func row(_ it: FriendActivity.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            badged(it.user, kind: it.kind)
            VStack(alignment: .leading, spacing: 3) {
                (Text(it.who).bold() + Text(" " + it.text)).font(.subheadline)
                if !it.detail.isEmpty { Text(it.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(it.at.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if it.id.hasPrefix("fo-"), let u = it.user, !u.isEmpty {
                followBack(u)
            } else if let p = it.photo, let url = URL(string: p) {
                FeedPhoto(src: url.absoluteString, fill: true)
                    .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8))
            } else if !it.id.hasPrefix("test-") {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    /// A new follower: follow them back from the row (Following, or Requested for a private profile, once you have).
    @ViewBuilder private func followBack(_ u: String) -> some View {
        switch follows.state(u) {
        case .none:
            Button("Follow back") { Task { await follows.follow(u) } }
                .buttonStyle(.borderedProminent).controlSize(.small).foregroundStyle(Theme.onAccent)
        case .requested:
            Text("Requested").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6).background(Color(.tertiarySystemFill), in: Capsule())
        case .following:
            Text("Following").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6).background(Color(.tertiarySystemFill), in: Capsule())
        }
    }

    private func symbol(_ k: FriendActivity.Item.Kind) -> String {
        switch k { case .reaction: return "heart.fill"; case .comment: return "bubble.left.fill"; case .sent: return "paperplane.fill"; case .post: return "photo.on.rectangle"; case .request: return "person.badge.plus" }
    }
    private func tint(_ k: FriendActivity.Item.Kind) -> Color {
        switch k { case .reaction: return .pink; case .comment: return Theme.accent; case .sent: return .green; case .post: return Theme.warn; case .request: return .purple }
    }
}

/// For the UI test: Activity as it opens from the bell, over a screen, with one test item so a tab beside All shows.
struct ActivityHarness: View {
    @State private var open = false
    var body: some View {
        Theme.bg.ignoresSafeArea()
            .onAppear { FriendActivity.shared.addSample(); open = true }
            .sheet(isPresented: $open) { ActivityView() }
    }
}
