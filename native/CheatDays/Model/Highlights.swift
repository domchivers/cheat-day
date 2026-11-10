import SwiftUI

/// Highlights: stories kept on a profile in named circles after their 24 hours. Each keeps copies of its stories, so
/// they last when the story itself has gone; your own old stories are the archive they're picked from.
@Observable @MainActor
final class Highlights {
    static let shared = Highlights()

    private(set) var of: [String: [JSON]] = [:]   // each person's, in order
    private(set) var archive: [JSON] = []         // every story you've posted, newest first
    var error: String?
    private var api: Supabase { Supabase.shared }
    var me: String { api.userId ?? "" }

    private func rows(_ path: String, method: String = "GET", body: Any? = nil, prefer: String? = nil) async throws -> [JSON] {
        let d = try await api.rest(path, method: method, body: body, prefer: prefer)
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    func load(_ id: String) async {
        guard UUID(uuidString: id) != nil else { return }
        if let got = try? await rows("/rest/v1/highlights?owner=eq.\(id)&select=*&order=position.asc,created_at.asc") { of[id] = got }
    }

    /// Your own stories, past and present: yours stay readable to you after they expire.
    func loadArchive() async {
        guard !me.isEmpty else { return }
        archive = (try? await rows("/rest/v1/stories?owner=eq.\(me)&select=*&order=created_at.desc&limit=300")) ?? []
    }

    /// What a highlight keeps of a story: enough to play it.
    static func copy(_ s: JSON) -> JSON {
        ["id": s["id"] ?? "", "kind": s["kind"] ?? "photo", "media": s["media"] ?? "", "overlays": s["overlays"] ?? [Any](),
         "seconds": s["seconds"] ?? NSNull(), "created_at": s["created_at"] ?? ""]
    }
    /// The picture on its circle: the first photo in it.
    static func cover(_ items: [JSON]) -> String? {
        items.first { str($0["kind"]) == "photo" }.map { str($0["media"]) } ?? items.first.map { str($0["media"]) }
    }

    func create(title: String, stories: [JSON]) async -> Bool {
        let items = stories.map(Self.copy)
        do {
            _ = try await rows("/rest/v1/highlights", method: "POST",
                               body: [["owner": me, "title": title, "items": items, "cover": Self.cover(items) ?? NSNull(), "position": (of[me]?.count ?? 0)]],
                               prefer: "return=representation")
            await load(me); error = nil
            return true
        } catch { self.error = "Highlights need setting up (supabase/highlights.sql)."; return false }
    }

    func update(_ h: JSON, title: String, stories: [JSON]) async {
        let items = stories.map(Self.copy)
        _ = try? await api.rest("/rest/v1/highlights?id=eq.\(str(h["id"]))&owner=eq.\(me)", method: "PATCH",
                                body: ["title": title, "items": items, "cover": Self.cover(items) ?? NSNull(), "updated_at": ISO.now()])
        await load(me)
    }

    func add(_ story: JSON, to h: JSON) async {
        var items = list(h["items"])
        guard !items.contains(where: { str($0["id"]) == str(story["id"]) }) else { return }
        items.append(Self.copy(story))
        await update(h, title: str(h["title"]), stories: items)
    }

    func delete(_ h: JSON) async {
        _ = try? await api.rest("/rest/v1/highlights?id=eq.\(str(h["id"]))&owner=eq.\(me)", method: "DELETE")
        of[me]?.removeAll { str($0["id"]) == str(h["id"]) }
    }
}

/// A story's little picture: the photo, or a gradient with a play mark for a video.
struct StoryThumb: View {
    let story: JSON
    var body: some View {
        if str(story["kind"]) == "video" {
            ZStack {
                LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.fill").font(.title3).foregroundStyle(.white.opacity(0.85))
            }
        } else { FeedPhoto(src: str(story["media"]), fill: true) }
    }
}

/// The row of highlight circles on a profile: yours start with New.
struct HighlightsRow: View {
    let owner: String
    @State private var making = false
    @State private var editing: PostBox?
    @State private var playing: PostBox?
    private var highlights: Highlights { Highlights.shared }
    private var isMe: Bool { owner == Highlights.shared.me }

    var body: some View {
        let shelf = highlights.of[owner] ?? []
        Group {
            if isMe || !shelf.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        if isMe {
                            Button { making = true } label: {
                                circle(Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary), "New")
                            }
                            .buttonStyle(.plain).accessibilityLabel("New highlight")
                        }
                        ForEach(shelf.indices, id: \.self) { i in
                            let h = shelf[i], items = list(h["items"])
                            // its first photo on the circle, else the first story as it is
                            Button { playing = PostBox(post: h) } label: {
                                circle(StoryThumb(story: items.first { str($0["kind"]) == "photo" } ?? items.first ?? [:]), str(h["title"]).isEmpty ? "Highlight" : str(h["title"]))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if isMe {
                                    Button { editing = PostBox(post: h) } label: { Label("Edit highlight", systemImage: "pencil") }
                                    Button(role: .destructive) { Task { await highlights.delete(h) } } label: { Label("Delete highlight", systemImage: "trash") }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task { await highlights.load(owner) }
        .sheet(isPresented: $making) { HighlightMaker(existing: nil) }
        .sheet(item: $editing) { b in HighlightMaker(existing: b.post) }
        .fullScreenCover(item: $playing) { b in StoryView(people: [owner], at: 0, highlight: b.post) }
    }

    private func circle(_ inner: some View, _ title: String) -> some View {
        VStack(spacing: 6) {
            inner.frame(width: 62, height: 62).clipShape(Circle())
                .background(Circle().fill(Color(.tertiarySystemFill)))
                .overlay(Circle().stroke(Color(.separator), lineWidth: 1).padding(-3))
            Text(title).font(.caption).foregroundStyle(.primary).lineLimit(1).frame(width: 70)
        }
    }
}

/// Make or change a highlight: a name, and which of your stories go in it.
struct HighlightMaker: View {
    let existing: JSON?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var picked: [String] = []
    @State private var busy = false
    private var highlights: Highlights { Highlights.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Name it (Meal prep, Gym, Cheat days…)", text: $title)
                        .font(.headline).padding(12).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    Text(picked.isEmpty ? "Pick the stories to keep" : "\(picked.count) picked").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    let all = pool
                    if all.isEmpty { Text("Post a story first: they're kept here for highlights.").foregroundStyle(.secondary).padding(.top, 20) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(all.indices, id: \.self) { i in
                            let s = all[i], id = str(s["id"]), on = picked.contains(id)
                            Button { if on { picked.removeAll { $0 == id } } else { picked.append(id) } } label: {
                                Color.clear.aspectRatio(9.0 / 16.0, contentMode: .fit)
                                    .overlay { StoryThumb(story: s) }.clipped()
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3)
                                            .foregroundStyle(on ? Theme.accent : .white).shadow(radius: 2).padding(6)
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        Text(ISO.date(str(s["created_at"]))?.formatted(.dateTime.day().month(.abbreviated)) ?? "")
                                            .font(.caption2.weight(.heavy)).foregroundStyle(.white).padding(5).shadow(radius: 2)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let e = highlights.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
                }
                .padding(16)
            }
            .navigationTitle(existing == nil ? "New highlight" : "Edit highlight").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : "Save") { save() }.fontWeight(.bold).disabled(busy || picked.isEmpty)
                }
            }
            .task {
                await highlights.loadArchive()
                if let h = existing { title = str(h["title"]); picked = list(h["items"]).map { str($0["id"]) } }
            }
        }
    }

    /// Your stories, plus any in this highlight that have gone from the archive.
    private var pool: [JSON] {
        var out = highlights.archive
        for it in list(existing?["items"]) where !out.contains(where: { str($0["id"]) == str(it["id"]) }) { out.append(it) }
        return out
    }

    private func save() {
        busy = true
        let chosen = picked.compactMap { id in pool.first { str($0["id"]) == id } }
        let name = String(title.trimmingCharacters(in: .whitespaces).prefix(24))
        Task {
            if let h = existing { await highlights.update(h, title: name, stories: chosen); dismiss() }
            else if await highlights.create(title: name, stories: chosen) { dismiss() }
            busy = false
        }
    }
}

/// Add the story you're watching (yours) to a highlight, or start a new one with it.
struct AddToHighlight: View {
    let story: JSON
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    private var highlights: Highlights { Highlights.shared }
    var body: some View {
        NavigationStack {
            List {
                Section("New highlight") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Create") { Task { if await highlights.create(title: String(newName.prefix(24)), stories: [story]) { dismiss() } } }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                let mine = highlights.of[highlights.me] ?? []
                if !mine.isEmpty {
                    Section("Add to") {
                        ForEach(mine.indices, id: \.self) { i in
                            Button { Task { await highlights.add(story, to: mine[i]); dismiss() } } label: {
                                Text(str(mine[i]["title"]).isEmpty ? "Highlight" : str(mine[i]["title"]))
                            }
                        }
                    }
                }
                if let e = highlights.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
            }
            .navigationTitle("Add to highlight").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await highlights.load(highlights.me) }
        }
    }
}
