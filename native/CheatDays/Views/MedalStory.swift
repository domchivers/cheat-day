import SwiftUI

/// A badge or a rank-up, shared as a story (17 Nov: the calm medal, chosen over posts in the feed, which filled it with
/// "Earned Shared" cards). It goes up as an ordinary photo story, the medal drawn into the picture, so older versions
/// and messages show it as it is; a "medal" thing on it tells this version to draw it live, with its opening.
enum Medal {
    /// What's on the story for a badge: its emoji, name, what it was for, and its group and XP.
    static func of(_ b: Badge) -> JSON {
        ["type": "medal", "tone": "gold", "eyebrow": "BADGE EARNED", "emoji": b.icon, "name": b.name, "how": b.how, "line": "\(b.group) · +\(b.xp) XP"]
    }
    static func of(_ r: Rank) -> JSON {
        ["type": "medal", "tone": "blue", "eyebrow": "RANKED UP", "emoji": "⭐️", "name": r.name, "how": "A new rank in Cheat Days", "line": "Level \(r.level)"]
    }
    /// The medal on a story, if it is one.
    static func on(_ st: JSON) -> JSON? { list(st["overlays"]).first { str($0["type"]) == "medal" } }

    /// Up on your story, one slide each, for friends only. False when one didn't go.
    @MainActor static func share(_ medals: [JSON]) async -> Bool {
        var ok = true
        for m in medals {
            let r = ImageRenderer(content: MedalStory(o: m, owner: Profiles.shared.me, date: Date(), play: false).frame(width: 360, height: 640))
            r.scale = 3
            guard let img = r.uiImage, await Stories.shared.post(image: img, video: nil, overlays: [m], audience: "friends") else { ok = false; continue }
        }
        return ok
    }

    /// Badges and ranks put on the feed before they went in stories: your own from the last two days go on your story
    /// instead and come off the feed, once.
    @MainActor static func carryOver() async {
        let key = "medals.carried"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let me = Profiles.shared.me
        guard !me.isEmpty else { return }
        let since = Date().addingTimeInterval(-2 * 86400)
        let mine = Feed.shared.posts.filter { str($0["owner"]) == me && str($0["kind"]) == "moment" && (ISO.date(str($0["created_at"])) ?? .distantPast) > since }
            .sorted { str($0["created_at"]) < str($1["created_at"]) }
        UserDefaults.standard.set(true, forKey: key)
        guard !mine.isEmpty else { return }
        let medals: [JSON] = mine.map { p in
            let x = dict(p["extra"]), title = str(p["name"])
            if str(x["type"]) == "rank" {
                return ["type": "medal", "tone": "blue", "eyebrow": "RANKED UP", "emoji": "⭐️", "name": title.replacingOccurrences(of: "Ranked up to ", with: ""), "how": "A new rank in Cheat Days", "line": ""]
            }
            let name = title.replacingOccurrences(of: "Earned ", with: "")
            if let b = Badge.all.first(where: { $0.name == name }) { return of(b) }
            return ["type": "medal", "tone": "gold", "eyebrow": "BADGE EARNED", "emoji": str(x["emoji"]).isEmpty ? "🏆" : str(x["emoji"]), "name": name, "how": str(x["detail"]), "line": ""]
        }
        if await share(medals) { for p in mine { await Feed.shared.delete(p) } }
        else { UserDefaults.standard.set(false, forKey: key) }   // try again next time
    }
}

/// The medal story itself: a soft glow, the emoji in a medal, its name, what it was for, its group and XP.
/// Playing, it opens as the mockup did: the medal settles in with one small overshoot and one shine, and the
/// words fade up under it. Not playing (the picture, a slide beside), it's drawn as it ends.
struct MedalStory: View {
    let o: JSON
    var owner: String
    var date: Date?
    var play: Bool
    @State private var shown = false
    @State private var shine = false

    private var blue: Bool { str(o["tone"]) == "blue" }
    private var c: Color { blue ? Color(red: 0.35, green: 0.66, blue: 1) : Color(red: 0.96, green: 0.64, blue: 0.29) }
    private var c2: Color { blue ? Color(red: 0.66, green: 0.84, blue: 1) : Color(red: 1, green: 0.82, blue: 0.48) }
    private var deep: Color { blue ? Color(red: 0.11, green: 0.31, blue: 0.56) : Color(red: 0.54, green: 0.32, blue: 0.07) }
    private var on: Bool { shown || !play }

    var body: some View {
        GeometryReader { g in
            let u = g.size.width / 300   // laid out on a 300-wide story, as in the mockup
            ZStack {
                RadialGradient(colors: [blue ? Color(red: 0.09, green: 0.17, blue: 0.29) : Color(red: 0.16, green: 0.13, blue: 0.09),
                                        Color(red: 0.06, green: 0.06, blue: 0.07), Color(red: 0.03, green: 0.035, blue: 0.05)],
                               center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0, endRadius: g.size.height * 0.62)
                VStack(spacing: 0) {
                    Text(str(o["eyebrow"])).font(.system(size: 11 * u, weight: .heavy, design: .rounded)).tracking(2.2 * u).foregroundStyle(c2)
                        .padding(.top, 92 * u)
                    medal(u).padding(.top, 24 * u)
                        .scaleEffect(on ? 1 : 0.7).opacity(on ? 1 : 0)
                    Text(str(o["name"])).font(.system(size: 27 * u, weight: .black, design: .rounded)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(.top, 22 * u)
                        .opacity(on ? 1 : 0).offset(y: on ? 0 : 12 * u)
                    Text(str(o["how"])).font(.system(size: 14.5 * u, weight: .medium, design: .rounded)).foregroundStyle(Color(white: 0.8))
                        .multilineTextAlignment(.center).padding(.top, 7 * u)
                        .opacity(on ? 1 : 0).offset(y: on ? 0 : 12 * u)
                    if !str(o["line"]).isEmpty {
                        Text(str(o["line"])).font(.system(size: 13 * u, weight: .bold, design: .rounded)).foregroundStyle(c2).padding(.top, 12 * u)
                            .opacity(on ? 1 : 0).offset(y: on ? 0 : 12 * u)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8 * u) {
                        Avatar(id: owner, size: 22 * u)
                        Text([Feed.shared.name(owner), date?.formatted(.dateTime.day().month(.abbreviated)) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                    .font(.system(size: 12.5 * u, weight: .medium, design: .rounded)).foregroundStyle(Color(white: 0.7))
                    .padding(.bottom, 74 * u).opacity(on ? 1 : 0)
                }
                .padding(.horizontal, 22 * u)
            }
        }
        .onAppear {
            guard play else { return }
            withAnimation(.spring(duration: 0.55, bounce: 0.25).delay(0.1)) { shown = true }
            withAnimation(.easeInOut(duration: 0.8).delay(0.6)) { shine = true }
        }
    }

    private func medal(_ u: CGFloat) -> some View {
        let d = 136 * u
        return ZStack {
            Circle().fill(AngularGradient(colors: [c2, c, deep, c, c2, .white, c2], center: .center, angle: .degrees(210)))
            Circle().fill(RadialGradient(colors: [Color(red: 0.23, green: 0.25, blue: 0.31), Color(red: 0.09, green: 0.1, blue: 0.14)],
                                         center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: d * 0.5))
                .padding(12 * u)
            FluentIcon(emoji: str(o["emoji"]).isEmpty ? "🏆" : str(o["emoji"]), size: 74 * u).shadow(color: .black.opacity(0.5), radius: 6 * u, y: 4 * u)
            // one shine across it as it lands
            if play {
                LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: d * 0.4).rotationEffect(.degrees(25)).offset(x: shine ? d : -d)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: d, height: d).clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.06), lineWidth: 4 * u).padding(-4 * u))
        .shadow(color: c.opacity(0.22), radius: 18 * u, y: 16 * u)
    }
}

/// A badge just earned: "Add it to your story?", showing the story it'll make. Nothing goes up unless they say yes.
struct MomentAsk: ViewModifier {
    @Binding var badge: Badge?
    func body(content: Content) -> some View {
        content.sheet(item: $badge) { b in MedalAsk(medal: Medal.of(b)) { badge = nil } }
    }
}

/// Add this badge or rank to your story, or not now.
struct MedalAsk: View {
    let medal: JSON
    var done: () -> Void
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 14) {
            MedalStory(o: medal, owner: Profiles.shared.me, date: Date(), play: true)
                .frame(width: 128, height: 228).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 26)
            Text("\(str(medal["eyebrow"]).capitalized): \(str(medal["name"]))").font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text(failed ? "Couldn't add it. Check your connection and try again." : "Add it to your story? Friends can cheer it for a day.")
                .font(.subheadline).foregroundStyle(failed ? Theme.warn : .secondary).multilineTextAlignment(.center)
            Button {
                busy = true
                Task {
                    if await Medal.share([medal]) { UINotificationFeedbackGenerator().notificationOccurred(.success); done() }
                    else { failed = true; busy = false }
                }
            } label: {
                Text(busy ? "Adding…" : "Add to my story").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 16)).foregroundStyle(.black).disabled(busy)
            Button("Not now") { done() }.font(.subheadline.weight(.semibold)).padding(.bottom, 8).disabled(busy)
        }
        .padding(.horizontal, 22)
        .presentationDetents([.height(520)])
        .presentationDragIndicator(.visible)
    }
}
