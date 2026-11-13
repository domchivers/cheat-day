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
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")   // always showing: the default hid it after a flash, until you pulled down
        .background(Theme.bg)
        .navigationTitle("Messages").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { picking = true } label: { Image(systemName: "square.and.pencil").offset(x: 0, y: -2) }.accessibilityLabel("New message") } }   // nudged: the square, not the square and its pencil, in the middle of the button
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

/// One chat: bubbles, a GIF, a post or food card, reactions (hold a message), the day and time between stretches,
/// ticks under your last message (blue once it's seen), and a box with ＋ for a photo, one of today's foods, a saved
/// meal or today's workout, and GIF for GIPHY's. Slide the chat left to see each message's time; slide a message
/// right to reply to it (the reply carries a line of what it answers, in payload.reply).
struct ChatView: View {
    let friend: String
    @State private var text = ""
    @State private var picked: PhotosPickerItem?
    @State private var library = false
    @State private var camera = false
    @State private var choosing = false
    @State private var gifs = false
    @State private var replying: JSON?   // the message the next one answers
    @State private var rewording: JSON?  // your message being changed: the box holds its words
    @State private var failed: String?
    @State private var jump: String?     // a quoted message to scroll back to
    /// A finger sliding a row sideways: left shows the times, right pulls that message towards a reply. It lets go
    /// by itself, even when the scroll takes the touch over.
    private struct Slide: Equatable { var id = ""; var dx: CGFloat = 0 }
    @GestureState(resetTransaction: Transaction(animation: .snappy(duration: 0.25))) private var slide = Slide()
    private var timesOut: CGFloat { slide.dx < 0 ? max(-64, slide.dx * 0.6) : 0 }
    private func replyPull(_ id: String) -> CGFloat { slide.id == id && slide.dx > 0 ? min(70, slide.dx * 0.6) : 0 }
    @State private var opened: PostBox?
    @State private var watching: PostBox?   // a story sent in the chat, opened: its owner's stories

    private func storyCard(_ p: JSON, live: Bool) -> some View {
        // an answer to a story shows it smaller: the answer is the point, the story's the reminder
        let small = !str(p["reaction"]).isEmpty || !str(p["reply"]).isEmpty
        return ZStack {
            LinearGradient(colors: [Color(red: 0.1, green: 0.18, blue: 0.32), Color(red: 0.16, green: 0.13, blue: 0.31)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let day = StoryView.daySlide(p) {
                // a meal or workout from their day: what it was and its calories, read from their day as it stands
                VStack(spacing: 8) {
                    switch day {
                    case .meal(let meal, let items):
                        FoodDot(name: str(items.first?["name"]), size: 52)
                        Text(meal).font(.headline).foregroundStyle(.white)
                        Text("\(Fmt.int(items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) })) kcal").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                    case .workout(let w):
                        FoodDot(name: "Workout", size: 52)
                        Text(str(w["name"]).replacingOccurrences(of: "Workout: ", with: "")).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(3)
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 24)
            }
            else if live, str(p["kind"]) != "video" {
                // the picture from the story as it stands (a friends-only one is sent without it)
                let now = Stories.shared.all.first { str($0["id"]) == str(p["story"]) }
                FeedPhoto(src: now.map { str($0["media"]) } ?? str(p["media"]), fill: true)
            }
            else { Image(systemName: live ? "play.fill" : "clock.arrow.circlepath").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.8)) }
        }
        .frame(width: small ? 110 : 150, height: small ? 176 : 240)
        .overlay(alignment: .bottomLeading) {
            Text(!live ? "Story no longer available" : str(p["owner"]) == Feed.shared.me ? "Your story" : "\(Feed.shared.name(str(p["owner"])))'s story")
                .font(.caption.weight(.bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3).padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityLabel(live ? "Story, opens it" : "Story no longer available")
    }
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
                        if let last = t.last, str(last["from_user"]) == me { ticks(seen: !str(last["seen_at"]).isEmpty) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .offset(x: timesOut)   // the times wait just off the right edge
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: jump) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) }; jump = nil } }
                .sensoryFeedback(.impact(weight: .light), trigger: slide.dx * 0.6 > 48)
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
        .fullScreenCover(item: $watching, onDismiss: { KeyboardDone.quiet = true }) { b in StoryView(people: [b.id], at: 0) }
        .sheet(isPresented: $gifs, onDismiss: { KeyboardDone.quiet = true }) {
            GifPicker { g in
                let payload = g.merging(takeReply()) { a, _ in a }
                Task { await messages.send(to: friend, kind: "gif", payload: payload) }
            }
            .presentationDetents([.medium, .large])
        }
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
        Text(Self.when(ISO.date(str(m["created_at"])))).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 8)
    }
    /// "Today, 14:31", "Yesterday, 09:15", "Sat 7 Nov, 18:42".
    static func when(_ date: Date?) -> String {
        guard let d = date else { return "" }
        let time = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday, \(time)" }
        return "\(d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(time)"
    }

    /// Two small ticks under your last message: grey once it's sent, blue once it's been seen.
    private func ticks(seen: Bool) -> some View {
        ZStack {
            Image(systemName: "checkmark").offset(x: -2.5)
            Image(systemName: "checkmark").offset(x: 2.5)
        }
        .font(.system(size: 10, weight: .heavy))
        .foregroundStyle(seen ? Theme.accent : Color(.systemGray2))
        .compositingGroup()
        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 9).padding(.top, 1)
        .accessibilityElement(children: .ignore).accessibilityLabel(seen ? "Seen" : "Sent")
        .animation(.easeInOut(duration: 0.2), value: seen)
    }

    @ViewBuilder private func bubble(_ m: JSON) -> some View {
        let mine = str(m["from_user"]) == me, kind = str(m["kind"]), p = dict(m["payload"])
        let rx = messages.reactions.filter { str($0["message_id"]) == str(m["id"]) }
        let id = str(m["id"]), quoted = dict(p["reply"]), pulled = replyPull(id)
        VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
            if !quoted.isEmpty {
                // what this one answers: a tap goes back to it
                Button { jump = str(quoted["id"]) } label: {
                    VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                        Text(mine ? "You replied" : "Replied to you").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(str(quoted["text"])).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .buttonStyle(.plain).padding(.bottom, 3)
            }
            Group {
                switch kind {
                case "photo":
                    FeedPhoto(src: str(p["photo"]), fill: true).frame(width: 220, height: 260).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                case "gif":
                    let w = num(p["w"]) ?? 200, h = num(p["h"]) ?? 200
                    AnimatedGIF(url: str(p["url"])).frame(width: 200, height: min(260, max(90, 200 * h / max(w, 1))))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).accessibilityLabel("GIF")
                case "post":
                    Button { opened = PostBox(post: dict(p["post"]).isEmpty ? p : dict(p["post"])) } label: { postCard(p) }.buttonStyle(.plain)
                case "story":
                    // shown only while it's still up and it's one they can see; after that, just that it was sent
                    let live = str(p["slide"]).isEmpty ? Stories.shared.all.contains { str($0["id"]) == str(p["story"]) } : StoryView.daySlide(p) != nil
                    let reaction = str(p["reaction"]), words = str(p["reply"])
                    VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
                        // an answer to a story: said so above it, with the emoji or the words under it
                        if !reaction.isEmpty || !words.isEmpty {
                            Text(mine ? (reaction.isEmpty ? "You replied to their story" : "You reacted to their story") : (reaction.isEmpty ? "Replied to your story" : "Reacted to your story"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button { if live { watching = PostBox(post: ["id": str(p["owner"])]) } } label: { storyCard(p, live: live) }
                            .buttonStyle(.plain).disabled(!live)
                        if !reaction.isEmpty { Text(reaction).font(.system(size: 40)) }
                        if !words.isEmpty {
                            Text(words).font(.body).foregroundStyle(mine ? Theme.onAccent : .primary)
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .background(mine ? Theme.accent : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                case "food":
                    foodCard(m, p, mine: mine)
                default:
                    Text(str(m["text"])).font(.body).foregroundStyle(mine ? Theme.onAccent : .primary)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(mine ? Theme.accent : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .contextMenu {
                // the reactions in one row across the top of the menu, not a list down it
                ControlGroup {
                    // drawn as pictures: as text the menu set them small
                    ForEach(["❤️", "😂", "👍", "🔥", "😋"], id: \.self) { e in
                        Button { Task { await messages.react(m, e) } } label: { Image(uiImage: ReactionGlyph.make(e)).accessibilityLabel(e) }   // the picture alone: with a title too, the menu kept an empty line under the row
                    }
                }
                .controlGroupStyle(.palette)
                if kind == "text" { Button { UIPasteboard.general.string = str(m["text"]) } label: { Label("Copy", systemImage: "doc.on.doc") } }
                if mine && kind == "text" { Button { replying = nil; rewording = m; text = str(m["text"]); typing = true } label: { Label("Edit", systemImage: "pencil") } }
                if mine { Button(role: .destructive) { Task { await messages.delete(m) } } label: { Label("Delete", systemImage: "trash") } }
            }
            if !rx.isEmpty {
                Text(rx.map { str($0["emoji"]) }.joined()).font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color(.tertiarySystemBackground), in: Capsule())
                    .overlay(Capsule().stroke(Theme.bg, lineWidth: 2)).offset(y: -6).padding(.horizontal, 10)
            }
            if p["edited"] as? Bool == true { Text("Edited").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 50)
        .offset(x: pulled)
        // the reply arrow comes in from the left as the message is pulled
        .overlay(alignment: .leading) {
            Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(pulled > 48 ? Theme.accent : Color.secondary)
                .opacity(Double(min(1, pulled / 40))).offset(x: pulled - 26)
                .accessibilityHidden(true)
        }
        // its own time, off the right edge until the chat is slid left
        .overlay(alignment: .trailing) {
            Text(ISO.date(str(m["created_at"]))?.formatted(date: .omitted, time: .shortened) ?? "").font(.caption2).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing).offset(x: 64).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 18)
            .updating($slide) { v, state, _ in
                // sideways only: an up-and-down drag is the scroll's
                if state.id == id || abs(v.translation.width) > abs(v.translation.height) * 1.4 { state = Slide(id: id, dx: v.translation.width) }
            }
            .onEnded { v in
                if v.translation.width * 0.6 > 48, abs(v.translation.width) > abs(v.translation.height) * 1.4 { replying = m; typing = true }
            })
        .accessibilityAction(named: "Reply") { replying = m; typing = true }
    }

    /// A line of a message, for the quote above a reply and the bar above the box.
    private func line(of m: JSON) -> String {
        let p = dict(m["payload"])
        switch str(m["kind"]) {
        case "photo": return "Photo"
        case "gif": return "GIF"
        case "story": return "Story"
        case "post", "food": return str(p["name"])
        default: return String(str(m["text"]).prefix(120))
        }
    }
    /// What goes with a message sent while replying, and the reply is then done with.
    private func takeReply() -> JSON {
        guard let r = replying else { return [:] }
        replying = nil
        return ["reply": ["id": str(r["id"]), "from": str(r["from_user"]), "text": line(of: r)] as JSON]
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
        return VStack(spacing: 4) {
            if rewording != nil {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Editing message").font(.caption.weight(.bold))
                        if let failed { Text(failed).font(.caption).foregroundStyle(Theme.warn).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                    Button { withAnimation(.snappy) { rewording = nil; failed = nil; text = "" } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Cancel the edit")
                }
                .padding(.leading, 10).padding(.top, 4)
            }
            if let r = replying {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(str(r["from_user"]) == me ? "Replying to yourself" : "Replying to \(Feed.shared.name(friend))").font(.caption.weight(.bold))
                        Text(line(of: r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { withAnimation(.snappy) { replying = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Cancel the reply")
                }
                .padding(.leading, 10).padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        HStack(alignment: .bottom, spacing: 8) {
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
            Button { typing = false; gifs = true } label: {
                Text("GIF").font(.system(size: 11, weight: .black)).foregroundStyle(.primary)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary, lineWidth: 1.6))
                    .frame(height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Send a GIF")
            Button {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let old = rewording {
                    // the same message, reworded: it stays in the box if the server won't take it
                    Task {
                        if t == str(old["text"]) { rewording = nil; text = ""; return }
                        if await messages.edit(old, text: String(t.prefix(1000))) { rewording = nil; failed = nil; text = "" }
                        else { failed = "Couldn't save the edit. Try again." }
                    }
                    return
                }
                text = ""
                let payload = takeReply()
                Task { await messages.send(to: friend, text: String(t.prefix(1000)), payload: payload) }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .frame(width: 36, height: 36).background(Theme.accent.opacity(empty ? 0.4 : 1), in: Circle())
            }
            .buttonStyle(.plain).disabled(empty).accessibilityLabel("Send")
        }
        }
        .animation(.snappy, value: replying == nil)
        .animation(.snappy, value: rewording == nil)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .composerGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .composerBar()
    }
}

/// A reaction emoji as a full-colour picture at a set size, for the hold menu's row (text there comes out small).
enum ReactionGlyph {
    @MainActor private static var made: [String: UIImage] = [:]
    @MainActor static func make(_ emoji: String, side: CGFloat = 30) -> UIImage {
        if let m = made[emoji] { return m }
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let text = emoji as NSString, font = UIFont.systemFont(ofSize: side * 0.86)
            let size = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: [.font: font])
        }
        .withRenderingMode(.alwaysOriginal)
        made[emoji] = out
        return out
    }
}

/// GIPHY's GIFs to send in a chat: what's trending, a few quick words, or a search. A tap sends it.
struct GifPicker: View {
    var send: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var found: [JSON] = []
    @State private var loading = false
    @State private var limited = false
    @MainActor private static var trending: [JSON] = []   // kept for the next time the sheet opens
    private let topics = ["Yes", "Hungry", "Gym", "Well done", "Haha", "No"]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search GIPHY", text: $q).autocorrectionDisabled().submitLabel(.search)
                if !q.isEmpty { Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear") }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Chip(text: "Trending", on: q.isEmpty, quiet: true) { q = "" }
                    ForEach(topics, id: \.self) { t in Chip(text: t, on: q.lowercased() == t.lowercased(), quiet: true) { q = t } }
                }
            }
            ScrollView {
                if limited && found.isEmpty {
                    Text("GIF search is busy right now. Try again in a bit.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 30)
                } else if loading && found.isEmpty {
                    ProgressView().padding(.top, 40)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(found.indices, id: \.self) { i in
                        let g = found[i]
                        Button { send(["url": g["url"] ?? "", "w": g["w"] ?? 200, "h": g["h"] ?? 200]); dismiss() } label: {
                            // GIPHY's 100-pixel copy in the grid (the 200 one is sent): a quarter of the frames to decode
                            AnimatedGIF(url: str(g["url"]).replacingOccurrences(of: "/200w.gif", with: "/100w.gif"), maxPixel: 200).frame(height: 96).frame(maxWidth: .infinity)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain).accessibilityLabel("GIF \(i + 1)")
                    }
                }
                // GIPHY asks for its name wherever its search is
                Text("Powered by GIPHY").font(.caption.weight(.heavy)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .padding(.horizontal, 12).padding(.top, 18)
        .presentationDragIndicator(.visible)
        .onAppear { if found.isEmpty { found = Self.trending } }
        .task(id: q) {
            if !q.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }   // not a search a letter
            if !Task.isCancelled { await load() }
        }
    }

    private func load() async {
        let asked = q
        loading = true; defer { loading = false }
        guard let (d, code) = try? await Supabase.shared.call("/functions/v1/giphy", body: ["q": asked, "kind": "gifs"] as JSON, timeout: 20), code == 200,
              let r = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { limited = true; return }
        guard asked == q else { return }
        found = CheatDays.list(r["items"])
        limited = r["limited"] as? Bool ?? false
        if asked.isEmpty && !found.isEmpty { Self.trending = found }
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
