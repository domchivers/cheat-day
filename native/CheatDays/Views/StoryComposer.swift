import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Making a story: a photo or a video (up to 30 seconds) from the camera or the library, then the editor
/// (StoryEditor), then Friends only or Your story (friends and followers).
struct StoryComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var video: URL?
    @State private var camera = false
    @State private var picked: PhotosPickerItem?
    @State private var loading = false
    @State private var words = false   // an Aa story: the editor opens on writing
    // Several chosen at once: each is its own slide, edited and shared in turn (the one showing is `image`/`video`)
    @State private var queue: [StoryPick] = []
    @State private var extras: [JSON] = []   // the other photos picked with the first, on it as stickers
    @State private var at = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // straight into the camera, as Instagram opens (the in-between Camera / Library screen is gone)
            if image == nil && video == nil {
                StoryCamera(captured: { img, url in words = false; queue = []; extras = []; at = 0; image = img; video = url }, close: { dismiss() },
                            wordsOnly: { card in words = true; queue = []; at = 0; image = card; video = nil },
                            capturedMany: { picks in
                                // Several picked from the library: one story. The first is the picture; the other photos go
                                // on it as stickers, to move and size (each was a story of its own). A video can't be a
                                // sticker, so any more videos still come after it as stories of their own.
                                words = false; at = 0
                                let first = picks[0], rest = picks.dropFirst()
                                extras = StoryEditor.photoStickers(rest.compactMap(\.image))
                                queue = [first] + rest.filter { $0.video != nil }
                                if queue.count == 1 { queue = [] }
                                image = first.image; video = first.video
                            })
            }
            else {
                StoryEditor(image: image, video: video, startWriting: words, close: {
                    extras = []
                    // leaving part-way: what's shared stays shared, the rest are let go
                    let shared = at > 0
                    queue = []; at = 0; image = nil; video = nil; words = false
                    if shared { dismiss() }
                }, posted: {
                    // on to the next one chosen, or done
                    if at + 1 < queue.count { at += 1; image = queue[at].image; video = queue[at].video } else { dismiss() }
                }, startItems: at == 0 ? extras : [])
                .id(at)
                .overlay(alignment: .top) {
                    if queue.count > 1 {
                        Text("\(at + 1) of \(queue.count)").font(.footnote.weight(.heavy)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 30).background(.black.opacity(0.55), in: Capsule())
                            .padding(.top, 14).allowsHitTesting(false)
                    }
                }
            }
        }
        .statusBarHidden()
        .fullScreenCover(isPresented: $camera) {
            MediaCamera { img, url in camera = false; image = img; video = url }.ignoresSafeArea()
        }
        .onChange(of: picked) { _, item in Task { await load(item) } }
    }

    // MARK: picking the photo or video

    private var pick: some View {
        VStack(spacing: 18) {
            HStack { Button { dismiss() } label: { Image(systemName: "xmark").font(.title2).foregroundStyle(.white).padding(10) }; Spacer() }
                .padding(.horizontal, 12)
            Spacer()
            Text("Add to your story").font(.title2.bold()).foregroundStyle(.white)
            Text("A photo or a video up to 30 seconds. It's up for 24 hours.").font(.subheadline).foregroundStyle(.white.opacity(0.7))
            Button { camera = true } label: { bigButton("camera.fill", "Camera") }.buttonStyle(.plain)
            PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos])) { bigButton("photo.on.rectangle", "Library") }
            if loading { ProgressView().tint(.white) }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func bigButton(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 15).background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loading = true; defer { loading = false }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let m = try? await item.loadTransferable(type: PickedMovie.self) { video = m.url; image = nil }
        else if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { image = img; video = nil }
        picked = nil
    }
}

/// A video from the library, copied somewhere it can be read.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { got in
            let to = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + got.file.pathExtension)
            try FileManager.default.copyItem(at: got.file, to: to)
            return PickedMovie(url: to)
        }
    }
}

/// The camera for a story: a photo, or a video up to 30 seconds.
struct MediaCamera: UIViewControllerRepresentable {
    let onDone: (UIImage?, URL?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        p.videoMaximumDuration = 30
        p.videoQuality = .typeHigh
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?, URL?) -> Void
        init(_ f: @escaping (UIImage?, URL?) -> Void) { onDone = f }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage, info[.mediaURL] as? URL)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil, nil) }
    }
}

/// One of today's foods (or a saved meal) for a sticker.
struct FoodStickerPicker: View {
    var pick: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }
    var body: some View {
        NavigationStack {
            List {
                let items = store.todayItems
                if items.isEmpty { Text("Log something today to add it as a sticker.").foregroundStyle(.secondary) }
                ForEach(items.indices, id: \.self) { i in
                    Button { pick(items[i]); dismiss() } label: {
                        HStack(spacing: 12) {
                            FoodDot(name: str(items[i]["name"]), size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(str(items[i]["name"])).font(.subheadline.weight(.semibold))
                                Text("\(Fmt.int(num(items[i]["kcal"]) ?? 0)) kcal").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Food sticker").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// A story you were mentioned in, being added to your own: their picture placed like a sticker over a soft copy of
/// itself, their name under it (so they're told, and whoever watches can go to them). Everything can be moved, and
/// anything else added, before it's shared.
struct StoryReshare: View {
    let story: JSON
    @Environment(\.dismiss) private var dismiss
    /// Their story as it's watched: the photo with everything they put on it (18 Nov: only the bare photo came, so
    /// their words, drawing and stickers were lost).
    @State private var whole: UIImage?
    @State private var full = false   // their story as the whole of yours, or as a card over a soft copy of it
    @State private var failed = false

    private var owner: String { str(story["owner"]) }
    private var name: String { let u = Profiles.shared.all[owner]?.username ?? ""; return u.isEmpty ? Feed.shared.name(owner) : u }
    /// Says whose it is: the viewer shows "↻ their name" by yours at the top. Not drawn on the story itself.
    private var repost: JSON { ["id": "repost", "type": "repost", "user": owner, "name": name, "x": 0.5, "y": 0.02, "scale": 1.0, "rotation": 0.0] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let whole {
                Group {
                    if full {
                        StoryEditor(image: whole, video: nil, close: { dismiss() }, posted: { dismiss() }, startItems: [repost])
                    } else {
                        StoryEditor(image: StoryArt.backdrop(whole), video: nil, close: { dismiss() }, posted: { dismiss() }, startItems: [
                            ["id": "theirs", "type": "photo", "local": PhotoStickers.keep(whole),
                             "w": Double(whole.size.width), "h": Double(whole.size.height), "x": 0.5, "y": 0.45, "scale": 1.25, "rotation": 0.0],
                            ["id": "whose", "type": "mention", "user": owner, "name": name, "x": 0.5, "y": 0.88, "scale": 0.75, "rotation": 0.0],
                            repost,
                        ])
                    }
                }
                .id(full)   // a fresh editor for each way
                .overlay(alignment: .top) {
                    Picker("How", selection: $full) { Text("Sticker").tag(false); Text("Full screen").tag(true) }
                        .pickerStyle(.segmented).frame(width: 220).padding(.top, 118)
                        .environment(\.colorScheme, .dark)
                }
            } else if failed {
                VStack(spacing: 14) {
                    Text("Couldn't open that story.").foregroundStyle(.white)
                    Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .statusBarHidden()
        .task {
            guard whole == nil else { return }
            guard let img = await ImageStore.load(str(story["media"])) else { failed = true; return }
            // the photos stuck on it, here first, so the picture of it is made with them in
            for src in Stories.pictures(story) where src != str(story["media"]) { _ = await ImageStore.load(src) }
            whole = Self.render(story, base: img) ?? img
        }
    }

    /// Their story drawn into one picture at the story's shape: the photo, then what's on it, as it's watched.
    static func render(_ story: JSON, base: UIImage) -> UIImage? {
        let w = StoryArt.design, h = w / StoryArt.aspect
        let on = list(story["overlays"]).filter { !["song", "repost"].contains(str($0["type"])) }
        let picture = ZStack {
            Color.black
            Image(uiImage: base).resizable().scaledToFill().frame(width: w, height: h).clipped()
            StoryLayer(items: on)
        }
        .frame(width: w, height: h).clipped()
        .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: picture)
        r.scale = 3
        return r.uiImage
    }
}

/// A feed post being added to your own story (18 Nov), as Instagram lets you put a post or reel on yours: the post
/// as a card, straight and in the middle, over a soft copy of its photo, and a See post under it that opens the post
/// for whoever watches. Everything can be moved, and anything else added, before it's shared.
struct PostReshare: View {
    let post: JSON
    var done: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var ground: UIImage?
    @State private var items: [JSON] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let ground {
                StoryEditor(image: ground, video: nil, close: { dismiss() }, posted: { dismiss(); done() }, startItems: items)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .statusBarHidden()
        .task {
            guard ground == nil else { return }
            let photo: UIImage? = Feed.hasPhoto(post) ? await ImageStore.load(str(post["photo"])) : nil
            let card = PostStoryCard(post: post, photo: photo)
            let r = ImageRenderer(content: card.environment(\.colorScheme, .dark))
            r.scale = 3
            guard let img = r.uiImage else { dismiss(); return }
            items = [
                // style 1: the card as it is, rounded, with a soft shadow
                ["id": "post", "type": "photo", "local": PhotoStickers.keep(img), "style": 1,
                 "w": Double(img.size.width), "h": Double(img.size.height), "x": 0.5, "y": 0.42, "scale": 1.5, "rotation": 0.0],
                ["id": "seepost", "type": "seepost", "post": str(post["id"]), "x": 0.5, "y": 0.83, "scale": 1.0, "rotation": 0.0],
            ]
            ground = photo.map(StoryArt.backdrop) ?? Self.plainGround()
        }
    }

    /// For a post with no photo (a workout): the app's own dark blue, a little lighter at the top.
    static func plainGround() -> UIImage {
        let size = CGSize(width: 270, height: 480), format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            let colours = [UIColor(Theme.hero).cgColor, UIColor(Theme.bg).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
                c.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }
}

/// A post drawn as a card for a story: whose it is, its photo, and what it was. Made into a picture once, so it
/// looks the same for everyone and in every version.
struct PostStoryCard: View {
    let post: JSON
    let photo: UIImage?

    private var owner: String { str(post["owner"]) }
    private var who: String {
        let u = Profiles.shared.all[owner]?.username ?? ""
        if !u.isEmpty { return u }
        let n = Feed.shared.name(owner)
        return n == "You" ? Friends.shared.myName : n
    }
    private var line: String {
        let kind = str(post["kind"]), name = str(post["name"])
        if kind == "workout" { return "Workout · " + name }
        if kind == "photo" { return str(post["caption"]) }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(who.prefix(1)).uppercased()).font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28).background(Theme.hero, in: Circle())
                Text(who).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            picture
            if !line.isEmpty || str(post["kind"]) != "photo" { footer }
        }
        .frame(width: 300)
        .background(Color(white: 0.07))
    }

    @ViewBuilder private var picture: some View {
        if let photo {
            // its own shape, kept between 4:5 and 1.91:1 like the feed's
            let ratio = min(1.91, max(0.8, photo.size.width / max(1, photo.size.height)))
            Image(uiImage: photo).resizable().scaledToFill().frame(width: 300, height: 300 / ratio).clipped()
        } else {
            ZStack {
                LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(str(post["name"])).font(.system(size: 26, weight: .heavy)).foregroundStyle(.white).multilineTextAlignment(.center).padding(20)
            }
            .frame(width: 300, height: 220)
        }
    }

    private var footer: some View {
        let kcal = num(post["kcal"]) ?? 0, protein = num(dict(post["macros"])["p"])
        let food = str(post["kind"]) != "workout" && str(post["kind"]) != "photo"
        return HStack(spacing: 7) {
            Text(line).foregroundStyle(.white).lineLimit(1)
            if food && kcal > 0 { Text("\(Fmt.int(kcal)) kcal").foregroundStyle(.white.opacity(0.7)).fixedSize() }
            if food, let protein { Text("\(Int(protein)) g protein").foregroundStyle(Theme.walk).fixedSize() }
        }
        .font(.system(size: 13, weight: .bold))
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// One of your saved meals for a recipe sticker (18 Nov): the ones with a method first. The sticker carries the meal,
/// so whoever watches can open the recipe, save it to their meals or have a portion today.
struct RecipeStickerPicker: View {
    var pick: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    private var meals: [JSON] {
        let all = list(store.doc["meals"]).filter { !str($0["name"]).isEmpty && !list($0["items"]).isEmpty }
        return all.filter { !Self.steps($0).isEmpty } + all.filter { Self.steps($0).isEmpty }
    }
    static func steps(_ m: JSON) -> [String] { (m["steps"] as? [String] ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// The sticker for a meal: its name, a portion's numbers, how many ingredients and steps, and the meal itself.
    static func sticker(_ m: JSON) -> JSON {
        let b = Store.shared.mealBasis(m)
        var meal = m
        if str(meal["photo"]).hasPrefix("data:") { meal["photo"] = nil }   // a photo kept in the meal itself is too big to carry
        return ["type": "recipe", "name": str(b["name"]), "kcal": Int(num(b["kcalPerServing"]) ?? 0), "p": Int(num(b["pServ"]) ?? 0),
                "c": Int(num(b["cServ"]) ?? 0), "f": Int(num(b["fServ"]) ?? 0), "n": list(m["items"]).count, "steps": steps(m).count, "meal": meal]
    }

    /// A tapped sticker as the post the recipe card opens with (PostRecipeSheet's meal kind).
    static func post(_ o: JSON, owner: String) -> JSON {
        let meal = dict(o["meal"])
        return ["id": "recipe:" + str(meal["id"]), "kind": "meal", "name": o["name"] ?? "", "kcal": o["kcal"] ?? 0, "owner": owner,
                "macros": ["p": o["p"] ?? 0, "c": o["c"] ?? 0, "f": o["f"] ?? 0] as JSON, "payload": meal]
    }

    var body: some View {
        NavigationStack {
            List {
                if meals.isEmpty { Text("Save a meal (Me, then Meals) to share it as a recipe.").foregroundStyle(.secondary) }
                ForEach(meals.indices, id: \.self) { i in
                    let m = meals[i], b = store.mealBasis(m), method = !Self.steps(m).isEmpty
                    Button { pick(m); dismiss() } label: {
                        HStack(spacing: 12) {
                            FoodDot(name: str(m["name"]), size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(str(m["name"])).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    if method { Text("METHOD").font(.caption2.weight(.heavy)).foregroundStyle(Theme.accent) }
                                }
                                Text("\(Fmt.int(num(b["kcalPerServing"]) ?? 0)) kcal · \(Int(num(b["pServ"]) ?? 0)) g protein a portion").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Recipe sticker").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
