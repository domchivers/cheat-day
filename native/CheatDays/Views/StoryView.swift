import SwiftUI

/// A friend's day as stories, full screen: today's posts first, then each meal with what they had, then a workout.
/// Tap right for the next slide, left for the last, hold to pause, swipe down to close; one friend runs into the next.
struct StoryView: View {
    /// The people with a story today, in ring order, and where to start.
    let people: [String]
    @State var at: Int
    /// A highlight from a profile: just its stories, kept after their 24 hours.
    var highlight: JSON? = nil
    @State private var adding: JSON?   // your story going into a highlight
    @State private var managing: JSON?   // your story's options are open
    @State private var mentioning: JSON? // your story, someone being mentioned on it after it went up
    @State private var failed: String?
    @Environment(\.dismiss) private var dismiss
    @State private var slide = 0
    @State private var progress: Double = 0
    @State private var tickAt = Date()     // when progress last stepped, for drawing the bar between steps
    @State private var pace: Double = 0    // how much of the bar a second is
    @State private var swipe: CGFloat = 0     // how far the card's been pulled sideways, to the next person (−) or back (+)
    @State private var width: CGFloat = 400   // the card's, for how far a swipe has to go
    @State private var axis = 0               // the drag going on: 0 not known yet, 1 down (to close), 2 sideways
    @State private var grab: CGSize = .zero   // where the finger was when the drag set off, for the card to go from there
    @State private var paused = false
    /// The poster's name was tapped: the story closes and whoever opened it shows their profile as a normal page.
    var onProfile: ((String) -> Void)? = nil
    @State private var tagged: String?   // someone tagged on a story, tapped, where no one else can show their profile
    @State private var reportOf: ReportTarget?
    /// The slide showing, as a report carries it.
    private var reportTarget: ReportTarget {
        let s = slides
        guard !s.isEmpty else { return ReportTarget(user: who, what: "Story", kind: "profile", target: who) }
        switch s[min(slide, s.count - 1)] {
        case .snap(let st):
            let words = list(st["overlays"]).map { str($0["text"]) + str($0["q"]) }.filter { !$0.isEmpty }.joined(separator: "\n")
            let video = str(st["kind"]) == "video"
            return ReportTarget(user: who, what: "Story: \(str(st["id"]))", kind: "story", target: str(st["id"]), text: words, media: video ? "" : str(st["media"]), video: video)
        case .post(let p):
            return ReportTarget(user: who, what: "Post: \(str(p["id"]))", kind: "post", target: str(p["id"]),
                                text: [str(p["name"]), str(p["caption"])].filter { !$0.isEmpty }.joined(separator: "\n"), media: str(p["photo"]), video: Feed.video(p) != nil)
        default: return ReportTarget(user: who, what: "Their day, in a story", kind: "profile", target: who)
        }
    }
    @State private var reply = ""
    // starts below the screen: the story rises in on its own (onAppear), the swipe-down close played backwards
    @State private var drag: CGFloat = 1000
    @State private var sent = false
    @FocusState private var typing: Bool
    private static let seconds = 5.0

    enum Slide { case snap(JSON), post(JSON), meal(String, [JSON]), workout(JSON) }
    @State private var seenBy: JSON?   // your own snap's "Seen by" list
    // the heart beside the message box: tapped, a like; held, a row of emoji to answer with
    @State private var reacting = false
    @State private var sharing: PostBox?        // a post in their story, being sent to a friend
    @State private var sharingStory: PostBox?   // a story of theirs, being sent to a friend
    @State private var burstEmoji: String?
    @State private var likedSnaps: Set<String> = []
    private static let answers = ["❤️", "🔥", "👏", "😂", "😮", "😢", "💪"]
    private static let quick = ["😂", "😮", "😍", "😢", "👏", "🔥"]   // over the story while a message is being written
    @State private var wasQuiet = false   // whether keyboards had no Done bar before this opened

    /// What's on a story that can be pressed, so it's drawn above the taps that turn the slides: a poll, a question,
    /// a person tagged.
    static func live(_ o: JSON) -> Bool {
        ["poll", "question"].contains(str(o["type"])) || (str(o["type"]) == "mention" && !str(o["user"]).isEmpty && o["hidden"] as? Bool != true)
    }

    private var who: String { people[min(at, people.count - 1)] }
    private var slides: [Slide] { highlight.map { list($0["items"]).map { Slide.snap($0) } } ?? Self.slides(for: who) }
    private var isMe: Bool { who == Profiles.shared.me }

    /// Their slides: posts from today, then each meal they've logged, then workouts.
    static func slides(for id: String) -> [Slide] {
        let today = DayKey.string(Date())
        let posts = Feed.shared.posts.filter { str($0["owner"]) == id && str($0["kind"]) != "moment" && str($0["kind"]) != "photo" && ISO.date(str($0["created_at"])).map { DayKey.string($0) } == today }   // the server's time is UTC: by its first ten letters a Melbourne post before 11am was yesterday's
            .sorted { str($0["created_at"]) < str($1["created_at"]) }
        // stories they posted come first, then today's posts, meals and workouts
        var out: [Slide] = Stories.shared.of(id).map { .snap($0) } + posts.map { .post($0) }
        let food: [JSON], workouts: [JSON]
        // your own, "as friends see it": a workout only when Settings shares it in your day (it showed here always,
        // so a workout friends never got looked shared, 17 Nov)
        if id == Profiles.shared.me { food = Store.shared.todayItems; workouts = Store.shared.workoutsInDay ? Store.shared.todayWorkouts.map { ["name": $0["name"] ?? "", "workout": $0] } : [] }
        else if let p = Friends.shared.people.first(where: { $0.id == id }) { food = p.food; workouts = p.workouts }
        else { food = []; workouts = [] }
        for meal in Meals.all {
            let its = food.filter { (str($0["meal"]).isEmpty ? Meals.of($0) : str($0["meal"])) == meal }
            if !its.isEmpty { out.append(.meal(meal, its)) }
        }
        out += workouts.map { .workout($0) }
        return out
    }

    /// Something to show today: their ring is there.
    static func has(_ id: String) -> Bool { !slides(for: id).isEmpty }

    /// A ring is bright for something not watched yet. A story someone posted is known one by one (Stories.watched),
    /// for as long as it's up. What's from their day (today's posts, meals, a workout) is counted: watched to the end
    /// today, it's seen until there's more of it than there was.
    ///
    /// It was one sum of everything, matched exactly and by the day. So a ring came back bright the morning after for a
    /// story watched the night before, flashed bright each time the app opened (until their day had loaded and the
    /// count matched again), and your own lit up whenever you logged a meal.
    static func extras(_ id: String) -> Int {
        id == Profiles.shared.me ? 0 : max(0, slides(for: id).count - Stories.shared.of(id).count)
    }
    /// Which day of theirs is showing: their own date, not mine. A friend's day stays up for 18 hours after they last
    /// touched it (family in the UK), so it runs past my midnight; keyed by my date, a day already watched lit up
    /// again every night at 12 with nothing new in it.
    static func day(_ id: String) -> String {
        Friends.shared.people.first { $0.id == id }?.current.map { str($0["day"]) } ?? DayKey.string(Date())
    }
    static func signature(_ id: String) -> String { "\(day(id))|\(extras(id))" }
    static func seen(_ id: String) -> Bool {
        _ = Stories.shared.seenTick   // read, so a ring is drawn again when a story's been watched
        guard !Stories.shared.unwatched(id) else { return false }
        let more = extras(id)
        guard more > 0 else { return true }
        let kept = (UserDefaults.standard.dictionary(forKey: "stories.seen")?[id] as? String ?? "").split(separator: "|")
        guard kept.count == 2, String(kept[0]) == day(id), let had = Int(kept[1]) else { return false }
        return had >= more
    }
    static func markSeen(_ id: String) {
        var d = UserDefaults.standard.dictionary(forKey: "stories.seen") ?? [:]
        guard d[id] as? String != signature(id) else { Stories.shared.seenTick += 1; return }
        d[id] = signature(id); UserDefaults.standard.set(d, forKey: "stories.seen")
        Stories.shared.seenTick += 1
    }

    var body: some View {
        let s = slides
        ZStack {
            // the black is behind (below), so it stays put and fades while the story is pulled down; this only catches drags
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
            if !s.isEmpty {
                // The story stays the size it is when the keyboard comes up (it was squeezed to a third of the
                // screen); the message box rides up over it on the keyboard, as Instagram's does.
                ZStack(alignment: .bottom) {
                ZStack {   // its own, so the cards' order (zIndex) is only among themselves, under the message box
                // The person before, waiting under this one in the dark (back: this one slides off right to show them)
                if people.indices.contains(at - 1), highlight == nil {
                    let q = 1 - min(1, max(0, swipe) / width)
                    peek(people[at - 1]).modifier(Sunk(p: q, width: width)).opacity(swipe < 0 ? 0 : 1).zIndex(0)
                }
                VStack(spacing: 6) {
                    // Every slide the one shape (9:16, a story's own), and as big as the screen lets it be: edge to
                    // edge from the top, with the bars and the name over it, as Instagram's are. With those stacked
                    // above it on black and a margin each side, it came out noticeably smaller than theirs.
                    content(s[min(slide, s.count - 1)])
                        .aspectRatio(StoryArt.aspect, contentMode: .fit)
                        // solid behind every slide: the cards' colours fade to see-through and were made on black, so
                        // with the feed showing behind (swipe down, 16 Nov) the feed showed through the card, and one
                        // person's card through the other's in the push
                        .background(Color.black)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 16, style: .continuous))
                        // the bars and the name read over a bright photo too
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)).allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .overlay { taps }
                        // polls sit above the taps, so voting doesn't skip the story
                        .overlay {
                            if case .snap(let st) = s[min(slide, s.count - 1)] {
                                let polls = list(st["overlays"]).filter(Self.live)
                                // a name tagged on the story opens that person's page, as the poster's name at the top does
                                if !polls.isEmpty {
                                    StoryLayer(items: polls, story: str(st["id"]), mention: { id in
                                        // whoever opened the story shows the profile once it's closed (the feed); with nobody
                                        // to do that (a story opened from a profile or a chat), it comes up over the story
                                        if let onProfile { onProfile(id); dismiss() } else { tagged = id }
                                    }, holding: { paused = $0 })
                                        .aspectRatio(StoryArt.aspect, contentMode: .fit)
                                }
                            }
                        }
                        // over the taps, so the name and the cross can be pressed
                        .overlay(alignment: .top) {
                            VStack(spacing: 8) { bars(s.count); header }.padding(.horizontal, 8).shadow(color: .black.opacity(0.35), radius: 3)
                        }
                    // and the one height kept under it, whatever goes there, so the slide above doesn't change size either
                    Color.clear.frame(height: 52)
                }
                // Moving between people follows the finger (16 Nov): forward, the next one slides in over the top and
                // this one sinks back into the dark; back, this one slides off to the right. It played only once the
                // finger let go before, as a transition, and going back played the forward one.
                .modifier(Sunk(p: swipe < 0 && people.indices.contains(at + 1) ? min(1, -swipe / width) : 0, width: width))
                .offset(x: swipe > 0 || !people.indices.contains(at + 1) ? swipe : 0)
                .zIndex(swipe > 0 ? 2 : 1)
                // the next person, just off the right edge until it's pulled in
                if people.indices.contains(at + 1), highlight == nil {
                    peek(people[at + 1]).offset(x: width + min(0, swipe)).shadow(color: .black.opacity(swipe < 0 ? 0.5 : 0), radius: 16).zIndex(3)
                }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { width = $0 } }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // writing a message: the story dims, with emoji to answer in one tap; a tap on it puts the keyboard away
                if typing {
                    Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { typing = false }
                    VStack {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(96)), count: 3), spacing: 26) {
                            ForEach(Self.quick, id: \.self) { e in
                                Button { typing = false; react(s[min(slide, s.count - 1)], e) } label: { Text(e).font(.system(size: 52)) }
                                    .buttonStyle(.plain).accessibilityLabel("React with " + e)
                            }
                        }
                        .padding(.top, 170)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .transition(.opacity)
                }
                footer(s[min(slide, s.count - 1)]).frame(height: 52).padding(.horizontal, 8).padding(.bottom, typing ? 6 : 0)
                }
                .animation(.easeOut(duration: 0.18), value: typing)
                // the row of emoji is open: a tap anywhere else puts it away
                if reacting { Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { withAnimation(.snappy(duration: 0.2)) { reacting = false } } }
                if reacting {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(Self.answers, id: \.self) { e in
                                Button { withAnimation(.snappy(duration: 0.2)) { reacting = false }; react(s[min(slide, s.count - 1)], e) } label: {
                                    Text(e).font(.system(size: 30)).frame(width: 42, height: 46)
                                }
                                .buttonStyle(.plain).accessibilityLabel("React with " + e)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule()).environment(\.colorScheme, .dark)
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                        .padding(.bottom, 64)
                    }
                    .transition(.scale(scale: 0.7, anchor: .bottomTrailing).combined(with: .opacity))
                }
                if let e = burstEmoji { EmojiShower(emoji: e).transition(.identity) }
            }
        }
        .offset(y: max(0, drag))
        // Swiping down to close (D3, chosen 16 Nov): the story slides down under the finger and the screen it was
        // opened from shows through as the black fades. The black slid down with it before, so it was black behind.
        .background { Color.black.opacity(max(0, 1 - Double(max(0, drag)) / 500)).ignoresSafeArea() }
        .presentationBackground(.clear)
        .gesture(DragGesture().onChanged { v in
                let t = v.translation
                // which way it's going is settled once, at the start, so a swipe sideways that dips doesn't start closing;
                // and the card goes from where it is then, not by the 10 points the finger had to move first (it
                // jumped them as it set off, 17 Nov)
                if axis == 0 { axis = abs(t.width) > abs(t.height) * 1.2 && !typing && highlight == nil ? 2 : 1; grab = t }
                let dx = t.width - grab.width, dy = t.height - grab.height
                if axis == 2 {
                    paused = true
                    // nobody that way (the first person, back): it gives a little and comes back, so it doesn't feel stuck
                    let there = people.indices.contains(at + (dx < 0 ? 1 : -1))
                    swipe = there ? dx : dx * 0.25
                } else { drag = max(0, dy); paused = true }
            }
            .onEnded { v in
                let across = v.translation.width - grab.width, down = v.translation.height - grab.height
                defer { axis = 0; grab = .zero }
                // a swipe sideways: the next person's story, or the one before, once it's gone a third of the way or
                // was flicked
                if axis == 2 {
                    let step = across < 0 ? 1 : -1
                    let far = abs(across) > width * 0.3 || abs(v.predictedEndTranslation.width) > width * 0.6
                    if far, people.indices.contains(at + step) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if step > 0 { Self.markSeen(who) }
                        finish(step, speed: v.velocity.width)
                    } else if far, step > 0 { Self.markSeen(who); dismiss() }   // past the last person, they close
                    else { withAnimation(.smooth(duration: 0.3)) { swipe = 0 }; paused = false }
                    return
                }
                // far enough, or flicked down
                let speed = v.velocity.height
                if down > 120 || (down > 30 && speed > 700) {
                    print("StoryView closed by a swipe down: across \(across), down \(down), speed \(Int(speed))")
                    // It carries on down from where the finger let go at the finger's own speed, easing off as it goes,
                    // then closes with nothing left to slide. It went the rest of the way in a set 0.2 s from a standing
                    // start, so after a slow pull it leapt off the screen (17 Nov).
                    let rest = max(1, 1000 - drag)
                    let time = min(0.45, max(0.22, 2 * rest / max(900, speed)))   // the curve starts at twice its average speed
                    withAnimation(.timingCurve(0.25, 0.5, 0.5, 1, duration: time)) { drag = 1000 } completion: {
                        var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { dismiss() }
                    }
                } else { withAnimation(.snappy) { drag = 0 }; paused = false }
            })
        .statusBarHidden()
        // opened with the system's slide-up turned off (openStory), it comes up from below as the black fades in
        .onAppear { withAnimation(.spring(duration: 0.34, bounce: 0)) { drag = 0 } }
        .overlay(alignment: .top) {
            if let failed {
                Text(failed).font(.footnote.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.red.opacity(0.85), in: Capsule()).padding(.top, 70)
                    .task { try? await Task.sleep(for: .seconds(3)); self.failed = nil }
            }
        }
        .task(id: "\(at)|\(slide)") {
            progress = 0
            let now = slides.indices.contains(slide) ? slides[slide] : nil
            var length = Self.seconds
            if case .snap(let st)? = now { if highlight == nil { Stories.shared.watch(st) }; if str(st["kind"]) == "video" { length = max(3, num(st["seconds"]) ?? 15) } }
            // a story with a song: it plays for as long as the story's showing (it's one of the things put on it, by name)
            if case .snap(let st)? = now, let tune = list(st["overlays"]).first(where: { str($0["type"]) == "song" }),
               var song = Music.all.first(where: { $0.id == str(tune["id"]) }) {
                song.start = num(tune["start"])   // the part of it the poster chose, if they did
                SongPlayer.shared.play(song, key: "story:" + str(st["id"]), loop: true)
            } else { SongPlayer.shared.stop() }
            pace = 1 / length; tickAt = Date()
            // The last slide's up: this person's story has been watched. It was only counted when the last slide was
            // gone past (by its bar running out or a tap), so closing on the last slide, as most people do, left
            // the ring bright for good.
            if highlight == nil, slide >= slides.count - 1 { Self.markSeen(who) }
            // what's coming, fetched while this slide's being watched: the rest of this person's, then the next person's
            if highlight == nil {
                let rest = slides.dropFirst(slide + 1).flatMap(Self.pictures)
                let after = people.indices.contains(at + 1) ? Self.slides(for: people[at + 1]).flatMap(Self.pictures) : []
                Stories.shared.fetchSoon(rest + after)
            }
            // a photo that isn't here yet: its bar waits for it (up to eight seconds), as Instagram's does. It ran on over
            // a blank slide before, so a slow picture was gone before it was seen.
            // By the clock, not by counting ticks: a tick is never exactly 50 ms, so counted ones ran the bar unevenly
            var waited = 0.0, last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                let at = Date(), dt = min(0.25, at.timeIntervalSince(last)); last = at
                if case .snap(let st)? = now, waited < 8, Stories.pictures(st).contains(where: { ImageStore.cached($0) == nil }) { waited += dt; continue }
                if paused || tagged != nil || reportOf != nil || typing || reacting || sharing != nil || sharingStory != nil || seenBy != nil || adding != nil || managing != nil || mentioning != nil { continue }
                progress += dt / length; tickAt = at
                if progress >= 1 { next(); return }
            }
        }
        .onAppear { if slides.isEmpty { dismiss() }; wasQuiet = KeyboardDone.quiet; KeyboardDone.quiet = true }
        .onDisappear { KeyboardDone.quiet = wasQuiet }
        .onChange(of: paused) { _, on in SongPlayer.shared.hold(on) }
        .onDisappear { SongPlayer.shared.stop() }
    }

    private func bars(_ n: Int) -> some View {
        // Smooth between the 20-a-second steps by drawing every frame, up to one step past the last (where a paused bar
        // rests). It slid with an animation before (16 Nov): during a swipe down the white part was animated on its
        // own and came apart from its bar, trailing above the card.
        TimelineView(.animation) { tl in
            let ahead = min(0.05, max(0, tl.date.timeIntervalSince(tickAt))) * pace
            let now = progress > 0 ? min(1, progress + ahead) : 0
            HStack(spacing: 4) {
                ForEach(0..<n, id: \.self) { i in
                    GeometryReader { g in
                        Capsule().fill(.white.opacity(0.3))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: g.size.width * (i < slide ? 1 : i == slide ? now : 0))
                            }
                    }
                    .frame(height: 3)
                }
            }
        }
        .padding(.top, 6)
    }

    /// When the slide showing is from: a story or a post by how long ago it went up ("3 h ago", "yesterday"), a meal or
    /// workout from their day "today". It said "today" for all of them, a story from last night too.
    private var when: String {
        let s = slides
        guard !s.isEmpty else { return "today" }
        return Self.whenWord(s[min(slide, s.count - 1)], who)
    }
    static func whenWord(_ s: Slide, _ id: String) -> String {
        let ago: String
        switch s {
        case .snap(let st): ago = Feed.ago(str(st["created_at"]))
        case .post(let p): ago = Feed.ago(str(p["created_at"]))
        default: ago = ""
        }
        return ago.isEmpty ? dayWord(id) : ago
    }

    /// Their day's slides: today, or yesterday when the day showing is still yesterday's (a day touched in the last
    /// 18 hours is shown, for family in other time zones, and it said "today" the morning after).
    static func dayWord(_ id: String) -> String {
        guard id != Profiles.shared.me, let d = Friends.shared.people.first(where: { $0.id == id })?.current else { return "today" }
        return str(d["day"]) == DayKey.string(Date()) || str(d["day"]).isEmpty ? "today" : "yesterday"
    }

    private var header: some View {
        HStack(spacing: 9) {
            // their photo and name close the story and open their profile, as a page
            Button { onProfile?(who); dismiss() } label: {
                HStack(spacing: 9) {
                    Avatar(id: who, size: 32)
                    Text(highlight.map { str($0["title"]).isEmpty ? "Highlight" : str($0["title"]) } ?? (isMe ? "Your day" : Feed.shared.name(who))).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("story-author")
            Text(when).font(.subheadline).foregroundStyle(.white.opacity(0.65))
            Spacer()
            // someone else's: it can be reported (there was no way to from the story itself)
            if !isMe, highlight == nil {
                Button { reportOf = reportTarget } label: {
                    Image(systemName: "flag").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(8)
                }
                .accessibilityLabel("Report")
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).padding(8) }
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 6)
    }

    /// Tap the left side to go back, the right side to go forward; hold anywhere to pause. One view reads where
    /// the tap was, so the hold to pause can't swallow the taps.
    private var taps: some View {
        GeometryReader { g in
            Color.clear.contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in if p.x < g.size.width * 0.4 { back() } else { next() } }
                .onLongPressGesture(minimumDuration: 0.25, perform: {}, onPressingChanged: { paused = $0 })
        }
        .accessibilityElement()
        .accessibilityLabel("Story")
        .accessibilityAction(named: "Next") { next() }
        .accessibilityAction(named: "Back") { back() }
        .reportDialog($reportOf)
        .sheet(isPresented: Binding(get: { tagged != nil }, set: { if !$0 { tagged = nil } })) {
            NavigationStack {
                ProfileView(id: tagged ?? "")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { tagged = nil } } }
            }
        }
    }

    /// A slide, for whoever's story is showing, or for `person` beside it (peek), which never plays.
    @ViewBuilder private func content(_ s: Slide, of person: String? = nil) -> some View {
        let them = person ?? who
        switch s {
        case .snap(let st):
            // 9:16, the editor's shape, so everything placed lands where it was put
            let layer = StoryLayer(items: list(st["overlays"]).filter { !Self.live($0) }, story: str(st["id"]))
            ZStack {
                if str(st["kind"]) == "video", let url = URL(string: str(st["media"])) { LoopingVideo(url: url, paused: paused || seenBy != nil || person != nil); layer }
                // a photo still on its way: black with a turning circle, and nothing that's stuck on it until it's
                // here (the stickers and tags showed at once, over an empty slide)
                else { StoryPhoto(src: str(st["media"]), also: Stories.pictures(st).filter { $0 != str(st["media"]) }) { layer }.id(str(st["id"])) }
            }
            .aspectRatio(StoryArt.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .post(let p):
            ZStack(alignment: .bottomLeading) {
                if Feed.hasPhoto(p) { FeedPhoto(src: str(p["photo"]), fill: true) }
                else {
                    LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    FoodDot(name: str(p["kind"]) == "workout" ? "Workout" : str(p["name"]), size: 150).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !str(p["caption"]).isEmpty { Text(str(p["caption"])).font(.body.weight(.semibold)).foregroundStyle(.white).shadow(radius: 4) }
                    HStack(spacing: 8) {
                        Text(str(p["name"])).lineLimit(1)
                        Text("\(Fmt.int(num(p["kcal"]) ?? 0)) kcal").foregroundStyle(.white.opacity(0.75))
                        if let pr = num(dict(p["macros"])["p"]) { Text("\(Int(pr)) g protein").foregroundStyle(Theme.walk) }
                    }
                    .font(.caption.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                }
                .padding(14)
            }
        case .meal(let meal, let items):
            let kcal = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: meal, color: Theme.heroLabel)
                Text("\(Fmt.int(kcal)) kcal").font(.system(size: 34, weight: .heavy)).foregroundStyle(.white)
                Text("What \(them == Profiles.shared.me ? "you" : Feed.shared.name(them)) had").font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(Theme.heroLabel).textCase(.uppercase).padding(.top, 8)
                ForEach(items.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        FoodDot(name: str(items[i]["name"]), size: 32)
                        Text(str(items[i]["name"])).font(.body).foregroundStyle(.white).lineLimit(2)
                        Spacer()
                        Text(Fmt.int(num(items[i]["kcal"]) ?? 0)).font(.body.weight(.bold)).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                    }
                }
                Spacer()
            }
            .padding(22).padding(.top, 62)
            .background(LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .workout(let w):
            let lifts = list(dict(w["workout"])["lifts"] ?? w["lifts"])
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Workout", color: Theme.heroLabel)
                Text(str(w["name"]).replacingOccurrences(of: "Workout: ", with: "")).font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                ForEach(lifts.indices, id: \.self) { i in
                    Text("\(str(lifts[i]["exercise"])) · \(Int(num(lifts[i]["sets"]) ?? 3))×\(Int(num(lifts[i]["reps"]) ?? 8))").font(.body).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                FoodDot(name: "Workout", size: 90).frame(maxWidth: .infinity, alignment: .trailing).opacity(0.6)
            }
            .padding(22).padding(.top, 62)
            .background(LinearGradient(colors: [Color(red: 0.1, green: 0.18, blue: 0.32), Color(red: 0.16, green: 0.13, blue: 0.31)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    @ViewBuilder private func footer(_ s: Slide) -> some View {
        if highlight != nil {
            // a highlight: when it was, nothing to reply to from here
            if case .snap(let st) = s {
                Text(ISO.date(str(st["created_at"]))?.formatted(.dateTime.day().month(.wide).year()) ?? "").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.65)).frame(height: 44)
            }
        } else if isMe {
            if case .snap(let st) = s {
                // yours: who's watched it, and take it down early
                HStack {
                    Button { seenBy = st } label: {
                        Label("Seen by \(Stories.shared.viewers(st).count)", systemImage: "eye").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    }
                    Spacer()
                    Text(str(st["audience"]) == "friends" ? "Friends only" : "Friends and followers").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                    // mention someone on it now it's up, as Instagram's Mention along the bottom
                    Button { mentioning = st } label: { Image(systemName: "at").font(.title3.weight(.semibold)).foregroundStyle(.white).padding(8) }
                        .accessibilityLabel("Mention someone")
                    sendButton { sharingStory = PostBox(post: st) }
                    // a dialog that pauses the story: a menu kept playing, moved to the next slide, and its Delete did nothing
                    Button { managing = st } label: { Image(systemName: "ellipsis").font(.title3).foregroundStyle(.white).padding(10) }
                        .accessibilityLabel("Story options")
                }
                .frame(height: 44).padding(.horizontal, 8)
                .sheet(item: $sharingStory) { b in ShareStorySheet(story: b.post).presentationDetents([.medium, .large]) }
                .sheet(item: Binding(get: { seenBy.map { PostBox(post: $0) } }, set: { seenBy = $0?.post })) { b in SeenBySheet(story: b.post).presentationDetents([.medium, .large]) }
                .sheet(item: Binding(get: { adding.map { PostBox(post: $0) } }, set: { adding = $0?.post })) { b in AddToHighlight(story: b.post).presentationDetents([.medium, .large]) }
                .sheet(item: Binding(get: { mentioning.map { PostBox(post: $0) } }, set: { mentioning = $0?.post })) { b in
                    MentionPicker { id, name in
                        Task {
                            if await Stories.shared.mention(b.post, user: id, name: name) { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                            else { failed = Stories.shared.error ?? "Couldn't add that." }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
                .confirmationDialog("Your story", isPresented: Binding(get: { managing != nil }, set: { if !$0 { managing = nil } }), presenting: managing) { m in
                    Button("Add to highlight") { managing = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { adding = m } }
                    // tag someone after it's gone up (it could only be done while it was made)
                    Button("Mention someone") { managing = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { mentioning = m } }
                    Button("Delete this story", role: .destructive) {
                        managing = nil
                        Task {
                            if await Stories.shared.delete(m) {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                if slides.isEmpty { dismiss() } else { slide = min(slide, slides.count - 1); progress = 0 }
                            } else { failed = "Couldn't delete it. Check your connection and try again." }
                        }
                    }
                    Button("Cancel", role: .cancel) { managing = nil }
                }
            } else {
                HStack {
                    Text("Your day, as friends see it").font(.footnote).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    sendButton { sharingStory = PostBox(post: dayCard(s)) }
                }
                .frame(height: 44).padding(.horizontal, 8)
                .sheet(item: $sharingStory) { b in ShareStorySheet(story: b.post).presentationDetents([.medium, .large]) }
            }
        } else {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    TextField("", text: $reply, prompt: Text(typing ? "Send message…" : sent ? "Sent" : "Send \(Feed.shared.name(who)) a message…").foregroundStyle(.white.opacity(0.7)))
                        .focused($typing).foregroundStyle(.white).submitLabel(.send).onSubmit { send() }
                    if typing, !reply.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button { send() } label: {
                            Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 48, height: 32).background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Send")
                    }
                }
                .padding(.leading, 16).padding(.trailing, typing ? 6 : 16).frame(height: 44)
                .overlay(Capsule().stroke(.white.opacity(0.55), lineWidth: 1.5))
                if !typing {
                // a heart whatever the slide is (a meal or workout had a party popper here, which nobody read as a like)
                let liked = isLiked(s)
                Image(systemName: liked ? "heart.fill" : "heart").font(.system(size: 25, weight: .medium))
                    .foregroundStyle(liked ? Color(red: 1, green: 0.3, blue: 0.4) : .white)
                    .symbolEffect(.bounce, value: liked)
                    .frame(width: 40, height: 44).contentShape(Rectangle())
                    .onTapGesture { react(s, "❤️") }
                    .onLongPressGesture(minimumDuration: 0.3) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.snappy(duration: 0.2)) { reacting = true }
                    }
                    .accessibilityLabel(liked ? "Liked" : "Like").accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "React with an emoji") { reacting = true }
                // send it to a friend: a post, or a story (one for friends only still opens only for their friends)
                switch s {
                case .post(let p): sendButton { sharing = PostBox(post: p) }
                case .snap(let st): sendButton { sharingStory = PostBox(post: st) }
                default: sendButton { sharingStory = PostBox(post: dayCard(s)) }
                }
                }
            }
            .sheet(item: $sharing) { b in SharePostSheet(post: b.post).presentationDetents([.medium, .large]) }
            .sheet(item: $sharingStory) { b in ShareStorySheet(story: b.post).presentationDetents([.medium, .large]) }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
    }

    private func sendButton(_ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: "paperplane").font(.system(size: 23, weight: .medium)).foregroundStyle(.white).frame(width: 38, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Send to a friend")
    }

    /// A story as a message carries it: which one, whose, and its picture.
    static func card(_ st: JSON) -> JSON {
        ["story": str(st["id"]), "owner": str(st["owner"]), "kind": str(st["kind"]), "media": str(st["media"])]
    }

    /// A meal or workout from someone's day, as a message carries it: whose, which day, and which one. Not what was
    /// in it: whoever it's sent to sees that only if they can see that person's day themselves.
    private func dayCard(_ s: Slide) -> JSON {
        var kind = "", name = ""
        switch s {
        case .meal(let meal, _): kind = "meal"; name = meal
        case .workout(let w): kind = "workout"; name = str(w["name"]).replacingOccurrences(of: "Workout: ", with: "")
        default: break
        }
        return ["id": "day:" + who + ":" + kind + ":" + name, "owner": who, "day": DayKey.string(Date()), "slide": kind, "name": name]
    }

    /// That meal or workout, if it's still today and it's a day this person can see.
    static func daySlide(_ p: JSON) -> Slide? {
        let kind = str(p["slide"]), name = str(p["name"])
        guard !kind.isEmpty, str(p["day"]) == DayKey.string(Date()) else { return nil }
        return slides(for: str(p["owner"])).first {
            switch $0 {
            case .meal(let meal, _): return kind == "meal" && meal == name
            case .workout(let w): return kind == "workout" && str(w["name"]).replacingOccurrences(of: "Workout: ", with: "") == name
            default: return false
            }
        }
    }

    /// The picture a slide needs fetched, if it has one (a photo story, or a post's photo).
    static func picture(_ s: Slide) -> String? {
        switch s {
        case .snap(let st): return str(st["kind"]) == "video" ? nil : str(st["media"])
        case .post(let p): return Feed.hasPhoto(p) ? str(p["photo"]) : nil
        default: return nil
        }
    }
    /// Every picture a slide shows, photos stuck on it included.
    static func pictures(_ s: Slide) -> [String] {
        if case .snap(let st) = s { return Stories.pictures(st) }
        return picture(s).map { [$0] } ?? []
    }

    private func isLiked(_ s: Slide) -> Bool {
        switch s {
        case .snap(let st): return likedSnaps.contains(str(st["id"])) || Stories.shared.reacted[str(st["id"])] != nil
        case .post(let p): return Feed.shared.reactions.contains { str($0["post_id"]) == str(p["id"]) && str($0["user_id"]) == Feed.shared.me && str($0["emoji"]) == "❤️" }
        default: return Friends.shared.cheered.contains(who)
        }
    }

    /// A like or another emoji for the slide showing: sent the way that kind of slide takes it, and shown going up.
    private func react(_ s: Slide, _ e: String) {
        switch s {
        case .snap(let st):
            let id = str(st["id"]), had = Stories.shared.reacted[id]
            // the heart tapped on a story already liked takes the like off, with nothing sent or shown for it
            if had != nil, e == "❤️" { likedSnaps.remove(id); Task { await Stories.shared.unreact(st) }; return }
            if had == e { return }   // the same emoji again: said once already
            likedSnaps.insert(id)
            // on the story's own record (its Seen by list), and to its owner as a message with the story on it
            Task {
                await Stories.shared.react(st, e)
                var payload = Self.card(st); payload["reaction"] = e
                await Messages.shared.send(to: who, text: "Reacted \(e) to your story", kind: "story", payload: payload)
            }
        case .post(let p):
            let has = Feed.shared.reactions.contains { str($0["post_id"]) == str(p["id"]) && str($0["user_id"]) == Feed.shared.me && str($0["emoji"]) == e }
            // the heart tapped on a post already liked takes the like off, with nothing to show for it
            if has { if e == "❤️" { Task { await Feed.shared.toggle(p, e) } }; return }
            Task { await Feed.shared.toggle(p, e) }
        default:
            if let person = Friends.shared.people.first(where: { $0.id == who }) { Task { await Friends.shared.cheer(person, emoji: e) } }
        }
        burstEmoji = nil
        DispatchQueue.main.async { burstEmoji = e }
        Task { try? await Task.sleep(for: .milliseconds(1800)); if burstEmoji == e { burstEmoji = nil } }
    }

    private func send() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        reply = ""; typing = false; sent = true
        // words written under a story go with the story they're about
        let showing = slides.indices.contains(slide) ? slides[slide] : nil
        Task {
            if case .snap(let st)? = showing {
                var payload = Self.card(st); payload["reply"] = t
                await Messages.shared.send(to: who, text: t, kind: "story", payload: payload)
            } else { await Messages.shared.send(to: who, text: t) }
        }
    }

    private func next() {
        if slide + 1 < slides.count { slide += 1; return }
        Self.markSeen(who)
        if at + 1 < people.count { go(1) } else { dismiss() }
    }
    /// To the next person (or back one) with the push (B, chosen 16 Nov), as a tap at either end of someone's story does.
    private func go(_ step: Int) {
        guard people.indices.contains(at + step), swipe == 0 else { return }   // two quick taps: one move at a time
        finish(step)
    }
    /// The push carried through from wherever the finger left it. The people before and after are drawn beside this
    /// one all along, so when it's done the one now in front just becomes the story showing, with nothing jumping.
    /// From a swipe, it goes on at the finger's speed (`speed`, points a second) and eases off; from a tap, in a set time.
    /// It went in a set 0.32 s on a curve starting at three times its average, so after a slow drag the next story
    /// leapt across in a frame (17 Nov).
    private func finish(_ step: Int, speed: CGFloat = 0) {
        let n = at + step
        paused = true
        let rest = max(1, width - abs(swipe))
        let time = speed == 0 ? 0.32 : min(0.42, max(0.2, 2 * rest / max(900, abs(speed))))   // the curve starts at twice its average
        withAnimation(.timingCurve(0.25, 0.5, 0.5, 1, duration: time)) { swipe = step > 0 ? -width : width } completion: {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { at = n; slide = 0; progress = 0; swipe = 0; paused = false }
        }
    }
    /// The person before or after, as their story will look when it starts: their first slide, empty bars, their name.
    /// Drawn beside the one showing, for the swipe to pull in. Nothing on it can be pressed.
    @ViewBuilder private func peek(_ p: String) -> some View {
        let s = Self.slides(for: p)
        if let first = s.first {
            VStack(spacing: 6) {
                content(first, of: p)
                    .aspectRatio(StoryArt.aspect, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 16, style: .continuous))
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .top) {
                        VStack(spacing: 8) {
                            HStack(spacing: 4) { ForEach(0..<s.count, id: \.self) { _ in Capsule().fill(.white.opacity(0.3)).frame(height: 3) } }
                                .padding(.top, 6)
                            HStack(spacing: 9) {
                                Avatar(id: p, size: 32)
                                Text(p == Profiles.shared.me ? "Your day" : Feed.shared.name(p)).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                                Text(Self.whenWord(first, p)).font(.subheadline).foregroundStyle(.white.opacity(0.65))
                                Spacer()
                                if p != Profiles.shared.me { Image(systemName: "flag").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(8) }
                                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).padding(8)
                            }
                            .padding(.horizontal, 6)
                        }
                        .padding(.horizontal, 8).shadow(color: .black.opacity(0.35), radius: 3)
                    }
                Color.clear.frame(height: 52)
            }
            .allowsHitTesting(false)
        }
    }

    private func back() {
        if slide > 0 { slide -= 1 } else if at > 0 { go(-1) } else { progress = 0 }
    }
}

/// Shows a story without the system's slide-up: with the feed showing behind a story (16 Nov) that slid up a black
/// sheet with the feed above it. StoryView rises in by itself instead.
func openStory(_ change: () -> Void) {
    var t = Transaction(); t.disablesAnimations = true
    withTransaction(t, change)
}

/// A person's story pushed back behind the next one, by how far (0 to 1): drifted a little to the left, a touch
/// smaller, and in the dark.
struct Sunk: ViewModifier {
    let p: CGFloat
    let width: CGFloat
    func body(content: Content) -> some View {
        // dimmed by a black layer fading in, not by brightness: brightness takes the same off every colour, so the
        // app's dark navy cards were near black a little way into a swipe (17 Nov)
        content
            .overlay { Color.black.opacity(0.55 * p).allowsHitTesting(false) }
            .scaleEffect(1 - 0.06 * p).offset(x: -width * 0.28 * p)
    }
}

/// Who's watched one of your stories, and how they reacted.
struct SeenBySheet: View {
    let story: JSON
    var body: some View {
        NavigationStack {
            List {
                let v = Stories.shared.viewers(story)
                if v.isEmpty { Text("No one yet.").foregroundStyle(.secondary) }
                ForEach(v.indices, id: \.self) { i in
                    let who = str(v[i]["viewer"])
                    HStack(spacing: 12) {
                        Avatar(id: who, size: 36)
                        Text(Feed.shared.name(who)).font(.subheadline.weight(.semibold))
                        Spacer()
                        if !str(v[i]["reaction"]).isEmpty { Text(str(v[i]["reaction"])).font(.title3) }
                    }
                }
            }
            .navigationTitle("Seen by \(Stories.shared.viewers(story).count)").navigationBarTitleDisplayMode(.inline)
            .task { await Stories.shared.load() }
        }
    }
}

/// A story sent on to a friend, as a message. It carries which story it is; the friend sees it there only if it's
/// still up and it's one they're allowed to see, the same as in the rings.
struct ShareStorySheet: View {
    let story: JSON
    var body: some View {
        let owner = str(story["owner"]), name = Feed.shared.name(owner)
        SendToSheet(exclude: owner) { friend, note in
            // a friends-only story goes without its picture: whoever may see it gets that from the story itself
            var payload = StoryView.card(story)
            if str(story["audience"]) == "friends" { payload["media"] = "" }
            // a meal or workout from their day has no story of its own to point to: it goes as which one it was
            if !str(story["slide"]).isEmpty { payload = story; payload["id"] = nil }
            await Messages.shared.send(to: friend, text: owner == Feed.shared.me ? "Sent a story" : "Sent \(name)'s story", kind: "story", payload: payload)
            if !note.isEmpty { await Messages.shared.send(to: friend, text: note) }
        }
    }
}

/// A story's photo with what's placed on it. Until the photo's here: black, a turning circle, and none of the rest.
struct StoryPhoto<Over: View>: View {
    let src: String
    /// The photos stuck on it: it waits for those too, so it comes up whole (the picture showed with a stuck-on
    /// photo still blank on it, filling in after).
    var also: [String] = []
    @ViewBuilder var over: () -> Over
    @State private var image: UIImage?
    @State private var rest: Bool

    init(src: String, also: [String] = [], @ViewBuilder over: @escaping () -> Over) {
        self.src = src; self.also = also; self.over = over
        _image = State(initialValue: ImageStore.cached(src))
        _rest = State(initialValue: also.allSatisfy { ImageStore.cached($0) != nil })
    }

    var body: some View {
        ZStack {
            Color.black
            if let image, rest {
                Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.clipped()
                over()
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .task(id: src) {
            // the stuck-on photos come down alongside; however they fare, they're waited for no more than eight seconds
            let others = also
            let waiting = Task {
                await withTaskGroup(of: Void.self) { g in for u in others where ImageStore.cached(u) == nil { g.addTask { _ = await ImageStore.load(u) } } }
            }
            if image == nil {
                for attempt in 0..<3 {
                    if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
                    if Task.isCancelled { return }
                    if let got = await ImageStore.load(src) { image = got; break }
                }
            }
            if !rest {
                let limit = Task { try? await Task.sleep(for: .seconds(8)); waiting.cancel() }
                _ = await waiting.value
                limit.cancel()
                rest = true
            }
        }
    }
}
