import PhotosUI
import SwiftUI

/// Your chats, newest first: their photo (a green dot when they're on the app), the last message and a dot when
/// it's unread. ✎ starts one with any friend.
struct MessagesView: View {
    @State private var search = ""
    @State private var picking = false
    @State private var chatWith: String?
    private var messages: Messages { Messages.shared }

    var body: some View {
        let chats = messages.chats.filter { search.isEmpty || Feed.shared.name($0.id).localizedCaseInsensitiveContains(search) || Profiles.shared.handle($0.id).localizedCaseInsensitiveContains(search) }
        List {
            if let e = messages.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
            if messages.chats.isEmpty && messages.error == nil {
                Text("No messages yet. Tap ✎ to message a friend.").foregroundStyle(.secondary)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(chats) { c in
                Button { chatWith = c.id } label: { row(c) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search")
        .background(Theme.bg)
        .navigationTitle("Messages").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { picking = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New message") } }
        .task { await messages.load() }
        .refreshable { await messages.load() }
        .navigationDestination(item: $chatWith) { id in ChatView(friend: id) }
        .sheet(isPresented: $picking) {
            NewMessageSheet { id in
                picking = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { chatWith = id }   // once the sheet's gone
            }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private func row(_ c: Messages.Chat) -> some View {
        HStack(spacing: 12) {
            Avatar(id: c.id, size: 52, dot: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(Feed.shared.name(c.id)).font(.headline)
                Text(Messages.preview(c.last, me: messages.me)).font(.subheadline)
                    .foregroundStyle(c.unread > 0 ? .primary : .secondary).fontWeight(c.unread > 0 ? .semibold : .regular).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Feed.ago(str(c.last["created_at"]))).font(.caption).foregroundStyle(.secondary)
                if c.unread > 0 { Circle().fill(Theme.accent).frame(width: 10, height: 10) }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Who to message: your friends, with their photo and @name, and a search.
struct NewMessageSheet: View {
    var pick: (String) -> Void
    @State private var q = ""
    @Environment(\.dismiss) private var dismiss
    private var profiles: Profiles { Profiles.shared }

    var body: some View {
        let all = Friends.shared.people.filter { p in
            q.isEmpty || p.name.localizedCaseInsensitiveContains(q) || profiles.handle(p.id).localizedCaseInsensitiveContains(q)
        }
        NavigationStack {
            List {
                if Friends.shared.people.isEmpty {
                    Text("Add a friend first: scan each other's code in Friends.").foregroundStyle(.secondary)
                }
                ForEach(all) { p in
                    Button { pick(p.id) } label: {
                        HStack(spacing: 12) {
                            Avatar(id: p.id, size: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profiles.all[p.id]?.name ?? p.name).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                                if !profiles.handle(p.id).isEmpty { Text(profiles.handle(p.id)).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")
            .navigationTitle("New message").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// One chat: bubbles, a post or food card, reactions (hold a message), "Seen", and a box with ＋ for a photo,
/// one of today's foods, a saved meal or today's workout.
struct ChatView: View {
    let friend: String
    @State private var text = ""
    @State private var picked: PhotosPickerItem?
    @State private var library = false
    @State private var camera = false
    @State private var choosing = false
    @State private var opened: PostBox?
    @State private var added: Set<String> = []
    @FocusState private var typing: Bool
    private var messages: Messages { Messages.shared }
    private var store: Store { Store.shared }
    private var me: String { messages.me }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        let t = messages.thread
                        ForEach(t.indices, id: \.self) { i in
                            if i == 0 || gap(t[i - 1], t[i]) { stamp(t[i]) }
                            bubble(t[i]).id(str(t[i]["id"]))
                        }
                        if let last = t.last, str(last["from_user"]) == me, !str(last["seen_at"]).isEmpty {
                            Text("Seen").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.thread.count) { _, _ in withAnimation { proxy.scrollTo(str(messages.thread.last?["id"]), anchor: .bottom) } }
            }
            composer
        }
        .background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink { ProfileView(id: friend) } label: {
                    HStack(spacing: 8) { Avatar(id: friend, size: 28, dot: true); Text(Feed.shared.name(friend)).font(.headline).foregroundStyle(.primary) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await messages.openChat(friend)
            // new messages while it's open
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { await messages.refresh() }
            }
        }
        // the chat box has no Done bar; leaving puts it back for every other keyboard (it stayed off after a chat,
        // and the workout's number pads lost their Done)
        .onDisappear { messages.closeChat(); KeyboardDone.quiet = false }
        .onAppear { KeyboardDone.quiet = true }
        .sheet(item: $opened, onDismiss: { KeyboardDone.quiet = true }) { b in PostRecipeSheet(post: b.post) }
        .sheet(isPresented: $choosing) { ShareThingSheet { kind, payload in Task { await messages.send(to: friend, kind: kind, payload: payload) } } }
        .photosPicker(isPresented: $library, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in Task { if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { await messages.sendPhoto(to: friend, img) }; picked = nil } }
        .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { Task { await messages.sendPhoto(to: friend, img) } } }.ignoresSafeArea() }
    }

    private func gap(_ a: JSON, _ b: JSON) -> Bool {
        guard let x = ISO.date(str(a["created_at"])), let y = ISO.date(str(b["created_at"])) else { return false }
        return y.timeIntervalSince(x) > 3600
    }
    private func stamp(_ m: JSON) -> some View {
        Text(ISO.date(str(m["created_at"]))?.formatted(.relative(presentation: .named)) ?? "").font(.caption2).foregroundStyle(.secondary).padding(.vertical, 8)
    }

    @ViewBuilder private func bubble(_ m: JSON) -> some View {
        let mine = str(m["from_user"]) == me, kind = str(m["kind"]), p = dict(m["payload"])
        let rx = messages.reactions.filter { str($0["message_id"]) == str(m["id"]) }
        VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
            Group {
                switch kind {
                case "photo":
                    FeedPhoto(src: str(p["photo"]), fill: true).frame(width: 220, height: 260).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                case "post":
                    Button { opened = PostBox(post: dict(p["post"]).isEmpty ? p : dict(p["post"])) } label: { postCard(p) }.buttonStyle(.plain)
                case "food":
                    foodCard(m, p, mine: mine)
                default:
                    Text(str(m["text"])).font(.body).foregroundStyle(mine ? Theme.onAccent : .primary)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(mine ? Theme.accent : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .contextMenu {
                ForEach(["❤️", "😂", "👍", "🔥", "😋"], id: \.self) { e in Button(e) { Task { await messages.react(m, e) } } }
                if kind == "text" { Button { UIPasteboard.general.string = str(m["text"]) } label: { Label("Copy", systemImage: "doc.on.doc") } }
                if mine { Button(role: .destructive) { Task { await messages.delete(m) } } label: { Label("Delete", systemImage: "trash") } }
            }
            if !rx.isEmpty {
                Text(rx.map { str($0["emoji"]) }.joined()).font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color(.tertiarySystemBackground), in: Capsule())
                    .overlay(Capsule().stroke(Theme.bg, lineWidth: 2)).offset(y: -6).padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 50)
    }

    private func postCard(_ p: JSON) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if Feed.hasPhoto(p) { FeedPhoto(src: str(p["photo"]), fill: true).frame(width: 220, height: 130).clipped() }
            else { ZStack { LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing); FoodDot(name: str(p["name"]), size: 56) }.frame(width: 220, height: 110) }
            VStack(alignment: .leading, spacing: 2) {
                Text(str(p["name"])).font(.subheadline.weight(.bold)).lineLimit(1)
                Text("\(Fmt.int(num(p["kcal"]) ?? 0)) kcal\(num(dict(p["macros"])["p"]).map { " · \(Int($0)) g protein" } ?? "") · tap to see it").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
        }
        .frame(width: 220, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A food or meal sent over: ＋ puts it on your day (theirs when it's yours, so just the card).
    private func foodCard(_ m: JSON, _ p: JSON, mine: Bool) -> some View {
        let id = str(m["id"]), kcal = num(p["kcal"]) ?? 0
        return HStack(spacing: 10) {
            FoodDot(name: str(p["name"]), size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(str(p["name"])).font(.subheadline.weight(.bold)).lineLimit(2)
                Text("\(Fmt.int(kcal)) kcal").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !mine {
                Button {
                    store.add(dict(p["basis"]).isEmpty ? ["name": p["name"] ?? "", "kcalPerServing": kcal, "unitLabel": "portion"] : dict(p["basis"]), kcal: kcal, meal: Meals.now)
                    added.insert(id)
                } label: { Image(systemName: added.contains(id) ? "checkmark.circle.fill" : "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent) }
                .buttonStyle(.plain).disabled(added.contains(id)).accessibilityLabel("Add \(str(p["name"])) to today")
            }
        }
        .padding(11).frame(width: 240)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var composer: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { camera = true } label: { Label("Take a photo", systemImage: "camera") }
                Button { library = true } label: { Label("Photo library", systemImage: "photo") }
                Button { choosing = true } label: { Label("A food, meal or workout", systemImage: "fork.knife") }
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 36, height: 36).background(Color.white.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Send a photo or food")
            TextField("Message \(Feed.shared.name(friend))…", text: $text, axis: .vertical).lineLimit(1...5).focused($typing)
                .padding(.vertical, 8)
            Button {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = ""
                Task { await messages.send(to: friend, text: String(t.prefix(1000))) }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .frame(width: 36, height: 36).background(Theme.accent.opacity(empty ? 0.4 : 1), in: Circle())
            }
            .buttonStyle(.plain).disabled(empty).accessibilityLabel("Send")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .composerGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .composerBar()
    }
}

/// Pick one of today's foods, a saved meal or today's workout to send in a chat.
struct ShareThingSheet: View {
    var send: (_ kind: String, _ payload: JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            List {
                let items = store.todayItems
                if !items.isEmpty {
                    Section("Today") {
                        ForEach(items.indices, id: \.self) { i in
                            let it = items[i]
                            row(str(it["name"]), "\(Int(num(it["kcal"]) ?? 0)) kcal") {
                                send("food", ["name": it["name"] ?? "", "kcal": it["kcal"] ?? 0, "basis": FoodMath.basisOf(it)])
                            }
                        }
                    }
                }
                let meals = Array(list(store.doc["meals"]).filter { $0["saved"] as? Bool == true }.prefix(10))
                if !meals.isEmpty {
                    Section("Your meals") {
                        ForEach(meals.indices, id: \.self) { i in
                            let m = meals[i], b = store.mealBasis(m)
                            row(str(m["name"]), "\(Fmt.int(num(b["kcalPerServing"]) ?? 0)) kcal a portion") {
                                send("food", ["name": m["name"] ?? "", "kcal": Int((num(b["kcalPerServing"]) ?? 0).rounded()), "basis": b])
                            }
                        }
                    }
                }
                let wos = store.todayWorkouts
                if !wos.isEmpty {
                    Section("Today's workouts") {
                        ForEach(wos.indices, id: \.self) { i in
                            let w = wos[i], post = ComposeSheet.workoutPost(w)
                            row(str(w["name"]), "\(Int(num(w["minutes"]) ?? 0)) min") { send("post", ["name": w["name"] ?? "", "kcal": w["kcal"] ?? 0, "post": post]) }
                        }
                    }
                }
                if items.isEmpty && meals.isEmpty && wos.isEmpty { Text("Log a food, save a meal or finish a workout to send it.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Send").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ name: String, _ detail: String, tap: @escaping () -> Void) -> some View {
        Button { tap(); dismiss() } label: {
            HStack(spacing: 12) {
                FoodDot(name: name, size: 30)
                VStack(alignment: .leading, spacing: 1) { Text(name).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }
}
