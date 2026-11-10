import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Making a story: a photo or a video (up to 30 seconds) from the camera or the library, then the editor
/// (StoryEditor), then Close friends (friends only) or Your story (friends and followers).
struct StoryComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var video: URL?
    @State private var camera = false
    @State private var picked: PhotosPickerItem?
    @State private var loading = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // straight into the camera, as Instagram opens (the in-between Camera / Library screen is gone)
            if image == nil && video == nil { StoryCamera(captured: { img, url in image = img; video = url }, close: { dismiss() }) }
            else { StoryEditor(image: image, video: video, close: { image = nil; video = nil }, posted: { dismiss() }) }
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
