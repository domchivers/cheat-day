import SwiftUI

/// Everyone's profile: a photo, a name, an @username, a short bio, a few tags and pinned badges (never weight). Read
/// with select=* so an app ahead of the database (before profiles_messages.sql is run) still loads names.
@Observable @MainActor
final class Profiles {
    static let shared = Profiles()

    struct Profile {
        let id: String
        var name: String
        var username: String
        var avatar: String
        var bio: String
        var tags: [String]
        var pinned: [String]
        var showWeek: Bool
        var seenAt: Date?
        /// On the app in the last five minutes: the green dot.
        var online: Bool { seenAt.map { Date().timeIntervalSince($0) < 300 } ?? false }

        init(_ r: JSON) {
            id = str(r["user_id"]); name = str(r["display_name"]); username = str(r["username"]); avatar = str(r["avatar"])
            bio = str(r["bio"]); tags = r["tags"] as? [String] ?? []; pinned = r["pinned"] as? [String] ?? []
            showWeek = r["show_week"] as? Bool ?? true; seenAt = ISO.date(str(r["seen_at"]))
        }
    }

    private(set) var all: [String: Profile] = [:] { didSet { if mine?.avatar != iconFor { Task { await makeIcon() } } } }
    /// The Me tab's icon: your photo, round.
    private(set) var meIcon: UIImage?
    private var iconFor: String?
    var error: String?
    private var api: Supabase { Supabase.shared }
    var me: String { api.userId ?? "" }
    var mine: Profile? { all[me] }

    private func rows(_ path: String) async throws -> [JSON] {
        let d = try await api.rest(path)
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    /// These people's profiles (and mine), kept for the session; again when asked.
    func load(_ ids: [String], force: Bool = false) async {
        let want = Set(ids + [me]).filter { !$0.isEmpty && (force || all[$0] == nil) }
        guard !want.isEmpty else { return }
        for r in (try? await rows("/rest/v1/profiles?user_id=in.(\(want.joined(separator: ",")))&select=*")) ?? [] {
            all[str(r["user_id"])] = Profile(r)
        }
    }

    func avatar(_ id: String) -> String { all[id]?.avatar ?? "" }

    private func makeIcon() async {
        let src = mine?.avatar ?? ""
        iconFor = src
        guard src.hasPrefix("http"), let url = URL(string: src), let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d) else { meIcon = nil; return }
        let side: CGFloat = 28
        let round = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
            let s = max(side / img.size.width, side / img.size.height)
            let w = img.size.width * s, h = img.size.height * s
            img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        if iconFor == src { meIcon = round.withRenderingMode(.alwaysOriginal) }
    }
    func handle(_ id: String) -> String { all[id].map { $0.username.isEmpty ? "" : "@\($0.username)" } ?? "" }

    /// A username as typed, made valid: lower case, letters, numbers, dots and underscores, 3 to 20 long.
    static func clean(_ s: String) -> String {
        String(s.lowercased().replacingOccurrences(of: "@", with: "").filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" }.prefix(20))
    }
    func taken(_ username: String) async -> Bool {
        let u = Self.clean(username)
        guard u.count >= 3 else { return false }
        let r = (try? await rows("/rest/v1/profiles?username=eq.\(u)&select=user_id")) ?? []
        return r.contains { str($0["user_id"]) != me }
    }

    func save(_ change: JSON) async -> Bool {
        var c = change; c["updated_at"] = ISO.now()
        do {
            _ = try await api.rest("/rest/v1/profiles?user_id=eq.\(me)", method: "PATCH", body: c)
            await load([me], force: true)
            await Friends.shared.load()
            error = nil
            return true
        } catch {
            self.error = "Couldn't save: profiles need setting up (supabase/profiles_messages.sql), or that @name is taken."
            return false
        }
    }

    /// A new photo: cropped square, uploaded, and set.
    func setPhoto(_ img: UIImage) async -> Bool {
        guard let jpeg = Feed.square(img), let url = try? await api.uploadPhoto(jpeg) else { error = "Couldn't upload the photo."; return false }
        return await save(["avatar": url])
    }

    /// The green dot: when I was last on the app.
    func touch() async {
        guard !me.isEmpty else { return }
        _ = try? await api.rest("/rest/v1/profiles?user_id=eq.\(me)", method: "PATCH", body: ["seen_at": ISO.now()])
    }

    func posts(of id: String) async -> [JSON] {
        (try? await rows("/rest/v1/posts?owner=eq.\(id)&select=*&order=created_at.desc&limit=60")) ?? []
    }

    func removeFriend(_ p: Friends.Person) async {
        _ = try? await api.rest("/rest/v1/friendships?id=eq.\(p.friendship)", method: "DELETE")
        await Friends.shared.load()
    }

    func report(_ id: String, reason: String) async {
        _ = try? await api.rest("/rest/v1/reports", method: "POST", body: [["reporter": me, "reported": id, "reason": reason]])
    }

    // muted friends: their posts stay off the feed, on this phone
    private(set) var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "muted") ?? [])
    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        UserDefaults.standard.set(Array(muted), forKey: "muted")
    }
}

/// Someone's round photo, or the first letter of their name until they've added one.
struct Avatar: View {
    let id: String
    var size: CGFloat = 36
    var ring = false
    var dot = false
    private var profiles: Profiles { Profiles.shared }

    var body: some View {
        let src = profiles.avatar(id)
        ZStack {
            if src.hasPrefix("http") {
                FeedPhoto(src: src, fill: true)
            } else {
                Theme.hero
                Text(String(Self.name(id).prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .heavy)).foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay { if ring { Circle().stroke(Theme.accent, lineWidth: 2.5).padding(-4) } }
        .overlay(alignment: .bottomTrailing) {
            if dot && profiles.all[id]?.online == true {
                Circle().fill(Theme.walk).frame(width: size * 0.26, height: size * 0.26).overlay(Circle().stroke(Theme.bg, lineWidth: 2.5))
            }
        }
        .accessibilityHidden(true)
    }

    /// Their name for the letter: a friend's from Friends (they may have no posts, so Feed doesn't know them), else
    /// their profile's. The rings all showed "S", for "Someone".
    static func name(_ id: String) -> String {
        if id == Profiles.shared.me { return Friends.shared.myName.isEmpty ? "Me" : Friends.shared.myName }
        if let p = Friends.shared.people.first(where: { $0.id == id }) { return p.name }
        if let n = Profiles.shared.all[id]?.name, !n.isEmpty { return n }
        return Feed.shared.name(id)
    }
}
