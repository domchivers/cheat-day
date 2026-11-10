import SwiftUI

/// Friends: each friend's day as a card (tap for what they had), the week as dots, requests, and the feed.
struct FriendsView: View {
    @Bindable private var nav = Nav.shared
    @State private var open: Set<String> = []
    @State private var adding = false
    @State private var showActivity = false
    @State private var viewing: FriendWorkout?
    @State private var showMessages = false
    @State private var profileOf: String?
    private var model: Friends { Friends.shared }
    private struct FriendWorkout: Identifiable { let id = UUID(); let post: JSON; let by: String }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $nav.friendsSeg) { Text("Feed").tag(1); Text("Explore").tag(2); Text("People").tag(0) }
                    .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
                switch nav.friendsSeg {
                case 0: people
                case 2: ExploreView()
                default: FeedView { id in open.insert(id); withAnimation { nav.friendsSeg = 0 } }
                }
            }
            .background(Theme.bg)
            .keyboardDone()
            .navigationTitle("Friends")
            .modifier(FriendsToolbar(unread: FriendActivity.shared.unread, chats: Messages.shared.unread, showActivity: $showActivity, adding: $adding, showMessages: $showMessages, showMe: Binding(get: { profileOf == Profiles.shared.me }, set: { profileOf = $0 ? Profiles.shared.me : nil })))
            .navigationDestination(isPresented: $showMessages) { MessagesView() }
            .navigationDestination(item: $profileOf) { id in ProfileView(id: id) }
            .navigationDestination(item: $nav.chatWith) { id in ChatView(friend: id) }
            .onChange(of: nav.addCode) { _, c in if c != nil { adding = true } }
            .onAppear { if nav.addCode != nil { adding = true } }
            .sheet(isPresented: $adding) { AddFriendSheet().presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showActivity) { ActivityView() }
            .sheet(item: $viewing) { v in PostRecipeSheet(post: v.post, by: v.by) }
            .task { await model.load(); await Profiles.shared.load(model.people.map(\.id)); await Messages.shared.load(); await Follows.shared.load() }
        }
    }

    /// Cards in a scroll view rather than a list: an opened card grows downwards with its corners intact, and the ones below slide down.
    private var people: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !model.requests.isEmpty {
                    box {
                        Eyebrow(text: "Requests")
                        ForEach(model.requests) { r in
                            HStack {
                                Text("\(r.name) wants to be friends").font(.subheadline)
                                Spacer()
                                Button("Accept") { Task { await model.accept(r) } }.buttonStyle(.borderedProminent).controlSize(.small).foregroundStyle(Theme.onAccent)
                            }
                        }
                    }
                }
                if model.people.isEmpty && !model.loading {
                    box {
                        Text("No friends yet").font(.title3.bold())
                        Text("Swap friend codes with someone and you'll see each other's day. Tap the person icon at the top.").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.people) { p in friendCard(p) }
                let leaders = model.people.filter { $0.streak > 0 }.sorted { $0.streak > $1.streak }.prefix(5)
                if !leaders.isEmpty {
                    box {
                        Eyebrow(text: "Streaks")
                        ForEach(Array(leaders.enumerated()), id: \.element.id) { pair in
                            let i = pair.offset, p = pair.element
                            HStack {
                                Text("\(i + 1)").font(.headline).foregroundStyle(i == 0 ? Theme.accent : .secondary).frame(width: 22)
                                Text(p.name)
                                Spacer()
                                HStack(spacing: 4) { FluentIcon(emoji: "🔥", size: 18); Text("\(p.streak) days").font(.subheadline.weight(.semibold)).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
                NavigationLink {
                    FriendsMore()
                } label: {
                    HStack {
                        Label("Shared meals, sending food and more", systemImage: "ellipsis.circle")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                Group {
                    if let e = model.error { Text("Couldn't load friends: \(e)") }
                    else { Text("Your code is \(model.myCode). Friends see what you choose to share.") }
                }
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 100)
        }
        .refreshable { await model.load() }
    }

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func friendCard(_ p: Friends.Person) -> some View {
        let isOpen = open.contains(p.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.35)) { if isOpen { open.remove(p.id) } else { open.insert(p.id) } }
            } label: { card(p) }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.vertical, 4)
                    let food = p.food
                    let wos = p.workouts
                    if food.isEmpty && wos.isEmpty { Text("Nothing shared today yet.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(Meals.all, id: \.self) { meal in
                        let its = food.filter { (str($0["meal"]).isEmpty ? Meals.of($0) : str($0["meal"])) == meal }
                        if !its.isEmpty {
                            Text(meal.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 4)
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
                    if !wos.isEmpty {
                        Text(wos.count == 1 ? "WORKOUT" : "WORKOUTS").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(wos.indices, id: \.self) { i in workoutRow(wos[i], by: p.name) }
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .offset(y: -10)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// A workout they showed in their day: tap for the exercises, to start it or save it as a routine.
    private func workoutRow(_ w: JSON, by name: String) -> some View {
        let lifts = list(w["lifts"])
        return Button {
            viewing = FriendWorkout(post: ["kind": "workout", "name": w["workout"] ?? "", "kcal": abs(num(w["kcal"]) ?? 0),
                                           "payload": ["minutes": w["minutes"] ?? 0, "lifts": lifts] as JSON], by: name)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(str(w["workout"])).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(num(w["minutes"]) ?? 0)) min\(lifts.isEmpty ? "" : " · \(lifts.count) exercise\(lifts.count == 1 ? "" : "s")")").font(.caption).foregroundStyle(.secondary)
                    if !lifts.isEmpty { Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary) }
                }
                if !lifts.isEmpty { Text(lifts.map { str($0["exercise"]) }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).disabled(lifts.isEmpty)
    }

    private func card(_ p: Friends.Person) -> some View {
        let day = p.current
        let kcal = num(day?["kcal"]) ?? 0, budget = pos(day?["budget"]) ?? 0
        let over = budget > 0 && kcal > budget * 1.1, near = budget > 0 && !over && kcal > budget
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(id: p.id, size: 42, dot: true)
                    .onTapGesture { profileOf = p.id }
                    .accessibilityAddTraits(.isButton).accessibilityLabel("\(p.name)'s profile")
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.headline)
                    Text(p.isActive ? (open.contains(p.id) ? "Their day so far" : "Tap to see what they had") : "Nothing logged today yet")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if p.isActive {
                    (Text(Fmt.int(kcal)).foregroundStyle(over || near ? Theme.warn : Theme.accent) + Text(" / \(Fmt.int(budget))").foregroundStyle(.secondary))
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                }
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open.contains(p.id) ? 180 : 0))
            }
            if p.isActive && budget > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(over || near ? Theme.warn : Theme.accent).frame(width: g.size.width * min(1, kcal / budget))
                    }
                }
                .frame(height: 7)
            }
            HStack {
                HStack(spacing: 5) {
                    ForEach(Array(p.week.enumerated()), id: \.offset) { pair in
                        let v = pair.element
                        Circle().fill(v == 1 ? Theme.accent : v == 2 ? Theme.warn : v == 3 ? Color.red.opacity(0.75) : Theme.track).frame(width: 10, height: 10)
                    }
                }
                if p.streak > 1 { HStack(spacing: 3) { FluentIcon(emoji: "🔥", size: 15); Text("\(p.streak)").font(.caption.weight(.bold)).foregroundStyle(.orange) } }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = Nav.shared.addCode ?? ""
    @State private var message: String?
    @State private var busy = false
    @State private var scanning = false
    private var model: Friends { Friends.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(model.myCode.isEmpty ? "…" : model.myCode).font(.title2.weight(.heavy)).monospaced()
                        Spacer()
                        ShareLink(item: "Add me on Cheat Days: my friend code is \(model.myCode)") { Image(systemName: "square.and.arrow.up") }
                    }
                } header: { Text("Your code") } footer: { Text("Send it to a friend, or type theirs below.") }
                Section {
                    TextField("Their code, like DOM-1234", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button(busy ? "Sending…" : "Send request") {
                        busy = true
                        Task { message = await model.add(code: code); busy = false }
                    }
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 4)
                    Button { scanning = true } label: { Label("Scan their QR code", systemImage: "qrcode.viewfinder") }
                    NavigationLink { FindPeopleView() } label: { Label("Find people by @name", systemImage: "magnifyingglass") }
                } footer: { if let message { Text(message) } }
            }
            .keyboardDone()
            .navigationTitle("Add a friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { Nav.shared.addCode = nil }
            .fullScreenCover(isPresented: $scanning) {
                QRScanView { found in
                    scanning = false
                    code = found
                    busy = true
                    Task { message = await model.add(code: found); busy = false }
                }
            }
        }
    }
}

/// The bell and add-friend buttons. On iOS 26 the new-activity count sits over the bell's top-right corner;
/// before that, a red dot drawn into the button.
private struct FriendsToolbar: ViewModifier {
    let unread: Int
    let chats: Int
    @Binding var showActivity: Bool
    @Binding var adding: Bool
    @Binding var showMessages: Bool
    @Binding var showMe: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbar {
                // its own glass circle (not the toolbar's shared one, which clips) so the count can sit over the corner
                ToolbarItem(placement: .topBarLeading) {
                    bell(Image(systemName: "bell.fill").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44).glassEffect(.regular, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if unread > 0 {
                                Text("\(min(unread, 99))").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).frame(minWidth: 19, minHeight: 19).background(Color.red, in: Capsule())
                                    .offset(x: 5, y: -5)
                            }
                        })
                    .buttonStyle(.plain)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { messages }
                ToolbarItem(placement: .topBarTrailing) { add }
                ToolbarItem(placement: .topBarTrailing) { me }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    bell(ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell.fill").padding(.top, 6).padding(.trailing, 9)
                        if unread > 0 {
                            Text("\(min(unread, 99))").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16).background(Color.red, in: Capsule())
                        }
                    }
                    .frame(minWidth: 34, minHeight: 30))
                }
                ToolbarItem(placement: .topBarTrailing) { messages }
                ToolbarItem(placement: .topBarTrailing) { add }
                ToolbarItem(placement: .topBarTrailing) { me }
            }
        }
    }

    private func bell(_ label: some View) -> some View {
        Button { showActivity = true } label: { label }.accessibilityLabel("Activity, \(unread) new")
    }
    private var add: some View {
        Button { adding = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("Add a friend")
    }
    /// Messages, with how many chats have something unread.
    private var messages: some View {
        Button { showMessages = true } label: {
            Image(systemName: "paperplane")
                .overlay(alignment: .topTrailing) {
                    if chats > 0 {
                        Text("\(min(chats, 99))").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16).background(Color.red, in: Capsule()).offset(x: 9, y: -8)
                    }
                }
        }
        .accessibilityLabel("Messages, \(chats) unread")
    }
    private var me: some View {
        Button { showMe = true } label: { Avatar(id: Profiles.shared.me, size: 28) }.accessibilityLabel("Your profile")
    }
}
