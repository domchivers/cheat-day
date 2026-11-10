import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Making a story: a photo or a video (up to 30 seconds) from the camera or the library, then text and food stickers
/// dragged into place, then Close friends (friends only) or Your story (friends and followers).
struct StoryComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var video: URL?
    @State private var camera = false
    @State private var picked: PhotosPickerItem?
    @State private var overlays: [JSON] = []
    @State private var writing = false
    @State private var draft = ""
    @State private var choosingFood = false
    @State private var dragging: Int?
    @State private var start: CGPoint = .zero
    @State private var pinchFrom: Double = 1
    @FocusState private var typing: Bool
    private var stories: Stories { Stories.shared }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if image == nil && video == nil { pick } else { edit }
        }
        .statusBarHidden()
        .fullScreenCover(isPresented: $camera) {
            MediaCamera { img, url in camera = false; image = img; video = url }.ignoresSafeArea()
        }
        .onChange(of: picked) { _, item in Task { await load(item) } }
        .sheet(isPresented: $choosingFood) {
            FoodStickerPicker { it in
                let m = Store.shared.macros([it])
                overlays.append(["type": "food", "name": it["name"] ?? "", "kcal": it["kcal"] ?? 0, "p": Int(m.p), "x": 0.5, "y": 0.68, "scale": 1.0])
            }
            .presentationDetents([.medium, .large])
        }
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
            if stories.posting { ProgressView().tint(.white) }
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
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let m = try? await item.loadTransferable(type: PickedMovie.self) { video = m.url; image = nil }
        else if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { image = img; video = nil }
        picked = nil
    }

    // MARK: placing text and stickers

    private var edit: some View {
        VStack(spacing: 10) {
            GeometryReader { g in
                ZStack {
                    if let video { LoopingVideo(url: video) } else if let image { Image(uiImage: image).resizable().scaledToFill() }
                    ForEach(overlays.indices, id: \.self) { i in
                        StoryOverlays.view(overlays[i])
                            .scaleEffect(num(overlays[i]["scale"]) ?? 1)
                            .position(x: (num(overlays[i]["x"]) ?? 0.5) * g.size.width, y: (num(overlays[i]["y"]) ?? 0.5) * g.size.height)
                            .gesture(DragGesture()
                                .onChanged { v in
                                    if dragging != i { dragging = i; start = CGPoint(x: num(overlays[i]["x"]) ?? 0.5, y: num(overlays[i]["y"]) ?? 0.5) }
                                    overlays[i]["x"] = min(0.95, max(0.05, start.x + v.translation.width / g.size.width))
                                    overlays[i]["y"] = min(0.95, max(0.05, start.y + v.translation.height / g.size.height))
                                }
                                .onEnded { _ in dragging = nil })
                            .simultaneousGesture(MagnificationGesture()
                                .onChanged { m in if dragging == nil { overlays[i]["scale"] = min(3, max(0.5, pinchFrom * m)) } }
                                .onEnded { _ in pinchFrom = num(overlays[i]["scale"]) ?? 1 })
                            .onLongPressGesture { overlays.remove(at: i) }
                    }
                    if writing {
                        Color.black.opacity(0.45)
                        TextField("", text: $draft, axis: .vertical).focused($typing)
                            .font(.system(size: 28, weight: .heavy)).foregroundStyle(.white).multilineTextAlignment(.center)
                            .padding(30).onSubmit { finishText() }.submitLabel(.done)
                    }
                }
                .frame(width: g.size.width, height: g.size.height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .top) {
                    HStack {
                        Button { image = nil; video = nil; overlays = [] } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.white).padding(10).background(.black.opacity(0.4), in: Circle()) }
                        Spacer()
                        if writing { Button("Done") { finishText() }.font(.headline).foregroundStyle(.white) }
                    }
                    .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    if !writing {
                        VStack(spacing: 14) {
                            tool("textformat") { draft = ""; writing = true; typing = true }.accessibilityLabel("Add text")
                            tool("fork.knife") { choosingFood = true }.accessibilityLabel("Add a food sticker")
                        }
                        .padding(.top, 70).padding(.trailing, 12)
                    }
                }
            }
            if !overlays.isEmpty { Text("Drag to move, pinch to size, hold to remove").font(.caption).foregroundStyle(.white.opacity(0.6)) }
            if let e = stories.error { Text(e).font(.caption).foregroundStyle(Theme.warn).multilineTextAlignment(.center) }
            HStack(spacing: 10) {
                Button { share("friends") } label: {
                    Label("Close friends", systemImage: "star.fill").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color(white: 0.16), in: Capsule())
                }
                Button { share("all") } label: {
                    Text(stories.posting ? "Sharing…" : "Your story →").font(.headline).foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .buttonStyle(.plain).disabled(stories.posting || writing)
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .padding(.horizontal, 8)
    }

    private func tool(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func finishText() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { overlays.append(["type": "text", "text": String(t.prefix(120)), "x": 0.5, "y": 0.35, "scale": 1.0]) }
        draft = ""; writing = false; typing = false
    }

    private func share(_ audience: String) {
        Task { if await stories.post(image: image, video: video, overlays: overlays, audience: audience) { dismiss() } }
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
