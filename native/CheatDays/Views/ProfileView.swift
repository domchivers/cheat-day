import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI

/// Someone's profile, social-app style: photo, counts, name and @username, bio, tags and pinned badges, then their
/// posts as a grid. Yours has Edit and Share; anyone else's has Follow and Message, and a friend's their week and their day. Never weight.
struct ProfileView: View {
    let id: String
    /// The Me tab: your own profile, with Your progress under the bio and Settings at the top.
    var home = false
    @State private var posts: [JSON] = []
    @State private var tab = 0
    @State private var editing = false
    @State private var openAt: Int?   // a post tapped in the grid: the posts from there, as on the feed
    @State private var chatting = false
    @State private var friendsOnly = false   // Message on someone who isn't a friend yet
    @State private var reporting = false
    @State private var removing = false
    @State private var showCode = false
    @State private var honorsOpen = false
    @State private var counts: (followers: Int, following: Int)?
    @State private var choosing = false   // public or private, the first time you see your profile
    @State private var friendNote: String?
    @Environment(\.dismiss) private var dismiss
    private var profiles: Profiles { Profiles.shared }
    private var store: Store { Store.shared }
    private var isMe: Bool { id == profiles.me }
    private var person: Friends.Person? { Friends.shared.people.first { $0.id == id } }
    private var p: Profiles.Profile? { profiles.all[id] }
    private var follows: Follows { Follows.shared }
    /// A private profile you're not a friend of and don't follow: name, photo, bio and counts only.
    private var locked: Bool { !isMe && person == nil && (p?.isPrivate ?? true) && follows.state(id) != .following }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 18).padding(.top, 8)
                // highlights: stories kept on the profile, like Instagram's circles
                if !locked { HighlightsRow(owner: id).padding(.top, 14) }
                if locked {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("This profile is private").font(.headline)
                        Text("Follow \(p?.name ?? "them") to see their posts.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 44)
                } else {
                Picker("Show", selection: $tab) {
                    Image(systemName: "square.grid.3x3").tag(0)
                    Image(systemName: "trophy").tag(1)
                    if person != nil { Image(systemName: "fork.knife").tag(2) }   // their food today, like the Today tab
                }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                switch tab {
                case 1: badges.padding(.horizontal, 16)
                case 2: today.padding(.horizontal, 16)
                default: grid
                }
                }
            }
            .padding(.bottom, 110)
        }
        .background(Theme.bg)
        .navigationTitle(p.map { $0.username.isEmpty ? $0.name : "@\($0.username)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if home {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
            }
            if !isMe {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { profiles.toggleMute(id) } label: { Label(profiles.muted.contains(id) ? "Unmute their posts" : "Mute their posts", systemImage: "speaker.slash") }
                        if follows.followsMe(id) { Button { Task { await follows.remove(id) } } label: { Label("Remove as a follower", systemImage: "person.fill.xmark") } }
                        Button { reporting = true } label: { Label("Report", systemImage: "flag") }
                        if follows.blocked.contains(id) { Button { Task { await follows.unblock(id) } } label: { Label("Unblock", systemImage: "hand.raised.slash") } }
                        else { Button(role: .destructive) { Task { await follows.block(id); dismiss() } } label: { Label("Block", systemImage: "hand.raised") } }
                        if let person { Button(role: .destructive) { removing = true } label: { Label("Remove \(person.name) as a friend", systemImage: "person.badge.minus") } }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .task {
            await reload()
            if isMe, profiles.mine?.privacyChosen == false { choosing = true }
        }
        .sheet(isPresented: $choosing) { PrivacyChoiceSheet().interactiveDismissDisabled() }
        .refreshable { await reload() }
        .sheet(isPresented: $editing) { EditProfileView() }
        .sheet(isPresented: $showCode) { MyCodeSheet().presentationDetents([.large]) }
        .sheet(isPresented: $honorsOpen) { HonorsSheet(theirs: p?.honors ?? [], name: isMe ? "Your" : (p?.name ?? "")).presentationDetents([.medium, .large]) }
        .navigationDestination(item: $openAt) { i in
            FeedView(only: posts, startAt: posts.indices.contains(i) ? str(posts[i]["id"]) : nil).navigationTitle("Posts").navigationBarTitleDisplayMode(.inline)
        }
        .navigationDestination(isPresented: $chatting) { ChatView(friend: id) }
        .alert("Messages are for friends", isPresented: $friendsOnly) { Button("OK", role: .cancel) {} } message: {
            Text("Scan each other's code in Add a friend, then you can message.")
        }
        .confirmationDialog("Report \(p?.name ?? "them")?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(["Spam", "Something hurtful", "Pretending to be someone", "Something else"], id: \.self) { r in
                Button(r) { Task { await profiles.report(id, reason: r) } }
            }
        } message: { Text("It goes to the app's owner. They won't know it was you.") }
        .confirmationDialog("Remove \(person?.name ?? "them") as a friend?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { if let person { await profiles.removeFriend(person) }; dismiss() } }
        } message: { Text("You'll stop seeing each other's days, posts and messages.") }
    }

    private func reload() async {
        await Task { await profiles.load([id], force: true) }.value
        if let got = await profiles.posts(of: id) { posts = got; await Feed.shared.loadExtras(got) }
        if let c = await Task(operation: { await follows.counts(id) }).value { counts = c }
    }

    // MARK: the top

    private var header: some View {
        let name = isMe ? (Friends.shared.myName.isEmpty ? "Me" : Friends.shared.myName) : (p?.name ?? person?.name ?? "")
        let streak = isMe ? store.streakInfo.days : (person?.streak ?? 0)
        let level = isMe ? store.rank.level : (person?.level ?? 0)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Avatar(id: id, size: 86, ring: true, dot: !isMe)
                    .overlay(alignment: .bottomTrailing) {
                        if isMe {
                            Image(systemName: "camera.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                                .frame(width: 26, height: 26).background(Theme.accent, in: Circle()).overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                        }
                    }
                    .onTapGesture { if isMe { editing = true } }
                HStack {
                    count(locked ? "–" : "\(posts.count)", posts.count == 1 ? "post" : "posts")
                    count("\(counts?.followers ?? 0)", counts?.followers == 1 ? "follower" : "followers")
                    count("\(counts?.following ?? 0)", "following")
                }
            }
            HStack(spacing: 8) {
                Text(name).font(.title3.weight(.heavy))
                if p?.isPrivate == true { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                if streak > 1 { HStack(spacing: 2) { FluentIcon(emoji: "🔥", size: 14); Text("\(streak)").font(.subheadline.weight(.heavy)).foregroundStyle(.orange) } }
                if level > 0 {
                    let r = Rank(level: level)
                    HStack(spacing: 4) { RankBadge(rank: r, size: 14); Text(r.name).font(.caption.weight(.bold)) }
                        .foregroundStyle(r.color).padding(.horizontal, 8).padding(.vertical, 3).background(r.color.opacity(0.14), in: Capsule())
                }
            }
            .padding(.top, 12)
            if !profiles.handle(id).isEmpty { Text(profiles.handle(id)).font(.subheadline).foregroundStyle(.secondary) }
            // their tag on its own line under the name (tap it for all of theirs), then their label in grey where
            // Instagram has "Artist", then the bio
            if let h = p?.shownHonor { Button { honorsOpen = true } label: { HonorText(honor: h) }.buttonStyle(.plain).accessibilityLabel(h.title).padding(.top, 2) }
            if let l = p?.label, !l.isEmpty { Text(l).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).padding(.top, 3) }
            if let bio = p?.bio, !bio.isEmpty { Text(bio).font(.subheadline).padding(.top, 4) }
            else if isMe { Button("Add a bio") { editing = true }.font(.subheadline).padding(.top, 4) }
            buttons.padding(.top, 13)
            if home && isMe { progressCard.padding(.top, 12) }
            if !isMe, p?.showWeek ?? true, let person { week(person).padding(.top, 12) }
            let pins = (p?.pinned ?? []).compactMap { pid in Badge.all.first { $0.id == pid } }
            if !pins.isEmpty {
                HStack(spacing: 14) {
                    ForEach(pins.prefix(4), id: \.id) { b in
                        VStack(spacing: 4) { BadgeCoin(badge: b, size: 52); Text(b.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }.frame(width: 62)
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    private func count(_ n: String, _ label: String, fire: Bool = false) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) { if fire { FluentIcon(emoji: "🔥", size: 16) }; Text(n).font(.headline.weight(.heavy)) }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if isMe {
                pill("Edit profile") { editing = true }
                pill("Share profile") { showCode = true }
            } else {
                // Follow (or Following) and Message, like Instagram; no Cheer. Becoming friends is scanning each other's
                // code, never a button here, and messages are between friends
                let st = follows.state(id)
                Button { Task { if st == .none { await follows.follow(id) } else { await follows.unfollow(id) }; counts = await follows.counts(id) } } label: {
                    Text(st == .following ? "Following" : st == .requested ? "Requested" : follows.followsMe(id) ? "Follow back" : "Follow")
                        .font(.subheadline.weight(.bold)).foregroundStyle(st == .none ? Theme.onAccent : .primary)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(st == .none ? Theme.accent : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                pill("Message") { if person != nil { chatting = true } else { friendsOnly = true } }
            }
        }
    }


    /// Your weight and goal, the week and your rank in a line, opening everything Me used to show.
    private var progressCard: some View {
        let kg = store.lastWeighIn?.kg ?? store.latestWeight?.kg, goal = pos(store.doc["goalWeight"])
        let week = store.weekDates.map(store.dayFacts).filter(\.logged), ok = week.filter(store.underBudget).count
        var bits: [String] = []
        if let kg { bits.append(goal.map { "\(Fmt.kg(kg)) → \(Fmt.kg($0)) kg" } ?? "\(Fmt.kg(kg)) kg") }
        if !week.isEmpty { bits.append("\(ok) of \(week.count) on budget") }
        bits.append(store.rank.name)
        return NavigationLink { ProgressDashboard() } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your progress").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    Text(bits.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func week(_ person: Friends.Person) -> some View {
        let w = person.week, ok = w.filter { $0 == 1 }.count
        let days = (0..<7).reversed().map { DayKey.date(DayKey.shift(DayKey.string(Date()), days: -$0)).formatted(.dateTime.weekday(.narrow)) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("THIS WEEK").font(.caption2.weight(.heavy)).tracking(1.4).foregroundStyle(.secondary)
                Spacer()
                (Text("\(ok)").font(.subheadline.weight(.heavy)) + Text(" of 7 on budget").font(.subheadline).foregroundStyle(.secondary))
            }
            HStack(spacing: 0) {
                ForEach(w.indices, id: \.self) { i in
                    VStack(spacing: 6) {
                        Circle().fill(w[i] == 1 ? Theme.walk : w[i] == 0 ? Color(.tertiarySystemFill) : Theme.warn).frame(width: 9, height: 9)
                        Text(days[i]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: the tabs

    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
        return Group {
            if posts.isEmpty {
                Text(isMe ? "Your posts show here. Tap ＋ on the feed to share one." : "No posts yet.")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
            } else {
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(keyed(posts)) { e in cell(e.item) }
                }
            }
        }
    }

    private func cell(_ post: JSON) -> some View {
        let photo = str(post["photo"]), kind = str(post["kind"])
        let label = kind == "workout" ? "\(Int(num(dict(post["extra"])["minutes"]) ?? 0)) min" : kind == "moment" ? "" : Fmt.int(num(post["kcal"]) ?? 0)
        return Button { openAt = posts.firstIndex { str($0["id"]) == str(post["id"]) } } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    if Feed.hasPhoto(post) { FeedPhoto(src: photo, fill: true) }
                    else {
                        ZStack {
                            LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            if kind == "moment" { FluentIcon(emoji: str(dict(post["extra"])["emoji"]).isEmpty ? "🏆" : str(dict(post["extra"])["emoji"]), size: 44) }
                            else { FoodDot(name: kind == "workout" ? "Workout" : str(post["name"]), size: 50) }
                        }
                    }
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if !label.isEmpty {
                        Text(label).font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5)).padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var badges: some View {
        let list: [Badge] = isMe ? Badge.all.filter { store.seenBadges.contains($0.id) || $0.earned(store.badgeStats) }
                                 : (p?.pinned ?? []).compactMap { pid in Badge.all.first { $0.id == pid } }
        if list.isEmpty {
            Text(isMe ? "Badges you earn show here." : "They haven't pinned any badges.").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: 4), spacing: 14) {
                ForEach(list, id: \.id) { b in
                    // the name gets room for two lines in every cell, so a long one doesn't push its coin up
                    VStack(spacing: 4) {
                        BadgeCoin(badge: b, size: 58)
                        Text(b.name).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.top, 8)
        }
    }

    /// Their day so far, as on People.
    @ViewBuilder private var today: some View {
        let food = person?.food ?? []
        if food.isEmpty { Text("Nothing shared today yet.").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30) }
        ForEach(Meals.all, id: \.self) { meal in
            let its = food.filter { (str($0["meal"]).isEmpty ? Meals.of($0) : str($0["meal"])) == meal }
            if !its.isEmpty {
                Eyebrow(text: meal).padding(.top, 10)
                ForEach(its.indices, id: \.self) { i in
                    HStack {
                        FoodDot(name: str(its[i]["name"]), size: 28)
                        Text(str(its[i]["name"])).font(.subheadline)
                        Spacer()
                        Text(Fmt.int(num(its[i]["kcal"]) ?? 0)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// Your photo, name, @username, bio, tags and pinned badges, and whether friends see your week.
struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var pinned: [String] = []
    @State private var showWeek = true
    @State private var isPrivate = true
    @State private var label = ""
    @State private var topHonor = ""
    @State private var showHonors = true
    private static let labels = ["Personal trainer", "Athlete", "Home cook", "Chef", "Nutritionist", "Bodybuilder", "Runner", "Powerlifter", "Creator", "Student"]
    @State private var framing: CropBox?   // a photo being moved and zoomed in the circle
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
    @State private var library = false
    @State private var busy = false
    @State private var taken = false
    @State private var problem: String?
    private var profiles: Profiles { Profiles.shared }
    private var store: Store { Store.shared }
    private static let suggestions = ["💪 Lifting", "🏃 Running", "🥗 Meal prep", "🍜 Loves a noodle", "🌱 Plant based", "🍰 Sweet tooth", "🧘 Yoga", "🚴 Cycling"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Menu {
                            Button { camera = true } label: { Label("Take a photo", systemImage: "camera") }
                            Button { library = true } label: { Label("Choose from library", systemImage: "photo.on.rectangle") }
                            if !profiles.avatar(profiles.me).isEmpty {
                                Button { Task { await reframe() } } label: { Label("Edit", systemImage: "crop") }
                            }
                        } label: {
                            Avatar(id: profiles.me, size: 96)
                                .padding(4).overlay(Circle().stroke(Theme.accent, lineWidth: 3))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "camera.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.onAccent)
                                        .frame(width: 32, height: 32).background(Theme.accent, in: Circle())
                                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 3))
                                }
                                .frame(maxWidth: .infinity)
                                .overlay(alignment: .bottom) { Text("Edit picture").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent).offset(y: 30) }
                                .padding(.bottom, 30)
                        }
                        .accessibilityLabel("Change your photo")
                        .padding(.top, 6)
                        Spacer()
                    }
                }
                Section {
                    NavigationLink { FieldPage(title: "Name", text: $name, placeholder: "Your name", limit: 30) } label: { row("Name", name) }
                    NavigationLink {
                        FieldPage(title: "Username", text: $username, placeholder: "username", limit: 20, prefix: "@", clean: Profiles.clean,
                                  footer: "3 to 20 letters, numbers, dots or underscores. Friends can find you by it.")
                    } label: { row("Username", username.isEmpty ? "" : "@" + username) }
                    NavigationLink {
                        FieldPage(title: "Label", text: $label, placeholder: "Founder of Cheat Days, Personal trainer…", limit: 30, chips: Self.labels,
                                  footer: "In grey under your name, like Instagram's.")
                    } label: { row("Label", label) }
                    NavigationLink { FieldPage(title: "Bio", text: $bio, placeholder: "A line about you", limit: 150, lines: true) } label: { row("Bio", bio) }
                } footer: { if taken { Text("That @name is taken.").foregroundStyle(Theme.warn) } }
                Section("On your profile") {
                    let mine = (profiles.mine?.honors ?? []).compactMap(Honor.find)
                    if !mine.isEmpty {
                        NavigationLink { HonorPickPage(mine: mine, top: $topHonor, show: $showHonors) } label: {
                            HStack {
                                Text("Your tag").frame(width: 96, alignment: .leading)
                                if showHonors, let h = mine.first(where: { $0.id == topHonor }) ?? mine.first { HonorText(honor: h) } else { Text("Hidden").foregroundStyle(.secondary) }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    NavigationLink { PinBadgesView(pinned: $pinned) } label: { row("Badges", pinned.isEmpty ? "None pinned" : "\(pinned.count) pinned", quiet: true) }
                }
                Section {
                    Toggle("Private profile", isOn: $isPrivate)
                    Toggle("Friends see my week", isOn: $showWeek)
                } header: { Text("Privacy") } footer: {
                    Text(isPrivate ? "People ask to follow you. Your food log is always friends only." : "Anyone can follow you and see your posts. Your food log is always friends only.")
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
            }
            .navigationTitle("Edit profile").navigationBarTitleDisplayMode(.inline)
            .photosPicker(isPresented: $library, selection: $picked, matching: .images)
            .keyboardDone()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(busy ? "Saving…" : "Save") { save() }.fontWeight(.bold).disabled(busy) }
            }
            .onAppear {
                let p = profiles.mine
                name = p?.name ?? Friends.shared.myName; username = p?.username ?? ""; bio = p?.bio ?? ""
                tags = p?.tags ?? []; pinned = p?.pinned ?? []; showWeek = p?.showWeek ?? true; isPrivate = p?.isPrivate ?? true
                label = p?.label ?? ""; showHonors = p?.showHonors ?? true
                topHonor = p?.shownHonor?.id ?? p?.honors.first ?? ""
            }
            .onChange(of: picked) { _, item in Task { if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { await photo(img) } } }
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Task { await photo(img) } } } }.ignoresSafeArea() }
            .fullScreenCover(item: $framing) { box in AvatarCropView(image: box.image) { out in framing = nil; if let out { Task { await upload(out) } } } }
        }
    }

    /// One row: what it is, then what it's set to (grey when it's empty).
    private func row(_ k: String, _ v: String, quiet: Bool = false) -> some View {
        HStack {
            Text(k).frame(width: 96, alignment: .leading)
            Text(v.isEmpty ? "Add" : v).foregroundStyle(v.isEmpty || quiet ? .secondary : .primary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func add(_ t: String) {
        let s = String(t.trimmingCharacters(in: .whitespaces).prefix(24))
        guard !s.isEmpty, tags.count < 3, !tags.contains(s) else { return }
        tags.append(s); newTag = ""
    }
    private func toggle(_ id: String) {
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) } else if pinned.count < 4 { pinned.append(id) }
    }
    /// A new photo: frame it in the circle first.
    private func photo(_ img: UIImage) async {
        Profiles.original = img
        framing = CropBox(image: img)
    }
    /// Move and zoom the photo you have: the whole one if this phone kept it, else the round one.
    private func reframe() async {
        if let o = Profiles.original { framing = CropBox(image: o); return }
        guard let url = URL(string: profiles.avatar(profiles.me)), let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d) else { return }
        framing = CropBox(image: img)
    }
    private func upload(_ img: UIImage) async {
        busy = true; defer { busy = false }
        if !(await profiles.setPhoto(img)) { problem = profiles.error }
    }
    private func save() {
        busy = true; problem = nil
        Task {
            defer { busy = false }
            let u = Profiles.clean(username)
            if !u.isEmpty, u.count < 3 { problem = "An @name needs at least 3 characters."; return }
            if !u.isEmpty, let why = Profiles.problem(u, username: true) { problem = why; return }
            if let why = Profiles.problem(name, username: false) { problem = why; return }
            if let why = Profiles.problem(label, username: false) { problem = why.replacingOccurrences(of: "name", with: "label"); return }
            if !u.isEmpty, await profiles.taken(u) { taken = true; return }
            taken = false
            let change: JSON = ["display_name": name.trimmingCharacters(in: .whitespaces).isEmpty ? Friends.shared.myName : name.trimmingCharacters(in: .whitespaces),
                                "username": u.isEmpty ? NSNull() : u, "bio": bio.trimmingCharacters(in: .whitespacesAndNewlines),
                                "tags": tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, "pinned": pinned, "show_week": showWeek, "private": isPrivate, "privacy_chosen": true,
                                "label": label.trimmingCharacters(in: .whitespaces), "top_honor": topHonor, "show_honors": showHonors]
            if await profiles.save(change) { dismiss() } else { problem = profiles.error }
        }
    }
}

/// Your QR code: friends scan it with the app (Add a friend) or the Camera app, which opens Cheat Days on Add a
/// friend with your code in. Your friend code and @name to send as well.
struct MyCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var message: String?
    private var profiles: Profiles { Profiles.shared }
    private var code: String { Friends.shared.myCode }
    private var link: String { "cheatdays://friend/" + code }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                VStack(spacing: 14) {
                    Avatar(id: profiles.me, size: 64)
                    VStack(spacing: 2) {
                        Text(Friends.shared.myName).font(.title3.weight(.heavy))
                        if !profiles.handle(profiles.me).isEmpty { Text(profiles.handle(profiles.me)).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    if let qr = Self.qr(link) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                            .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    Text(code).font(.title2.weight(.heavy)).monospaced()
                }
                .padding(24).frame(maxWidth: .infinity)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 24)
                Text("Friends scan it in Add a friend, or with their iPhone's camera.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                Spacer()
                HStack(spacing: 10) {
                    ShareLink(item: "Add me on Cheat Days\(profiles.handle(profiles.me).isEmpty ? "" : " (\(profiles.handle(profiles.me)))"): my friend code is \(code)") {
                        Label("Share", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button { scanning = true } label: {
                        Label("Scan theirs", systemImage: "qrcode.viewfinder").font(.headline).foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .buttonStyle(.plain).padding(.horizontal, 20)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(.bottom, 16)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Your code").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $scanning) {
                QRScanView { found in
                    scanning = false
                    Task { message = await Friends.shared.add(code: found) }
                }
            }
        }
    }

    static func qr(_ text: String) -> UIImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The camera reading a friend's QR code: calls back with their friend code.
struct QRScanView: View {
    var found: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wrong = false

    var body: some View {
        ZStack {
            BarcodeScanner(onCode: { s in
                if let c = Self.code(s) { found(c) } else { wrong = true }
            }, types: [.qr]).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.85), lineWidth: 3).frame(width: 240, height: 240)
            VStack {
                HStack { Spacer(); Button("Cancel") { dismiss() }.font(.headline).foregroundStyle(.white).padding(20) }
                Spacer()
                Text(wrong ? "That isn't a Cheat Days code." : "Point at your friend's code").font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.55), in: Capsule()).padding(.bottom, 50)
            }
        }
    }

    /// "cheatdays://friend/DOM-1234", or a bare code.
    static func code(_ s: String) -> String? {
        if let u = URL(string: s), u.scheme == "cheatdays", u.host == "friend" { let c = u.lastPathComponent; return c.isEmpty || c == "/" ? nil : c }
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        return t.range(of: #"^[A-Z]{3}-\d{4}$"#, options: .regularExpression) != nil ? t : nil
    }
}

/// The last step of setting up your profile: who can see your posts. Asked once; Edit profile changes it.
struct PrivacyChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isPrivate = true
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who can see your posts?").font(.title.bold()).padding(.top, 30)
            Text("Friends always see your day and your posts. This is about everyone else.").foregroundStyle(.secondary)
            option(true, "lock.fill", "Private", "People ask to follow you, and you say yes or no. Until then they see only your name, photo and bio.")
            option(false, "globe", "Public", "Anyone can follow you and see your posts and badges, and your posts can show on Explore. Your day, your week and your food log stay friends only.")
            Text("You can change this any time in Edit profile.").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button {
                busy = true
                Task { _ = await Profiles.shared.save(["private": isPrivate, "privacy_chosen": true]); busy = false; dismiss() }
            } label: { Text(busy ? "Saving…" : "Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 16)).foregroundStyle(Theme.onAccent).disabled(busy)
        }
        .padding(20)
        .background(Theme.bg.ignoresSafeArea())
    }

    private func option(_ value: Bool, _ icon: String, _ title: String, _ text: String) -> some View {
        Button { isPrivate = value } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isPrivate == value ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(isPrivate == value ? Theme.accent : .secondary)
            }
            .padding(16)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(isPrivate == value ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// Find people: by @name or name, and below that people your friends follow.
struct FindPeopleView: View {
    @State private var q = ""
    @State private var found: [Profiles.Profile] = []
    @State private var suggested: [(id: String, via: String, n: Int)] = []
    private var follows: Follows { Follows.shared }

    var body: some View {
        List {
            if !found.isEmpty { Section("Results") { ForEach(found, id: \.id) { p in row(p.id, detail: Profiles.shared.handle(p.id)) } } }
            else if q.count >= 2 { Text("No one by that name.").foregroundStyle(.secondary) }
            if !suggested.isEmpty {
                Section("From your friends") {
                    ForEach(suggested, id: \.id) { s in
                        row(s.id, detail: "Followed by \(Feed.shared.name(s.via))\(s.n > 1 ? " and \(s.n - 1) more" : "")")
                    }
                }
            }
            if let e = follows.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
        }
        .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "@name or name")
        .task(id: q) {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { found = await follows.search(q) }
        }
        .task { await follows.load(); suggested = await follows.suggestions() }
        .navigationTitle("Find people").navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ id: String, detail: String) -> some View {
        let st = follows.state(id), friend = Friends.shared.people.contains { $0.id == id }
        return HStack(spacing: 12) {
            NavigationLink { ProfileView(id: id) } label: {
                HStack(spacing: 12) {
                    Avatar(id: id, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(Profiles.shared.all[id]?.name ?? Feed.shared.name(id)).font(.subheadline.weight(.bold))
                            if Profiles.shared.all[id]?.isPrivate == true { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                        }
                        if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            if !friend {
                Button(st == .following ? "Following" : st == .requested ? "Requested" : "Follow") {
                    Task { if st == .none { await follows.follow(id) } else { await follows.unfollow(id) } }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .tint(st == .none ? Theme.accent : Color(.tertiarySystemFill)).foregroundStyle(st == .none ? Theme.onAccent : .primary)
            }
        }
    }
}

struct CropBox: Identifiable { let id = UUID(); let image: UIImage }

/// Move and zoom a photo in the circle, the way it'll show on your profile. Drag to move, pinch to zoom.
struct AvatarCropView: View {
    let image: UIImage
    var done: (UIImage?) -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height) - 48
            let fill = side / max(1, min(image.size.width, image.size.height))
            let w = image.size.width * fill * scale, h = image.size.height * fill * scale
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image).resizable().frame(width: w, height: h).offset(offset)
                    .frame(width: g.size.width, height: g.size.height).clipped()
                // dim everything outside the circle
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: g.size))
                    p.addEllipse(in: CGRect(x: (g.size.width - side) / 2, y: (g.size.height - side) / 2, width: side, height: side))
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: side, height: side).allowsHitTesting(false)
                VStack {
                    Text("Edit").font(.headline).foregroundStyle(.white).padding(.top, 20)
                    Spacer()
                    HStack {
                        Button("Cancel") { done(nil) }.foregroundStyle(.white)
                        Spacer()
                        Button("Choose") { done(crop(side: side, fill: fill)) }.fontWeight(.bold).foregroundStyle(Theme.accent)
                    }
                    .font(.headline).padding(.horizontal, 28).padding(.bottom, 30)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in offset = clamp(CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height), w: w, h: h, side: side) }
                    .onEnded { _ in lastOffset = offset }
                    .simultaneously(with: MagnificationGesture()
                        .onChanged { m in
                            scale = min(5, max(1, lastScale * m))
                            offset = clamp(offset, w: image.size.width * fill * scale, h: image.size.height * fill * scale, side: side)
                        }
                        .onEnded { _ in lastScale = scale; lastOffset = offset })
            )
        }
        .statusBarHidden()
    }

    /// Keep the circle covered: the photo can't be moved past its edges.
    private func clamp(_ o: CGSize, w: CGFloat, h: CGFloat, side: CGFloat) -> CGSize {
        let mx = max(0, (w - side) / 2), my = max(0, (h - side) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    /// What's inside the circle, as a 640 px square.
    private func crop(side: CGFloat, fill: CGFloat) -> UIImage {
        let s = fill * scale, visible = side / s
        let cx = image.size.width / 2 - offset.width / s, cy = image.size.height / 2 - offset.height / s
        let x0 = cx - visible / 2, y0 = cy - visible / 2, k = 640 / visible
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { _ in
            image.draw(in: CGRect(x: -x0 * k, y: -y0 * k, width: image.size.width * k, height: image.size.height * k))
        }
    }
}

/// Every badge you've earned, to pin up to four: tap to pin, tap again to unpin.
struct PinBadgesView: View {
    @Binding var pinned: [String]
    private var store: Store { Store.shared }

    var body: some View {
        let earned = Badge.all.filter { store.seenBadges.contains($0.id) || $0.earned(store.badgeStats) }
        ScrollView {
            Text("\(pinned.count) of 4 pinned").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
            if earned.isEmpty { Text("Earn a badge to pin it.").foregroundStyle(.secondary).padding(.top, 30) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: 4), spacing: 16) {
                ForEach(earned, id: \.id) { b in
                    let on = pinned.contains(b.id), full = pinned.count >= 4
                    Button {
                        if on { pinned.removeAll { $0 == b.id } } else if !full { pinned.append(b.id) }
                    } label: {
                        VStack(spacing: 4) {
                            BadgeCoin(badge: b, size: 58, got: on || !full)
                                .overlay(alignment: .topTrailing) {
                                    if on { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent).background(Theme.bg, in: Circle()).offset(x: 4, y: -4) }
                                }
                            Text(b.name).font(.caption2).foregroundStyle(on ? .primary : .secondary).lineLimit(2).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
                        }
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: on)
                    .accessibilityLabel(on ? "Unpin \(b.name)" : "Pin \(b.name)")
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("Pin badges").navigationBarTitleDisplayMode(.inline)
    }
}

/// One thing to type, on its own page from Edit profile: the box, how many letters are left, and for a label the
/// ready-made ones to pick.
struct FieldPage: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var limit = 30
    var prefix = ""
    var clean: ((String) -> String)? = nil
    var chips: [String] = []
    var lines = false
    var footer = ""
    @FocusState private var on: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 2) {
                    if !prefix.isEmpty { Text(prefix).foregroundStyle(.secondary) }
                    TextField(placeholder, text: $text, axis: lines ? .vertical : .horizontal).lineLimit(lines ? 3...6 : 1...1).focused($on)
                        .textInputAutocapitalization(prefix.isEmpty ? .sentences : .never).autocorrectionDisabled(!prefix.isEmpty)
                        .onChange(of: text) { _, t in
                            var t2 = clean?(t) ?? t
                            if t2.count > limit { t2 = String(t2.prefix(limit)) }
                            if t2 != t { text = t2 }
                        }
                }
            } footer: {
                HStack(alignment: .top) {
                    Text(footer)
                    Spacer()
                    Text("\(text.count) / \(limit)").monospacedDigit()
                }
            }
            if !chips.isEmpty {
                Section("Or pick one") {
                    Flow { ForEach(chips, id: \.self) { c in Chip(text: c, on: c == text) { text = c } } }
                }
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onAppear { on = true }
    }
}

/// Which of your tags shows by your name, or none.
struct HonorPickPage: View {
    let mine: [Honor]
    @Binding var top: String
    @Binding var show: Bool

    var body: some View {
        Form {
            Section {
                ForEach(mine) { h in
                    Button { top = h.id; show = true } label: {
                        HStack {
                            HonorText(honor: h)
                            Text(h.what).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            if show && top == h.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button { show = false } label: {
                    HStack { Text("Don't show a tag"); Spacer(); if !show { Image(systemName: "checkmark").foregroundStyle(Theme.accent) } }
                }
                .buttonStyle(.plain)
            } footer: { Text("Tags are given, not chosen. Pick which one shows by your name.") }
        }
        .navigationTitle("Your tag").navigationBarTitleDisplayMode(.inline)
    }
}
