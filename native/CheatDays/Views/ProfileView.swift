import PhotosUI
import SwiftUI

/// Someone's profile, social-app style: photo, counts, name and @username, bio, tags and pinned badges, then their
/// posts as a grid. Yours has Edit and Share; a friend's has Message, Cheer, their week and their day. Never weight.
struct ProfileView: View {
    let id: String
    @State private var posts: [JSON] = []
    @State private var tab = 0
    @State private var editing = false
    @State private var opened: PostBox?
    @State private var chatting = false
    @State private var reporting = false
    @State private var removing = false
    @Environment(\.dismiss) private var dismiss
    private var profiles: Profiles { Profiles.shared }
    private var store: Store { Store.shared }
    private var isMe: Bool { id == profiles.me }
    private var person: Friends.Person? { Friends.shared.people.first { $0.id == id } }
    private var p: Profiles.Profile? { profiles.all[id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 18).padding(.top, 8)
                Picker("Show", selection: $tab) {
                    Image(systemName: "square.grid.3x3").tag(0)
                    Image(systemName: "trophy").tag(1)
                    if !isMe { Image(systemName: "sun.max").tag(2) }
                }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                switch tab {
                case 1: badges.padding(.horizontal, 16)
                case 2: today.padding(.horizontal, 16)
                default: grid
                }
            }
            .padding(.bottom, 110)
        }
        .background(Theme.bg)
        .navigationTitle(p.map { $0.username.isEmpty ? $0.name : "@\($0.username)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isMe, let person {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { profiles.toggleMute(id) } label: { Label(profiles.muted.contains(id) ? "Unmute their posts" : "Mute their posts", systemImage: "speaker.slash") }
                        Button { reporting = true } label: { Label("Report", systemImage: "flag") }
                        Button(role: .destructive) { removing = true } label: { Label("Remove \(person.name)", systemImage: "person.badge.minus") }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .task {
            await profiles.load([id], force: true)
            posts = await profiles.posts(of: id)
        }
        .refreshable { await profiles.load([id], force: true); posts = await profiles.posts(of: id) }
        .sheet(isPresented: $editing) { EditProfileView() }
        .sheet(item: $opened) { b in PostRecipeSheet(post: b.post) }
        .navigationDestination(isPresented: $chatting) { ChatView(friend: id) }
        .confirmationDialog("Report \(p?.name ?? "them")?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(["Spam", "Something hurtful", "Pretending to be someone", "Something else"], id: \.self) { r in
                Button(r) { Task { await profiles.report(id, reason: r) } }
            }
        } message: { Text("It goes to the app's owner. They won't know it was you.") }
        .confirmationDialog("Remove \(person?.name ?? "them") as a friend?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { if let person { await profiles.removeFriend(person) }; dismiss() } }
        } message: { Text("You'll stop seeing each other's days, posts and messages.") }
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
                    count("\(posts.count)", posts.count == 1 ? "post" : "posts")
                    count(isMe ? "\(Friends.shared.people.count)" : "\(level)", isMe ? "friends" : "level")
                    count("\(streak)", "day streak", fire: streak > 1)
                }
            }
            HStack(spacing: 8) {
                Text(name).font(.title3.weight(.heavy))
                if level > 0 {
                    let r = Rank(level: level)
                    HStack(spacing: 4) { RankBadge(rank: r, size: 14); Text(r.name).font(.caption.weight(.bold)) }
                        .foregroundStyle(r.color).padding(.horizontal, 8).padding(.vertical, 3).background(r.color.opacity(0.14), in: Capsule())
                }
            }
            .padding(.top, 12)
            if let bio = p?.bio, !bio.isEmpty { Text(bio).font(.subheadline).padding(.top, 4) }
            else if isMe { Button("Add a bio") { editing = true }.font(.subheadline).padding(.top, 4) }
            if let tags = p?.tags, !tags.isEmpty {
                Flow { ForEach(tags, id: \.self) { t in Text(t).font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 5).background(Color(.tertiarySystemFill), in: Capsule()) } }
                    .padding(.top, 9)
            }
            buttons.padding(.top, 13)
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
                ShareLink(item: shareText) { Text("Share profile").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 9).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12)) }
                    .buttonStyle(.plain)
            } else {
                Button { chatting = true } label: {
                    Label("Message", systemImage: "bubble.left.fill").font(.subheadline.weight(.bold)).foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 9).background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                if let person {
                    let done = Friends.shared.cheered.contains(person.id)
                    pill(done ? "🎉 Cheered" : "🎉 Cheer") { Task { await Friends.shared.cheer(person) } }.disabled(done)
                }
            }
        }
    }

    private var shareText: String {
        let handle = p.map { $0.username.isEmpty ? "" : " (@\($0.username))" } ?? ""
        return "Add me on Cheat Days\(handle): my friend code is \(Friends.shared.myCode)"
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
        return VStack(alignment: .leading, spacing: 8) {
            (Text("This week").bold() + Text(" · \(ok) of 7 on budget").foregroundStyle(.secondary)).font(.subheadline)
            HStack(spacing: 7) {
                ForEach(w.indices, id: \.self) { i in
                    Text(days[i]).font(.caption2.weight(.heavy))
                        .foregroundStyle(w[i] == 1 ? Theme.walk : w[i] == 0 ? .secondary : Theme.warn)
                        .frame(width: 30, height: 30)
                        .background((w[i] == 1 ? Theme.walk : w[i] == 0 ? Color.gray : Theme.warn).opacity(w[i] == 0 ? 0.15 : 0.22), in: Circle())
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        return Button { if kind != "moment" { opened = PostBox(post: post) } } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    if photo.hasPrefix("http") { FeedPhoto(src: photo, fill: true) }
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                ForEach(list, id: \.id) { b in
                    VStack(spacing: 4) { BadgeCoin(badge: b, size: 58); Text(b.name).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center) }
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
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
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
                        VStack(spacing: 10) {
                            Avatar(id: profiles.me, size: 96)
                            HStack(spacing: 18) {
                                Button { camera = true } label: { Label("Camera", systemImage: "camera") }.buttonStyle(.borderless)
                                PhotosPicker(selection: $picked, matching: .images) { Label("Library", systemImage: "photo") }.buttonStyle(.borderless)
                            }
                            .font(.subheadline)
                        }
                        Spacer()
                    }
                }
                Section {
                    TextField("Name", text: $name)
                    HStack(spacing: 2) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: username) { _, u in let c = Profiles.clean(u); if c != u { username = c } }
                    }
                } footer: {
                    if taken { Text("That @name is taken.").foregroundStyle(Theme.warn) }
                    else { Text("3 to 20 letters, numbers, dots or underscores. Friends can find you by it.") }
                }
                Section("Bio") {
                    TextField("A line about you", text: $bio, axis: .vertical).lineLimit(2...4)
                        .onChange(of: bio) { _, b in if b.count > 150 { bio = String(b.prefix(150)) } }
                }
                Section {
                    ForEach(tags, id: \.self) { t in Text(t) }.onDelete { tags.remove(atOffsets: $0) }
                    if tags.count < 3 {
                        HStack {
                            TextField("Add a tag", text: $newTag)
                            Button("Add") { add(newTag) }.disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Flow { ForEach(Self.suggestions.filter { !tags.contains($0) }, id: \.self) { s in Chip(text: s, on: false) { add(s) } } }
                    }
                } header: { Text("Tags") } footer: { Text("Up to 3, about what you're into. Nothing about weight shows on your profile.") }
                Section {
                    let earned = Badge.all.filter { store.seenBadges.contains($0.id) || $0.earned(store.badgeStats) }
                    if earned.isEmpty { Text("Earn a badge to pin it.").foregroundStyle(.secondary) }
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(earned, id: \.id) { b in
                                Button { toggle(b.id) } label: {
                                    BadgeCoin(badge: b, size: 50, got: pinned.contains(b.id) || pinned.count < 4)
                                        .overlay(alignment: .topTrailing) { if pinned.contains(b.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).background(Theme.bg, in: Circle()) } }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                } header: { Text("Pinned badges") } footer: { Text("Up to 4, on your profile.") }
                Section { Toggle("Friends see my week", isOn: $showWeek) } footer: { Text("The seven dots for on budget or over, on your profile. Messages are friends only.") }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
            }
            .navigationTitle("Edit profile").navigationBarTitleDisplayMode(.inline)
            .keyboardDone()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(busy ? "Saving…" : "Save") { save() }.fontWeight(.bold).disabled(busy) }
            }
            .onAppear {
                let p = profiles.mine
                name = p?.name ?? Friends.shared.myName; username = p?.username ?? ""; bio = p?.bio ?? ""
                tags = p?.tags ?? []; pinned = p?.pinned ?? []; showWeek = p?.showWeek ?? true
            }
            .onChange(of: picked) { _, item in Task { if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { await photo(img) } } }
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { Task { await photo(img) } } }.ignoresSafeArea() }
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
    private func photo(_ img: UIImage) async {
        busy = true; defer { busy = false }
        if !(await profiles.setPhoto(img)) { problem = profiles.error }
    }
    private func save() {
        busy = true; problem = nil
        Task {
            defer { busy = false }
            let u = Profiles.clean(username)
            if !u.isEmpty, u.count < 3 { problem = "An @name needs at least 3 characters."; return }
            if !u.isEmpty, await profiles.taken(u) { taken = true; return }
            taken = false
            let change: JSON = ["display_name": name.trimmingCharacters(in: .whitespaces).isEmpty ? Friends.shared.myName : name.trimmingCharacters(in: .whitespaces),
                                "username": u.isEmpty ? NSNull() : u, "bio": bio.trimmingCharacters(in: .whitespacesAndNewlines),
                                "tags": tags, "pinned": pinned, "show_week": showWeek]
            if await profiles.save(change) { dismiss() } else { problem = profiles.error }
        }
    }
}
