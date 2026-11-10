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
        /// Private (the default): followers ask first. Friends see everything either way.
        var isPrivate: Bool
        var privacyChosen: Bool
        var friendCode: String
        /// What they call themselves, in grey under the name ("Founder of Cheat Days", "Personal trainer").
        var label: String
        /// Tags given to them (Founder, Alpha, First 100…), the one they show by their name, and whether to show them.
        var honors: [String]
        var topHonor: String
        var showHonors: Bool
        /// The tag beside their name: the one they chose, or their rarest.
        var shownHonor: Honor? {
            guard showHonors else { return nil }
            let mine = honors.compactMap(Honor.find)
            return mine.first { $0.id == topHonor } ?? mine.min { $0.rank < $1.rank }
        }
        /// On the app in the last five minutes: the green dot.
        var online: Bool { seenAt.map { Date().timeIntervalSince($0) < 300 } ?? false }

        init(_ r: JSON) {
            id = str(r["user_id"]); name = str(r["display_name"]); username = str(r["username"]); avatar = str(r["avatar"])
            bio = str(r["bio"]); tags = r["tags"] as? [String] ?? []; pinned = r["pinned"] as? [String] ?? []
            showWeek = r["show_week"] as? Bool ?? true; seenAt = ISO.date(str(r["seen_at"]))
            isPrivate = r["private"] as? Bool ?? true; privacyChosen = r["privacy_chosen"] as? Bool ?? true   // true until the column exists: don't ask
            friendCode = str(r["friend_code"])
            label = str(r["label"]); honors = r["honors"] as? [String] ?? []; topHonor = str(r["top_honor"]); showHonors = r["show_honors"] as? Bool ?? true
        }
    }

    private(set) var all: [String: Profile] = [:] {
        didSet {
            keepAvatars()
            if let a = mine?.avatar, a != iconFor { Task { await makeIcon() } }
        }
    }
    /// The Me tab's icon: your photo, round, the size of the other tab icons; with a ring in the accent colour
    /// when Me is the tab you're on (it didn't change at all before, so it looked stuck on).
    private(set) var meIcon: UIImage?
    private(set) var meIconOn: UIImage?
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
        let want = Set(ids + [me]).filter { UUID(uuidString: $0) != nil && (force || all[$0] == nil) }
        guard !want.isEmpty else { return }
        for r in (try? await rows("/rest/v1/profiles?user_id=in.(\(want.joined(separator: ",")))&select=*")) ?? [] {
            all[str(r["user_id"])] = Profile(r)
        }
    }

    /// Their photo's address, or the one kept from last time while their profile is still on its way (so the picture
    /// is there at once instead of the letter first).
    func avatar(_ id: String) -> String {
        if let a = all[id]?.avatar { return a }
        return keptAvatars[id] ?? ""
    }
    private var keptAvatars: [String: String] = UserDefaults.standard.dictionary(forKey: "avatars") as? [String: String] ?? [:]
    private func keepAvatars() {
        var k = keptAvatars
        for (id, p) in all where !p.avatar.isEmpty { k[id] = p.avatar }
        if k != keptAvatars { keptAvatars = k; UserDefaults.standard.set(k, forKey: "avatars") }
    }
    /// Profiles a search already fetched.
    func keep(_ ps: [Profile]) { for p in ps { all[p.id] = p } }

    /// The tab icon from the photo kept on the phone: there at launch, before your profile has loaded.
    func warmIcon() { if meIcon == nil, !avatar(me).isEmpty { Task { await makeIcon() } } }

    private func makeIcon() async {
        let src = mine?.avatar ?? keptAvatars[me] ?? ""
        iconFor = src
        guard src.hasPrefix("http"), let img = await ImageStore.load(src) else { meIcon = nil; meIconOn = nil; return }
        func icon(ring: Bool) -> UIImage {
            let side: CGFloat = 24.75, inset: CGFloat = ring ? 3.5 : 1.5   // a round photo reads smaller than a glyph, so a touch bigger
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
                let photo = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
                ctx.cgContext.saveGState()
                UIBezierPath(ovalIn: photo).addClip()
                let s = max(photo.width / img.size.width, photo.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: CGRect(x: photo.midX - w / 2, y: photo.midY - h / 2, width: w, height: h))
                ctx.cgContext.restoreGState()
                let edge = UIBezierPath(ovalIn: ring ? CGRect(x: 0.9, y: 0.9, width: side - 1.8, height: side - 1.8) : photo)
                edge.lineWidth = ring ? 1.8 : 0.6
                (ring ? UIColor(Theme.accent) : UIColor.white.withAlphaComponent(0.35)).setStroke()
                edge.stroke()
            }.withRenderingMode(.alwaysOriginal)
        }
        if iconFor == src { meIcon = icon(ring: false); meIconOn = icon(ring: true) }
    }
    func handle(_ id: String) -> String { all[id].map { $0.username.isEmpty ? "" : "@\($0.username)" } ?? "" }

    /// A username as typed, made valid: lower case, letters, numbers, dots and underscores, 3 to 20 long.
    static func clean(_ s: String) -> String {
        String(s.lowercased().replacingOccurrences(of: "@", with: "").filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" }.prefix(20))
    }
    /// Words an @name or name can't contain, after undoing look-alikes (0 for o, 1 for i, $ for s…) and taking out
    /// dots and underscores; and names kept back so nobody passes as the app. The same list is on the server.
    static let blocked = ["fuck", "fuk", "shit", "cunt", "nigger", "nigga", "faggot", "retard", "whore", "slut", "rapist", "nazi", "hitler", "kkk", "bitch", "pussy", "porn", "wank", "twat", "chink", "kike", "tranny", "penis", "vagina", "boob", "nude", "naked", "molest", "paedo", "pedophile", "incel", "jihad"]   // whole words that don't turn up inside foods or names ("spicy", "grape", "cucumber" are fine)
    static let reserved = ["admin", "administrator", "cheatdays", "cheatday", "mycheatdays", "support", "official", "help", "staff", "moderator", "mod", "system", "root", "owner", "team", "apple", "anthropic"]
    static func squash(_ s: String) -> String {
        let map: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "@": "a", "$": "s", "!": "i", "|": "i"]
        return String(s.lowercased().compactMap { c -> Character? in
            if let m = map[c] { return m }
            return c.isLetter ? c : nil
        })
    }
    /// Why this @name or name can't be used, or nil when it's fine.
    static func problem(_ s: String, username: Bool) -> String? {
        let t = squash(s)
        if blocked.contains(where: { t.contains($0) }) { return username ? "That @name isn't allowed. Try another." : "That name isn't allowed. Try another." }
        if username, reserved.contains(t) { return "That @name is kept for the app. Try another." }
        return nil
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

    /// The whole photo behind your round one, kept on this phone so Move photo can reframe it later.
    static var original: UIImage? {
        get { (try? Data(contentsOf: originalURL)).flatMap(UIImage.init(data:)) }
        set { if let d = newValue.flatMap({ Feed.prepare($0) }) { try? d.write(to: originalURL) } }
    }
    private static var originalURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("avatar-original.jpg") }

    /// The green dot: when I was last on the app.
    func touch() async {
        guard !me.isEmpty else { return }
        _ = try? await api.rest("/rest/v1/profiles?user_id=eq.\(me)", method: "PATCH", body: ["seen_at": ISO.now()])
    }

    /// Their posts, or nil when it couldn't load (so what's showing stays). Run outside the caller's task: pull to
    /// refresh cancels its own, and a cancelled request came back as no posts at all.
    func posts(of id: String) async -> [JSON]? {
        await Task { try? await rows("/rest/v1/posts?owner=eq.\(id)&select=*&order=created_at.desc&limit=60") }.value
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

/// A tag someone's been given, never chosen: Founder, Team, Alpha, Beta, First 100, First 1,000. Coloured by how rare
/// it is; the rarest (Founder, Team, Alpha) also show small beside the name on posts and comments.
struct Honor: Identifiable {
    let id: String
    let title: String
    let icon: String
    let what: String
    let how: String
    let rarity: String
    let rank: Int          // 0 rarest
    let colors: [Color]
    let ink: Color
    var onFeed: Bool { rank <= 2 }
    /// Its colours as text on the dark screen: the darker ones (Alpha's purple, First 1,000's grey) lifted so they read.
    var shade: LinearGradient {
        let c: [Color] = switch id {
        case "alpha": [Color(red: 0.72, green: 0.52, blue: 1), Color(red: 0.86, green: 0.7, blue: 1)]
        case "first1000": [Color(red: 0.68, green: 0.72, blue: 0.8), Color(red: 0.86, green: 0.89, blue: 0.94)]
        default: colors
        }
        return LinearGradient(colors: c, startPoint: .leading, endPoint: .trailing)
    }

    static let all: [Honor] = [
        Honor(id: "founder", title: "Founder", icon: "👑", what: "Made Cheat Days", how: "Only one.", rarity: "1 of 1", rank: 0,
              colors: [Color(red: 0.97, green: 0.84, blue: 0.45), Color(red: 0.95, green: 0.7, blue: 0.24), Color(red: 1, green: 0.95, blue: 0.72), Color(red: 0.85, green: 0.59, blue: 0.16)], ink: Color(red: 0.16, green: 0.1, blue: 0)),
        Honor(id: "team", title: "Team", icon: "✦", what: "Works on Cheat Days", how: "Given by the founder.", rarity: "Rare", rank: 1,
              colors: [Color(red: 0.55, green: 0.77, blue: 1), Color(red: 0.77, green: 0.63, blue: 1)], ink: Color(red: 0.04, green: 0.05, blue: 0.07)),
        Honor(id: "alpha", title: "Alpha", icon: "🧪", what: "Tested the very first builds", how: "Before the beta. No more will be given.", rarity: "Rare", rank: 2,
              colors: [Color(red: 0.36, green: 0.16, blue: 0.53), Color(red: 0.61, green: 0.3, blue: 0.79)], ink: .white),
        Honor(id: "first100", title: "#100", icon: "💯", what: "One of the first 100 to join", how: "Counted by when the account was made.", rarity: "Rare", rank: 3,
              colors: [Color(red: 1, green: 0.6, blue: 0.55), Color(red: 1, green: 0.42, blue: 0.53), Color(red: 1, green: 0.6, blue: 0.67)], ink: Color(red: 0.16, green: 0.05, blue: 0.09)),
        Honor(id: "beta", title: "Beta", icon: "🧭", what: "Tested Cheat Days before launch", how: "Joined during the beta.", rarity: "Uncommon", rank: 4,
              colors: [Color(red: 0.36, green: 0.78, blue: 1), Color(red: 0.55, green: 0.94, blue: 0.88)], ink: Color(red: 0.02, green: 0.13, blue: 0.2)),
        Honor(id: "first1000", title: "#1000", icon: "🎖️", what: "One of the first 1,000 to join", how: "The 900 after the first 100.", rarity: "Uncommon", rank: 5,
              colors: [Color(red: 0.36, green: 0.4, blue: 0.47), Color(red: 0.54, green: 0.58, blue: 0.66)], ink: .white),
    ]
    static func find(_ id: String) -> Honor? { all.first { $0.id == id } }
}

/// A tag as a line of text in its colours, where Instagram has its grey "Artist": small spaced capitals, no pill.
struct HonorText: View {
    let honor: Honor
    var body: some View {
        Text(honor.title.uppercased()).font(.system(size: 12, weight: .heavy)).tracking(1.6)
            .foregroundStyle(honor.shade).lineLimit(1).fixedSize().accessibilityLabel(honor.title)
    }
}

/// Every tag there is, rarest first, with how it's earned; theirs marked.
struct HonorsSheet: View {
    let theirs: [String]
    let name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(Honor.all) { h in
                    HStack(spacing: 12) {
                        HonorText(honor: h).frame(width: 96, alignment: .leading)   // no icons: just the word, as on the profile
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.what).font(.subheadline.weight(.semibold))
                            Text(h.how).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if theirs.contains(h.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        else { Text(h.rarity.uppercased()).font(.caption2.weight(.heavy)).foregroundStyle(.secondary) }
                    }
                    .opacity(theirs.isEmpty || theirs.contains(h.id) ? 1 : 0.55)
                }
            }
            .contentMargins(.top, 4, for: .scrollContent)   // the list starts just under the title
            .navigationTitle(name.isEmpty ? "Tags" : "\(name)'s tags").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
