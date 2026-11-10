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
    @State private var failed: String?
    @Environment(\.dismiss) private var dismiss
    @State private var slide = 0
    @State private var progress: Double = 0
    @State private var paused = false
    /// The poster's name was tapped: the story closes and whoever opened it shows their profile as a normal page.
    var onProfile: ((String) -> Void)? = nil
    @State private var reply = ""
    @State private var drag: CGFloat = 0
    @State private var sent = false
    @FocusState private var typing: Bool
    private static let seconds = 5.0

    enum Slide { case snap(JSON), post(JSON), meal(String, [JSON]), workout(JSON) }
    @State private var seenBy: JSON?   // your own snap's "Seen by" list

    private var who: String { people[min(at, people.count - 1)] }
    private var slides: [Slide] { highlight.map { list($0["items"]).map { Slide.snap($0) } } ?? Self.slides(for: who) }
    private var isMe: Bool { who == Profiles.shared.me }

    /// Their slides: posts from today, then each meal they've logged, then workouts.
    static func slides(for id: String) -> [Slide] {
        let today = DayKey.string(Date())
        let posts = Feed.shared.posts.filter { str($0["owner"]) == id && str($0["kind"]) != "moment" && String(str($0["created_at"]).prefix(10)) == today }
            .sorted { str($0["created_at"]) < str($1["created_at"]) }
        // stories they posted come first, then today's posts, meals and workouts
        var out: [Slide] = Stories.shared.of(id).map { .snap($0) } + posts.map { .post($0) }
        let food: [JSON], workouts: [JSON]
        if id == Profiles.shared.me { food = Store.shared.todayItems; workouts = Store.shared.todayWorkouts.map { ["name": $0["name"] ?? "", "workout": $0] } }
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

    /// What was in it when last watched, so new things colour the ring again.
    static func signature(_ id: String) -> String { "\(DayKey.string(Date()))|\(slides(for: id).count)" }
    static func seen(_ id: String) -> Bool {
        !Stories.shared.unwatched(id) && (UserDefaults.standard.dictionary(forKey: "stories.seen")?[id] as? String) == signature(id)
    }
    static func markSeen(_ id: String) {
        var d = UserDefaults.standard.dictionary(forKey: "stories.seen") ?? [:]
        d[id] = signature(id); UserDefaults.standard.set(d, forKey: "stories.seen")
    }

    var body: some View {
        let s = slides
        ZStack {
            Color.black.ignoresSafeArea()
            if !s.isEmpty {
                VStack(spacing: 10) {
                    bars(s.count)
                    header
                    content(s[min(slide, s.count - 1)])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { taps }
                        // polls sit above the taps, so voting doesn't skip the story
                        .overlay {
                            if case .snap(let st) = s[min(slide, s.count - 1)] {
                                let polls = list(st["overlays"]).filter { ["poll", "question"].contains(str($0["type"])) }
                                if !polls.isEmpty { StoryLayer(items: polls, story: str(st["id"])).aspectRatio(StoryArt.aspect, contentMode: .fit) }
                            }
                        }
                    footer(s[min(slide, s.count - 1)])
                }
                .padding(.horizontal, 8)
            }
        }
        .offset(y: max(0, drag))
        .gesture(DragGesture().onChanged { v in if v.translation.height > 0 { drag = v.translation.height; paused = true } }
            .onEnded { v in if v.translation.height > 120 { dismiss() } else { withAnimation(.snappy) { drag = 0 }; paused = false } })
        .statusBarHidden()
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if paused || typing || seenBy != nil || adding != nil || managing != nil { continue }
                progress += 0.05 / length
                if progress >= 1 { next(); return }
            }
        }
        .onAppear { if slides.isEmpty { dismiss() } }
    }

    private func bars(_ n: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<n, id: \.self) { i in
                GeometryReader { g in
                    Capsule().fill(.white.opacity(0.3))
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * (i < slide ? 1 : i == slide ? progress : 0)) }
                }
                .frame(height: 3)
            }
        }
        .padding(.top, 6)
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
            Text("today").font(.subheadline).foregroundStyle(.white.opacity(0.65))
            Spacer()
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
    }

    @ViewBuilder private func content(_ s: Slide) -> some View {
        switch s {
        case .snap(let st):
            // 9:16, the editor's shape, so everything placed lands where it was put
            ZStack {
                if str(st["kind"]) == "video", let url = URL(string: str(st["media"])) { LoopingVideo(url: url, paused: paused || seenBy != nil) }
                else { FeedPhoto(src: str(st["media"]), fill: true) }
                StoryLayer(items: list(st["overlays"]).filter { !["poll", "question"].contains(str($0["type"])) }, story: str(st["id"]))
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
                Text("What \(isMe ? "you" : Feed.shared.name(who)) had").font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(Theme.heroLabel).textCase(.uppercase).padding(.top, 8)
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
            .padding(22)
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
            .padding(22)
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
                    Text(str(st["audience"]) == "friends" ? "Close friends" : "Your story").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                    // a dialog that pauses the story: a menu kept playing, moved to the next slide, and its Delete did nothing
                    Button { managing = st } label: { Image(systemName: "ellipsis").font(.title3).foregroundStyle(.white).padding(10) }
                        .accessibilityLabel("Story options")
                }
                .frame(height: 44).padding(.horizontal, 8)
                .sheet(item: Binding(get: { seenBy.map { PostBox(post: $0) } }, set: { seenBy = $0?.post })) { b in SeenBySheet(story: b.post).presentationDetents([.medium, .large]) }
                .sheet(item: Binding(get: { adding.map { PostBox(post: $0) } }, set: { adding = $0?.post })) { b in AddToHighlight(story: b.post).presentationDetents([.medium, .large]) }
                .confirmationDialog("Your story", isPresented: Binding(get: { managing != nil }, set: { if !$0 { managing = nil } }), presenting: managing) { m in
                    Button("Add to highlight") { managing = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { adding = m } }
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
                Text("Your day, as friends see it").font(.footnote).foregroundStyle(.white.opacity(0.6)).frame(height: 44)
            }
        } else {
            HStack(spacing: 12) {
                TextField("", text: $reply, prompt: Text(sent ? "Sent" : "Send \(Feed.shared.name(who)) a message…").foregroundStyle(.white.opacity(0.7)))
                    .focused($typing).foregroundStyle(.white).submitLabel(.send).onSubmit { send() }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .overlay(Capsule().stroke(.white.opacity(0.55), lineWidth: 1.5))
                switch s {
                case .snap(let st):
                    Button { Task { await Stories.shared.react(st, "❤️") } } label: { Image(systemName: "heart").font(.system(size: 24)).foregroundStyle(.white) }
                        .accessibilityLabel("Like")
                case .post(let p):
                    let liked = Feed.shared.reactions.contains { str($0["post_id"]) == str(p["id"]) && str($0["user_id"]) == Feed.shared.me && str($0["emoji"]) == "❤️" }
                    Button { Task { await Feed.shared.toggle(p, "❤️") } } label: {
                        Image(systemName: liked ? "heart.fill" : "heart").font(.system(size: 24)).foregroundStyle(liked ? Color(red: 1, green: 0.3, blue: 0.4) : .white)
                    }
                    .accessibilityLabel(liked ? "Unlike" : "Like")
                default:
                    if let person = Friends.shared.people.first(where: { $0.id == who }) {
                        let done = Friends.shared.cheered.contains(person.id)
                        Button { Task { await Friends.shared.cheer(person) } } label: { Text("🎉").font(.system(size: 24)).opacity(done ? 0.4 : 1) }
                            .disabled(done).accessibilityLabel("Cheer")
                    }
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
    }

    private func send() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        reply = ""; typing = false; sent = true
        Task { await Messages.shared.send(to: who, text: t) }
    }

    private func next() {
        if slide + 1 < slides.count { slide += 1; return }
        Self.markSeen(who)
        if at + 1 < people.count { at += 1; slide = 0 } else { dismiss() }
    }
    private func back() {
        if slide > 0 { slide -= 1 } else if at > 0 { at -= 1; slide = 0 } else { progress = 0 }
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
