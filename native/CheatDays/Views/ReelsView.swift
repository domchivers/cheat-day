import AVFoundation
import SwiftUI

/// Which video the viewer opens on.
struct ReelStart: Identifiable { let id: String }

/// Videos full screen, one to a page: swipe up for the next. The clip fills the screen and plays with its sound;
/// who posted it, its song, caption and food are at the bottom left, like, comment and send down the right, and a
/// comment bar along the bottom. A tap pauses it and clears all of that away, leaving play and sound in the middle;
/// a double tap likes it.
struct ReelsView: View {
    let posts: [JSON]
    @Environment(\.dismiss) private var dismiss
    @State private var current: String?
    @State private var paused = false
    @State private var muted = false
    // Two fingers on the video: it zooms while they're on it and goes back when they lift. Pinching it bigger also
    // clears everything off the screen (just the video); pinching smaller, or the button at the bottom right,
    // brings it all back.
    @GestureState private var pinch: CGFloat = 1
    @State private var clean = false
    @State private var talking: PostBox?
    @State private var sharing: PostBox?
    @State private var recipe: PostBox?
    @State private var rewording: PostBox?   // your own video, being edited
    @State private var burst: String?
    private var feed: Feed { Feed.shared }

    init(posts: [JSON], startAt: String) {
        self.posts = posts.filter { Feed.video($0) != nil }
        _current = State(initialValue: startAt)
    }

    var body: some View {
        let ids = posts.map { str($0["id"]) }
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    if let p = posts.first(where: { str($0["id"]) == id }) {
                        page(p).containerRelativeFrame([.horizontal, .vertical])
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: current) { _, _ in paused = false; sound() }
        .onChange(of: paused) { _, _ in sound() }
        .onChange(of: muted) { _, _ in sound() }
        .onAppear {
            // a video they opened plays with its sound, the ringer off or not
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            sound()
        }
        .onDisappear {
            SongPlayer.shared.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
        }
        .sheet(item: $talking) { b in CommentsSheet(post: b.post).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(item: $sharing) { b in SharePostSheet(post: b.post).presentationDetents([.medium, .large]) }
        .sheet(item: $recipe) { b in PostRecipeSheet(post: b.post) }
        .sheet(item: $rewording) { b in EditPostSheet(post: b.post) }
    }

    /// The video showing has a song: it plays, by itself, for as long as the video's showing and not paused or
    /// silenced (the clip's own sound is off under it). One without a song is heard with its own sound.
    private func sound() {
        if let id = current, let p = posts.first(where: { str($0["id"]) == id }), let s = Music.of(p), !paused, !muted {
            if SongPlayer.shared.playing != "reel:" + id { SongPlayer.shared.play(s, key: "reel:" + id, loop: true) }
        } else {
            SongPlayer.shared.stop()
            // stopping a song hands the sound back to the ringer; here a video is still to be heard
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    private func page(_ p: JSON) -> some View {
        let id = str(p["id"]), on = current == id
        let rx = feed.reactions.filter { str($0["post_id"]) == id }
        return ZStack {
            Color.black
            Group {
            // only the page on screen plays; its neighbours wait as their first frame
            if on, let v = Feed.video(p) {
                // a tall clip fills the screen; a squarer one is shown whole in the middle
                if let a = num(dict(p["extra"])["aspect"]), a > 0.62 {
                    LoopingVideo(url: v, paused: paused, muted: muted || Music.of(p) != nil).aspectRatio(a, contentMode: .fit).allowsHitTesting(false)
                } else {
                    LoopingVideo(url: v, paused: paused, muted: muted || Music.of(p) != nil).allowsHitTesting(false)
                }
            } else if let a = num(dict(p["extra"])["aspect"]), a > 0.62 {
                Color.clear.aspectRatio(a, contentMode: .fit).overlay { FeedPhoto(src: str(p["photo"]), fill: true) }.clipped()
            } else {
                FeedPhoto(src: str(p["photo"]), fill: true).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
            }
            .scaleEffect(on ? min(4, max(1, pinch)) : 1)
            .animation(.snappy(duration: 0.25), value: pinch == 1)
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { like(p, rx: rx) }
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { paused.toggle() } }
                .simultaneousGesture(MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in
                        if v.magnification > 1.15, !clean { UIImpactFeedbackGenerator(style: .light).impactOccurred(); withAnimation(.easeOut(duration: 0.2)) { clean = true } }
                        else if v.magnification < 0.87, clean { UIImpactFeedbackGenerator(style: .light).impactOccurred(); withAnimation(.easeOut(duration: 0.2)) { clean = false } }
                    })
                .accessibilityLabel(paused ? "Play" : "Pause").accessibilityAddTraits(.isButton)
            if on && paused { pausedButtons } else if !clean { chrome(p, rx: rx) } else { backAgain }
            if burst == id {
                Image(systemName: "heart.fill").font(.system(size: 96)).foregroundStyle(.white).shadow(radius: 12)
                    .transition(.scale(scale: 0.4).combined(with: .opacity)).allowsHitTesting(false)
            }
        }
        .clipped()
    }

    /// With everything cleared off: one faint button at the bottom right to bring it back (a pinch does too).
    private var backAgain: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.2)) { clean = false } } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .frame(width: 42, height: 42).background(.black.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Bring everything back")
            }
        }
        .padding(.trailing, 14).padding(.bottom, 40)
        .transition(.opacity)
    }

    /// Paused: just the clip, with sound and play in the middle.
    private var pausedButtons: some View {
        VStack(spacing: 14) {
            Button { muted.toggle() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 45, height: 45).background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel(muted ? "Sound on" : "Sound off")
            Button { withAnimation(.easeOut(duration: 0.15)) { paused = false } } label: {
                Image(systemName: "play.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 69, height: 69).background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Play")
        }
        .transition(.opacity)
    }

    private func like(_ p: JSON, rx: [JSON]) {
        let id = str(p["id"])
        if !rx.contains(where: { str($0["emoji"]) == "❤️" && str($0["user_id"]) == feed.me }) { Task { await feed.toggle(p, "❤️") } }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { burst = id }
        Task { try? await Task.sleep(for: .milliseconds(750)); withAnimation(.easeOut(duration: 0.25)) { if burst == id { burst = nil } } }
    }

    // MARK: what's over the clip

    private func chrome(_ p: JSON, rx: [JSON]) -> some View {
        let id = str(p["id"]), kind = str(p["kind"])
        let comments = feed.comments.filter { str($0["post_id"]) == id }.count
        let hearted = rx.contains { str($0["emoji"]) == "❤️" && str($0["user_id"]) == feed.me }
        return ZStack {
            // so the words read over a bright clip
            VStack { Spacer(); LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 320) }.allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).shadow(radius: 3)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Back")
                    Spacer()
                }
                .padding(.leading, 8).padding(.top, 54)
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    about(p)
                    Spacer(minLength: 0)
                    VStack(spacing: 18) {
                        rail(hearted ? "heart.fill" : "heart", rx.isEmpty ? "" : "\(Set(rx.map { str($0["user_id"]) }).count)", tint: hearted ? .red : .white) { Task { await feed.toggle(p, "❤️") } }
                            .accessibilityLabel(hearted ? "Unlike" : "Like")
                        rail("bubble.right", comments == 0 ? "" : "\(comments)") { talking = PostBox(post: p) }.accessibilityLabel("Comments")
                        rail("paperplane", "") { sharing = PostBox(post: p) }.accessibilityLabel("Send to a friend")
                        // the same choices the post has on the feed: yours to edit or delete, someone else's to hide or report
                        Menu {
                            if str(p["owner"]) == feed.me {
                                Button { rewording = PostBox(post: p) } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { Task { await feed.delete(p) }; dismiss() } label: { Label("Delete post", systemImage: "trash") }
                            } else {
                                Button { Profiles.shared.toggleMute(str(p["owner"])); dismiss() } label: { Label("Hide posts from \(feed.name(str(p["owner"])))", systemImage: "eye.slash") }
                                Button { Task { await Profiles.shared.report(str(p["owner"]), reason: "Post: \(id)") } } label: { Label("Report post", systemImage: "flag") }
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 3).frame(width: 44, height: 34).contentShape(Rectangle())
                        }
                        .menuOrder(.fixed).accessibilityLabel("More")
                        rail("arrow.up.left.and.arrow.down.right", "") { withAnimation(.easeOut(duration: 0.2)) { clean = true } }.accessibilityLabel("Just the video")
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
                HStack(spacing: 8) {
                    Button { talking = PostBox(post: p) } label: {
                        Text("Add a comment…").font(.subheadline).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 11).background(.black.opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    if kind != "photo" && kind != "moment" {
                        Button { recipe = PostBox(post: p) } label: {
                            Label(kind == "workout" ? "Do it" : kind == "meal" ? "Recipe" : "Have some", systemImage: kind == "workout" ? "play.fill" : "plus")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 13).padding(.vertical, 10).background(Theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 30)
            }
        }
        .transition(.opacity)
    }

    private func rail(_ symbol: String, _ count: String, tint: Color = .white, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(tint)
                if !count.isEmpty { Text(count).font(.caption.weight(.bold)).foregroundStyle(.white).monospacedDigit() }
            }
            .shadow(color: .black.opacity(0.4), radius: 3).frame(width: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Who posted it (with Follow for someone you don't), its song, its caption, and the food or workout it's of.
    private func about(_ p: JSON) -> some View {
        let id = str(p["id"]), owner = str(p["owner"]), kind = str(p["kind"]), caption = feed.caption(p)
        let state = Follows.shared.state(owner)
        let stranger = owner != feed.me && !Friends.shared.people.contains { $0.id == owner } && state != .following
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Avatar(id: owner, size: 32)
                Text(feed.name(owner)).font(.subheadline.weight(.heavy)).foregroundStyle(.white).lineLimit(1)
                if stranger {
                    Button(state == .requested ? "Requested" : "Follow") {
                        Task { if state == .none { await Follows.shared.follow(owner) } else { await Follows.shared.unfollow(owner) } }
                    }
                    .font(.caption.weight(.heavy)).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(0.8), lineWidth: 1.5)).buttonStyle(.plain)
                }
            }
            if let s = Music.of(p) {
                let playing = SongPlayer.shared.playing == "reel:" + id
                Button { SongPlayer.shared.toggle(s, key: "reel:" + id) } label: {
                    Label(s.title + (playing ? " · playing" : ""), systemImage: playing ? "pause.fill" : "music.note").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            if !caption.isEmpty { Text(caption).font(.subheadline).foregroundStyle(.white).lineLimit(3).multilineTextAlignment(.leading) }
            if kind != "photo" && kind != "moment" {
                HStack(spacing: 8) {
                    Text(str(p["name"])).lineLimit(1)
                    Text(kind == "workout" ? "\(Int(num(dict(p["extra"])["minutes"]) ?? 0)) min" : "\(Fmt.int(num(p["kcal"]) ?? 0)) kcal").foregroundStyle(.white.opacity(0.75))
                    if let pr = num(dict(p["macros"])["p"]), pr > 0 { Text("\(Int(pr)) g protein").foregroundStyle(Theme.walk) }
                }
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 7).background(.black.opacity(0.45), in: Capsule())
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 3)
    }
}
