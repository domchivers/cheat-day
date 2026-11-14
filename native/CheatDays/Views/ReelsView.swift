import AVFoundation
import Photos
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
    @State private var reportOf: ReportTarget?
    @State private var current: String?
    @State private var paused = false
    @State private var muted = false
    // Two fingers on the video: it zooms while they're on it and goes back when they lift. Pinching it bigger also
    // clears everything off the screen (just the video); pinching smaller, or the button at the bottom right,
    // brings it all back.
    // how far through the video showing is (kept apart so that only the line along the bottom redraws as it moves),
    // and the moment a finger on that line is holding it at
    @State private var head = Playhead()
    @State private var holding: Double?
    @State private var lastTap = Date.distantPast
    @State private var pausedBefore = false
    @GestureState private var pinch: CGFloat = 1
    @State private var clean = false
    @State private var talking: PostBox?
    @State private var songShown: SongShown?
    @State private var deleting: PostBox?
    @State private var slide: CGFloat = 0   // carried to the right by a finger, on the way back out
    struct SongShown: Identifiable { let song: Song; let key: String; var id: String { key } }
    @State private var sharing: PostBox?
    @State private var recipe: PostBox?
    @State private var rewording: PostBox?   // your own video, being edited
    @State private var note: String?   // "Saved to Photos", for a moment
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
        // no blurred band under the status bar: the system puts one at the top of anything that scrolls, and here it
        // lay across the top of the video
        .noScrollEdgeBlur()
        .reportDialog($reportOf)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        // A swipe to the right goes back, as the X does: the video follows the finger, and past a third of a hand's
        // width (or flicked) it's left. Not from the line along the bottom, where a finger moves through the video.
        .offset(x: slide)
        .simultaneousGesture(DragGesture(minimumDistance: 24)
            .onChanged { v in
                guard holding == nil, v.startLocation.y < UIScreen.main.bounds.height - 130,
                      v.translation.width > 0, abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                slide = v.translation.width
            }
            .onEnded { v in
                if slide > 90 || (slide > 30 && v.predictedEndTranslation.width > 220) { leave() }
                else { withAnimation(.snappy(duration: 0.2)) { slide = 0 } }
            })
        // nothing behind the video but the screen it was opened from, which shows as the video slides away
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .onChange(of: current) { _, _ in paused = false; holding = nil; head.at = 0; head.length = 0; sound() }
        .onChange(of: paused) { _, _ in sound() }
        .onChange(of: muted) { _, _ in sound() }
        .onChange(of: holding) { was, now in
            // let go of the line: the song goes to the moment the video was left on, and both carry on from there
            if now == nil, let at = was { SongPlayer.shared.seek(at) }
            sound()
        }
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
        .sheet(item: $songShown) { s in SongCard(song: s.song, muted: $muted) }
        // deleting asks first: it was one tap in a menu, next to Edit, and there's no getting a post back
        .alert("Delete this post?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { b in
            Button("Delete", role: .destructive) { Task { await feed.delete(b.post) }; dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("It will be gone for good, along with its likes and comments.") }
        .sheet(item: $talking) { b in CommentsSheet(post: b.post).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(item: $sharing) { b in SharePostSheet(post: b.post).presentationDetents([.medium, .large]) }
        .sheet(item: $recipe) { b in PostRecipeSheet(post: b.post) }
        .sheet(item: $rewording) { b in EditPostSheet(post: b.post) }
        .overlay(alignment: .top) {
            if let note {
                Text(note).font(.footnote.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.black.opacity(0.7), in: Capsule()).padding(.top, 70).transition(.opacity)
            }
        }
    }

    /// Back out: the video slides off to the right, showing where it was opened from, and only then is the screen
    /// put away (with nothing left on it to see going). Left to the system it dropped off the bottom, and its last
    /// strip hung there for a moment over the tab bar.
    private func leave() {
        paused = true
        withAnimation(.easeOut(duration: 0.22)) { slide = UIScreen.main.bounds.width + 20 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }

    /// The video showing has a song: it plays, by itself, for as long as the video's showing and not paused or
    /// silenced, together with the clip's own sound (the two blended, as Instagram has them). One without a song is
    /// heard with its own sound alone.
    private func sound() {
        if let id = current, let p = posts.first(where: { str($0["id"]) == id }), let s = Music.of(p), !muted {
            // paused, or held on the line along the bottom: the song waits where it is (stopped and started again,
            // it began from its beginning while the video carried on from the middle)
            if SongPlayer.shared.playing != "reel:" + id {
                guard !paused else { return }
                SongPlayer.shared.play(s, key: "reel:" + id, loop: true, volume: Music.mix(p).song)
                if head.at > 0.3 { SongPlayer.shared.seek(head.at) }
            }
            SongPlayer.shared.hold(paused || holding != nil)
        } else {
            SongPlayer.shared.stop()
            // stopping a song hands the sound back to the ringer; here a video is still to be heard
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    /// The video, fetched and put in Photos.
    private func saveVideo(_ p: JSON) async {
        func say(_ text: String) async {
            withAnimation { note = text }
            try? await Task.sleep(for: .seconds(2.2))
            if note == text { withAnimation { note = nil } }
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { await say("Allow Photos in Settings to save"); return }
        withAnimation { note = "Saving…" }
        guard let remote = Feed.video(p), let (tmp, _) = try? await URLSession.shared.download(from: remote) else { await say("Couldn't save it"); return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        guard (try? FileManager.default.moveItem(at: tmp, to: file)) != nil else { await say("Couldn't save it"); return }
        let saved = (try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file) }) != nil
        try? FileManager.default.removeItem(at: file)
        await say(saved ? "Saved to Photos" : "Couldn't save it")
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
                    LoopingVideo(url: v, paused: paused, muted: muted, scrub: holding, tick: { at, length in
                        // gone round to its start: so does its song
                        if at + 0.5 < head.at, holding == nil { SongPlayer.shared.seek(at) }
                        head.at = at; head.length = length
                    }, volume: Music.mix(p).clip).aspectRatio(a, contentMode: .fit).allowsHitTesting(false)
                } else {
                    LoopingVideo(url: v, paused: paused, muted: muted, scrub: holding, tick: { at, length in
                        // gone round to its start: so does its song
                        if at + 0.5 < head.at, holding == nil { SongPlayer.shared.seek(at) }
                        head.at = at; head.length = length
                    }, volume: Music.mix(p).clip).allowsHitTesting(false)
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
                .onTapGesture {
                    let now = Date()
                    if now.timeIntervalSince(lastTap) < 0.3 {
                        // the second of two quick taps: a like, and the pause the first one made is taken back
                        withAnimation(.easeOut(duration: 0.1)) { paused = pausedBefore }
                        like(p, rx: rx)
                        lastTap = .distantPast
                    } else {
                        pausedBefore = paused; lastTap = now
                        withAnimation(.easeOut(duration: 0.12)) { paused.toggle() }
                    }
                }
                .simultaneousGesture(MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in
                        if v.magnification > 1.15, !clean { UIImpactFeedbackGenerator(style: .light).impactOccurred(); withAnimation(.easeOut(duration: 0.2)) { clean = true } }
                        else if v.magnification < 0.87, clean { UIImpactFeedbackGenerator(style: .light).impactOccurred(); withAnimation(.easeOut(duration: 0.2)) { clean = false } }
                    })
                .accessibilityLabel(paused ? "Play" : "Pause").accessibilityAddTraits(.isButton)
            // paused: everything stays where it was, with sound and play in the middle (as Instagram has it; it
            // used to clear the name, caption and buttons away, which read as something having gone wrong)
            if !clean { chrome(p, rx: rx) } else { backAgain }
            if on && paused { pausedButtons }
            if on {
                // just above the comment bar; lower when that's cleared away
                VStack { Spacer(); ReelBar(head: head, holding: $holding) }
                    .padding(.bottom, !clean ? 68 : 22)
            }
            if burst == id {
                HeartBurst().transition(.identity)
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
        .padding(.trailing, 14).padding(.bottom, 60)   // above the line, not under it
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
        // tapped again while it's still up: a fresh one
        burst = nil
        DispatchQueue.main.async { burst = id }
        Task { try? await Task.sleep(for: .milliseconds(1000)); if burst == id { burst = nil } }
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
                    Button { leave() } label: {
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
                        rail(feed.saved.contains(id) ? "bookmark.fill" : "bookmark", (feed.saveCounts[id] ?? 0) == 0 ? "" : "\(feed.saveCounts[id] ?? 0)") {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred(); Task { await feed.toggleSave(p) }
                        }
                        .accessibilityLabel(feed.saved.contains(id) ? "Saved, tap to take out" : "Save")
                        // the same choices the post has on the feed: yours to edit or delete, someone else's to hide or report
                        Menu {
                            Button { Task { await saveVideo(p) } } label: { Label("Save video", systemImage: "arrow.down.to.line") }
                            if str(p["owner"]) == feed.me {
                                Button { rewording = PostBox(post: p) } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { deleting = PostBox(post: p) } label: { Label("Delete post", systemImage: "trash") }
                            } else {
                                Button { Profiles.shared.toggleMute(str(p["owner"])); dismiss() } label: { Label("Hide posts from \(feed.name(str(p["owner"])))", systemImage: "eye.slash") }
                                Button { reportOf = ReportTarget(user: str(p["owner"]), what: "Post: \(id)") } label: { Label("Report post", systemImage: "flag") }
                            }
                        } label: {
                            Self.railIcon("ellipsis").foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 3).frame(width: 44).contentShape(Rectangle())
                        }
                        .menuOrder(.fixed).accessibilityLabel("More")
                        // no button for just the video: spreading two fingers does that, and its own button brings all this back
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 26)   // room for the line under it
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

    /// A symbol for the side of a reel, fitted to the same square whatever its own shape: drawn at one type size, the
    /// heart, the speech bubble, the paper plane and the three dots each came out a different size.
    private static func railIcon(_ symbol: String) -> some View {
        // the three dots are nothing but dots: stretched across the whole square they came out far heavier than the
        // other symbols' lines, so they're drawn narrower, in the middle of the same square
        let w: CGFloat = symbol == "ellipsis" ? 19 : 27
        return Image(systemName: symbol).resizable().scaledToFit().fontWeight(.medium).frame(width: w, height: w).frame(width: 27, height: 27)
    }

    private func rail(_ symbol: String, _ count: String, tint: Color = .white, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 3) {
                Self.railIcon(symbol).foregroundStyle(tint)
                    .symbolEffect(.bounce, value: symbol)   // the heart, as it fills or empties
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
                Avatar(id: owner, size: 32).task { await Follows.shared.loadKnown() }
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
                // its name opens the song (cover, name, sound on or off); the video carries on
                Button { songShown = SongShown(song: s, key: "reel:" + id) } label: {
                    Label(s.title + (playing ? "" : " · off"), systemImage: "music.note").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            if !caption.isEmpty { Text(caption).font(.subheadline).foregroundStyle(.white).lineLimit(3).multilineTextAlignment(.leading) }
            // someone you don't follow: who you know that does
            if stranger, let k = Follows.shared.known[owner] {
                HStack(spacing: 6) {
                    Avatar(id: k.via, size: 18)
                    (Text("Followed by ") + Text(feed.name(k.via)).bold() + Text(k.n > 1 ? " and \(k.n - 1) more" : ""))
                        .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            }
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

/// Where a playing video has got to. Its own small thing so that the line showing it can redraw twenty times a
/// second without the whole viewer doing so.
@Observable final class Playhead {
    var at: Double = 0
    var length: Double = 0
}

/// The fine line along the bottom of a video, as Instagram has: how far through it is. Put a finger on it and it
/// thickens, the video holds on the moment under the finger, and the time shows; lift, and it plays on from there.
struct ReelBar: View {
    let head: Playhead
    @Binding var holding: Double?

    var body: some View {
        let length = max(head.length, 0.01), now = holding ?? head.at
        VStack(spacing: 6) {
            if let h = holding {
                Text(clock(h) + " / " + clock(length)).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule())
            }
            GeometryReader { g in
                let w = g.size.width, tall: CGFloat = holding == nil ? 2 : 6
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28)).frame(height: tall)
                    Capsule().fill(.white.opacity(holding == nil ? 0.85 : 1)).frame(width: max(tall, w * CGFloat(min(1, now / length))), height: tall)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in holding = Double(min(1, max(0, v.location.x / max(1, w)))) * length }
                    .onEnded { _ in holding = nil })
                .animation(.easeOut(duration: 0.15), value: holding == nil)
            }
            .frame(height: 18)   // a finger's worth to catch, though the line is two points
        }
        .padding(.horizontal, 12)
        .accessibilityLabel("How far through").accessibilityValue(clock(now) + " of " + clock(length))
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(max(0, s)) / 60, Int(max(0, s)) % 60) }
}
