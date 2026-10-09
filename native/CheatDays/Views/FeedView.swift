import PhotosUI
import SwiftUI

/// The friends feed: posts, reactions and comments, from the same tables as the website.
@Observable @MainActor
final class Feed {
    static let shared = Feed()
    static let reacts = ["👍", "❤️", "🔥", "😋"]
    private(set) var posts: [JSON] = []
    private(set) var reactions: [JSON] = []
    private(set) var comments: [JSON] = []
    private(set) var names: [String: String] = [:]
    private(set) var loading = false
    var error: String?
    private var api: Supabase { Supabase.shared }
    var me: String { api.userId ?? "" }

    private func rows(_ path: String) async throws -> [JSON] {
        let d = try await api.rest(path)
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            posts = try await rows("/rest/v1/posts?select=*&order=created_at.desc&limit=40")
            let ids = posts.map { str($0["id"]) }.joined(separator: ",")
            if !ids.isEmpty {
                async let rx = rows("/rest/v1/reactions?post_id=in.(\(ids))&select=post_id,user_id,emoji")
                async let cm = rows("/rest/v1/comments?post_id=in.(\(ids))&select=*&order=created_at.asc")
                reactions = try await rx; comments = try await cm
            }
            let who = Set(posts.map { str($0["owner"]) } + comments.map { str($0["user_id"]) } + [me]).filter { !$0.isEmpty }
            if !who.isEmpty {
                for p in try await rows("/rest/v1/profiles?user_id=in.(\(who.joined(separator: ",")))&select=user_id,display_name") {
                    names[str(p["user_id"])] = str(p["display_name"])
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func name(_ id: String) -> String { id == me ? "You" : (names[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Someone") }

    func toggle(_ post: JSON, _ emoji: String) async {
        let id = str(post["id"]), mine = reactions.contains { str($0["post_id"]) == id && str($0["user_id"]) == me && str($0["emoji"]) == emoji }
        do {
            if mine {
                let e = emoji.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? emoji
                _ = try await api.rest("/rest/v1/reactions?post_id=eq.\(id)&user_id=eq.\(me)&emoji=eq.\(e)", method: "DELETE")
                reactions.removeAll { str($0["post_id"]) == id && str($0["user_id"]) == me && str($0["emoji"]) == emoji }
            } else {
                _ = try await api.rest("/rest/v1/reactions", method: "POST", body: [["post_id": post["id"] ?? id, "user_id": me, "emoji": emoji]], prefer: "resolution=ignore-duplicates")
                reactions.append(["post_id": id, "user_id": me, "emoji": emoji])
                notify(str(post["owner"]), kind: "react", text: str(post["name"]), extra: ["emoji": emoji])
                Store.shared.perform(["type": "bump", "key": "reactCount"], syncAfter: 3)
            }
        } catch { self.error = error.localizedDescription }
    }

    func comment(_ post: JSON, _ text: String) async {
        do {
            let d = try await api.rest("/rest/v1/comments", method: "POST", body: [["post_id": post["id"] ?? "", "user_id": me, "text": text]], prefer: "return=representation")
            comments += (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
            notify(str(post["owner"]), kind: "comment", text: text)
            Store.shared.perform(["type": "bump", "key": "commentCount"], syncAfter: 3)
        } catch { self.error = error.localizedDescription }
    }

    func deleteComment(_ c: JSON) async {
        do { _ = try await api.rest("/rest/v1/comments?id=eq.\(str(c["id"]))&user_id=eq.\(me)", method: "DELETE"); comments.removeAll { str($0["id"]) == str(c["id"]) } }
        catch { self.error = error.localizedDescription }
    }

    func delete(_ post: JSON) async {
        do { _ = try await api.rest("/rest/v1/posts?id=eq.\(str(post["id"]))&owner=eq.\(me)", method: "DELETE"); posts.removeAll { str($0["id"]) == str(post["id"]) } }
        catch { self.error = error.localizedDescription }
    }

    func post(_ row: JSON, photo: UIImage?) async throws {
        var r = row
        r["owner"] = me
        if let photo, let jpeg = Self.square(photo) { r["photo"] = (try? await api.uploadPhoto(jpeg)) ?? NSNull() }
        _ = try await api.rest("/rest/v1/posts", method: "POST", body: [r], prefer: "return=representation")
        Store.shared.perform(["type": "bump", "key": "postCount"], syncAfter: 2)
        await load()
    }

    /// A friend hears about it (the website's notifyFriend), if push is set up.
    private func notify(_ to: String, kind: String, text: String, extra: JSON = [:]) {
        guard !to.isEmpty, to != me else { return }
        var body: JSON = ["action": "notify", "to": to, "kind": kind, "text": text]
        body.merge(extra) { _, n in n }
        Task { _ = try? await api.call("/functions/v1/push", body: body) }
    }

    /// Feed photos: a 640 px square, about 40 KB, like the website's thumbFromBig.
    static func square(_ img: UIImage) -> Data? {
        let side = min(img.size.width, img.size.height), size = CGSize(width: 640, height: 640)
        let crop = CGRect(x: (img.size.width - side) / 2, y: (img.size.height - side) / 2, width: side, height: side)
        let out = UIGraphicsImageRenderer(size: size).image { _ in
            img.draw(in: CGRect(x: -crop.minX * 640 / side, y: -crop.minY * 640 / side, width: img.size.width * 640 / side, height: img.size.height * 640 / side))
        }
        return out.jpegData(compressionQuality: 0.72)
    }

    static func ago(_ iso: String) -> String {
        guard let d = ISO.date(iso) else { return "" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }; if s < 3600 { return "\(Int(s / 60)) min ago" }; if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86400); return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

struct FeedView: View {
    @State private var composing = false
    @State private var opened: Set<String> = []
    @State private var drafts: [String: String] = [:]
    @State private var recipe: JSON?
    private var feed: Feed { Feed.shared }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Button { composing = true } label: {
                    HStack(spacing: 12) {
                        Text(String(feed.name(feed.me).prefix(1))).font(.headline.weight(.heavy)).foregroundStyle(Theme.accent).frame(width: 40, height: 40).background(Theme.hero, in: Circle())
                        Text("Share a meal, a food or a workout").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "camera.fill").foregroundStyle(Theme.accent)
                    }
                    .padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                if let e = feed.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
                if feed.posts.isEmpty && !feed.loading { Text("Nothing in the feed yet. Share something, or add a friend.").foregroundStyle(.secondary).padding(.top, 30) }
                ForEach(feed.posts.indices, id: \.self) { i in postCard(feed.posts[i]) }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 100)
        }
        .refreshable { await feed.load() }
        .task { if feed.posts.isEmpty { await feed.load() } }
        .overlay { if feed.loading && feed.posts.isEmpty { ProgressView() } }
        .sheet(isPresented: $composing) { ComposeSheet() }
        .sheet(item: Binding(get: { recipe.map { PostBox(post: $0) } }, set: { recipe = $0?.post })) { b in PostRecipeSheet(post: b.post) }
    }

    private func postCard(_ p: JSON) -> some View {
        let id = str(p["id"]), owner = str(p["owner"]), kind = str(p["kind"]), extra = dict(p["extra"]), macros = dict(p["macros"])
        let rx = feed.reactions.filter { str($0["post_id"]) == id }, cm = feed.comments.filter { str($0["post_id"]) == id }
        let all = opened.contains(id) || cm.count <= 2, shown = all ? cm : Array(cm.suffix(2))
        let amount: String = kind == "workout" ? "\(Int(num(extra["minutes"]) ?? 0)) min · \(list(dict(p["payload"])["lifts"]).count) exercises"
            : kind == "meal" ? "\(Int(num(extra["portions"]) ?? 1)) portions · \(Fmt.int(num(p["kcal"]) ?? 0)) kcal each"
            : (num(extra["grams"]).map { "\(Fmt.int($0)) \(str(extra["unit"]).isEmpty ? "g" : str(extra["unit"])) · " } ?? "") + "\(Fmt.int(num(p["kcal"]) ?? 0)) kcal"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(String(feed.name(owner).prefix(1)).uppercased()).font(.subheadline.weight(.heavy)).foregroundStyle(Theme.accent).frame(width: 36, height: 36).background(Theme.hero, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(feed.name(owner)).font(.subheadline.weight(.bold))
                    Text(Feed.ago(str(p["created_at"])) + (kind == "meal" ? " · shared a meal" : kind == "workout" ? " · worked out" : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if owner == feed.me {
                    Menu { Button(role: .destructive) { Task { await feed.delete(p) } } label: { Label("Delete post", systemImage: "trash") } } label: { Image(systemName: "ellipsis").padding(8) }
                }
            }
            if let url = URL(string: str(p["photo"])), str(p["photo"]).hasPrefix("http") {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Theme.hero }
                    .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if !str(p["caption"]).isEmpty { (Text(feed.name(owner) + " ").bold() + Text(str(p["caption"]))).font(.subheadline) }
            HStack(spacing: 10) {
                FoodDot(name: str(p["name"]), size: 34)
                VStack(alignment: .leading, spacing: 1) { Text(str(p["name"])).font(.subheadline.weight(.bold)); Text(amount).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(kind == "workout" ? "Do it" : kind == "meal" ? "Recipe" : "Have some") { recipe = p }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            }
            if let pv = num(macros["p"]) {
                Text("P \(Int(pv))g · C \(Int(num(macros["c"]) ?? 0))g · F \(Int(num(macros["f"]) ?? 0))g").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(Feed.reacts, id: \.self) { e in
                    let n = rx.filter { str($0["emoji"]) == e }.count, on = rx.contains { str($0["emoji"]) == e && str($0["user_id"]) == feed.me }
                    Button { Task { await feed.toggle(p, e) } } label: {
                        Text(n > 0 ? "\(e) \(n)" : e).font(.subheadline).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(on ? Theme.accent.opacity(0.25) : Color(.tertiarySystemFill), in: Capsule())
                            .overlay(Capsule().stroke(on ? Theme.accent : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: on)
                }
            }
            if !all { Button("View all \(cm.count) comments") { opened.insert(id) }.font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(shown.indices, id: \.self) { j in
                let c = shown[j]
                HStack(alignment: .top) {
                    (Text(feed.name(str(c["user_id"])) + " ").bold() + Text(str(c["text"]))).font(.subheadline)
                    Spacer()
                    if str(c["user_id"]) == feed.me { Button { Task { await feed.deleteComment(c) } } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).foregroundStyle(.tertiary) }
                }
            }
            HStack {
                TextField("Add a comment…", text: Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })).submitLabel(.send)
                    .onSubmit { send(p) }
                if !(drafts[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { Button("Post") { send(p) }.font(.subheadline.weight(.bold)) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Color(.tertiarySystemFill), in: Capsule())
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func send(_ p: JSON) {
        let id = str(p["id"]), t = (drafts[id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        drafts[id] = ""
        Task { await feed.comment(p, String(t.prefix(300))) }
    }
}

private struct PostBox: Identifiable { let post: JSON; var id: String { str(post["id"]) } }

/// Share something: one of today's foods, a saved meal or today's workout, with a caption and an optional photo.
struct ComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var what: JSON?
    @State private var caption = ""
    @State private var photo: UIImage?
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
    @State private var busy = false
    @State private var problem: String?
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            List {
                if let w = what {
                    Section {
                        HStack { FoodDot(name: str(w["name"]), size: 34); Text(str(w["name"])).font(.headline); Spacer(); Button("Change") { what = nil }.font(.subheadline) }
                        TextField("Say something about it", text: $caption, axis: .vertical).lineLimit(2...5)
                    }
                    Section {
                        if let photo { Image(uiImage: photo).resizable().scaledToFill().frame(height: 220).clipped().clipShape(RoundedRectangle(cornerRadius: 14)) }
                        HStack(spacing: 18) {
                            Button { camera = true } label: { Label(photo == nil ? "Snap a pic" : "Retake", systemImage: "camera.fill") }.buttonStyle(.borderless)
                            PhotosPicker(selection: $picked, matching: .images) { Label("Library", systemImage: "photo") }.buttonStyle(.borderless)
                            if photo != nil { Button("Remove", role: .destructive) { photo = nil }.buttonStyle(.borderless) }
                        }
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
                } else {
                    let items = store.todayItems
                    if !items.isEmpty {
                        Section("Today") { ForEach(items.indices, id: \.self) { i in pickRow(str(items[i]["name"]), "\(Int(num(items[i]["kcal"]) ?? 0)) kcal") { what = food(items[i]) } } }
                    }
                    let meals = list(store.doc["meals"]).filter { $0["saved"] as? Bool == true }.prefix(8)
                    if !meals.isEmpty {
                        Section("Your meals") { ForEach(Array(meals).indices, id: \.self) { i in let m = Array(meals)[i]; pickRow(str(m["name"]), "\(Fmt.int(num(store.mealBasis(m)["kcalPerServing"]) ?? 0)) kcal a portion") { what = meal(m) } } }
                    }
                    let wos = store.todayWorkouts
                    if !wos.isEmpty {
                        Section("Today's workouts") { ForEach(wos.indices, id: \.self) { i in pickRow(str(wos[i]["name"]), "\(Int(num(wos[i]["minutes"]) ?? 0)) min") { what = workout(wos[i]) } } }
                    }
                    if items.isEmpty && meals.isEmpty && wos.isEmpty { Text("Log a food, save a meal or finish a workout, then share it here.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(what == nil ? "What are you sharing?" : "New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if what != nil { ToolbarItem(placement: .confirmationAction) { Button(busy ? "Posting…" : "Post") { post() }.fontWeight(.bold).disabled(busy) } }
            }
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { photo = img } }.ignoresSafeArea() }
            .onChange(of: picked) { _, item in Task { if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img } } }
        }
    }

    private func pickRow(_ name: String, _ detail: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                FoodDot(name: name, size: 30)
                VStack(alignment: .leading, spacing: 1) { Text(name).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }

    private func food(_ it: JSON) -> JSON {
        let m = store.macros([it]), k = num(it["kcal"]) ?? 0
        return ["kind": "food", "name": it["name"] ?? "", "kcal": Int(k), "macros": ["p": Int(m.p), "c": Int(m.c), "f": Int(m.f)] as JSON,
                "payload": FoodMath.basisOf(it), "extra": ["grams": it["grams"] ?? NSNull(), "unit": it["unit"] ?? "g"] as JSON]
    }
    private func meal(_ m: JSON) -> JSON {
        let b = store.mealBasis(m), n = num(m["portions"]) ?? 1
        return ["kind": "meal", "name": m["name"] ?? "", "kcal": Int((num(b["kcalPerServing"]) ?? 0).rounded()),
                "macros": ["p": Int(num(b["pServ"]) ?? 0), "c": Int(num(b["cServ"]) ?? 0), "f": Int(num(b["fServ"]) ?? 0)] as JSON,
                "payload": ["name": m["name"] ?? "", "portions": n, "items": m["items"] ?? [Any](), "steps": m["steps"] ?? [Any]()] as JSON, "extra": ["portions": n] as JSON]
    }
    private func workout(_ w: JSON) -> JSON {
        ["kind": "workout", "name": w["name"] ?? "", "kcal": w["kcal"] ?? 0, "macros": NSNull(),
         "payload": ["minutes": w["minutes"] ?? 0, "lifts": w["lifts"] ?? [Any]()] as JSON, "extra": ["minutes": w["minutes"] ?? 0] as JSON]
    }

    private func post() {
        guard var row = what else { return }
        row["caption"] = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; problem = nil
        Task {
            defer { busy = false }
            do { try await Feed.shared.post(row, photo: photo); dismiss() }
            catch { problem = "Couldn't post: \(error.localizedDescription)" }
        }
    }
}

/// A post to take for yourself: a meal's recipe to save or have, a food to add, or a workout to do.
struct PostRecipeSheet: View {
    let post: JSON
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var asking = false
    private var store: Store { Store.shared }

    var body: some View {
        let kind = str(post["kind"]), m = dict(post["payload"]), macros = dict(post["macros"])
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(str(post["name"])).font(.title2.bold())
                        Text("Shared by \(Feed.shared.name(str(post["owner"])))").font(.caption).foregroundStyle(.secondary)
                        Text("\(Fmt.int(num(post["kcal"]) ?? 0)) kcal\(num(macros["p"]).map { " · P \(Int($0))g C \(Int(num(macros["c"]) ?? 0))g F \(Int(num(macros["f"]) ?? 0))g" } ?? "")").font(.subheadline.weight(.semibold))
                    }
                }
                if kind == "meal" {
                    Section("Ingredients") {
                        ForEach(list(m["items"]).indices, id: \.self) { i in
                            let it = list(m["items"])[i]
                            HStack { Text(str(it["name"])); Spacer(); Text("\(num(it["grams"]).map { "\(Fmt.int($0)) g · " } ?? "")\(Fmt.int(num(it["kcal"]) ?? 0))").foregroundStyle(.secondary).monospacedDigit() }.font(.subheadline)
                        }
                    }
                    let steps = m["steps"] as? [String] ?? []
                    if !steps.isEmpty { Section("Method") { ForEach(steps.indices, id: \.self) { i in Text("\(i + 1). \(steps[i])").font(.subheadline) } } }
                    Section {
                        Button(saved ? "Saved to your meals" : "Save to my meals") { store.perform(["type": "saveMeal", "meal": copy(m)]); saved = true }.disabled(saved)
                        Button("Have a portion today") { let c = copy(m); store.add(store.mealBasis(c), kcal: num(post["kcal"]) ?? 0, meal: Meals.now); dismiss() }
                    }
                } else if kind == "workout" {
                    Section("Exercises") {
                        ForEach(list(m["lifts"]).indices, id: \.self) { i in
                            let l = list(m["lifts"])[i]
                            Text("\(str(l["exercise"])) · \(Int(num(l["sets"]) ?? 3))×\(Int(num(l["reps"]) ?? 8))\((num(l["kg"]) ?? 0) > 0 ? " @ \(Fmt.one(num(l["kg"]) ?? 0)) kg" : "")").font(.subheadline)
                        }
                    }
                    Section {
                        Button("Start this workout") {
                            store.startSession(["name": post["name"] ?? "", "exercises": list(m["lifts"]).map { ["exercise": $0["exercise"] ?? "", "sets": $0["sets"] ?? 3, "reps": $0["reps"] ?? 8, "kg": $0["kg"] ?? 0] as JSON }])
                            dismiss()
                        }
                        .disabled(store.session != nil || list(m["lifts"]).isEmpty)
                    } footer: { if store.session != nil { Text("Finish your current session first.") } }
                } else {
                    Section {
                        Button("Add it to today") {
                            var b = m; if b.isEmpty { b = ["name": post["name"] ?? "", "kcalPerServing": post["kcal"] ?? 0, "unitLabel": "portion"] }
                            store.add(b, kcal: num(post["kcal"]) ?? 0, meal: Meals.now); dismiss()
                        }
                        Button("Make me a recipe like this") { asking = true }
                    } footer: { Text("This was shared as a food, so there's no recipe with it. The assistant can make one with about the same calories.") }
                }
            }
            .navigationTitle(kind == "workout" ? "Workout" : "Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $asking) {
                AssistantView(meal: Meals.now, firstQuestion: "Give me a recipe for \(str(post["name"])), about \(Fmt.int(num(post["kcal"]) ?? 0)) kcal a portion\(num(macros["p"]).map { " with around \(Int($0)) g protein" } ?? "").")
            }
        }
    }

    private func copy(_ m: JSON) -> JSON {
        ["id": uid(), "name": str(m["name"]).isEmpty ? str(post["name"]) : str(m["name"]), "portions": m["portions"] ?? 1,
         "items": list(m["items"]).map { it -> JSON in var c = it; c["id"] = uid(); return c }, "steps": m["steps"] ?? [Any](),
         "saved": true, "copiedFrom": "post:\(str(post["id"]))", "updatedAt": ISO.now()]
    }
}
