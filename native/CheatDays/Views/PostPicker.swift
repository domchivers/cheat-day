import AVFoundation
import Photos
import SwiftUI

/// Choosing what to post, the way Instagram does it: the one picked shown big at the top, your recent photos and
/// videos in a grid under it (the camera first), a switch to pick several photos, and Next. If the app isn't
/// allowed to see the library, or only part of it, "All photos" opens the system's own picker, which needs no leave.
struct PostPicker: View {
    /// How many more photos the post can take.
    var room = 10
    /// The post already has photos: only photos can be added.
    var photosOnly = false
    var done: ([UIImage], URL?) -> Void
    var camera: () -> Void
    var allPhotos: () -> Void
    var close: () -> Void

    @State private var assets: [PHAsset] = []
    @State private var allowed = true
    @State private var several = false
    @State private var picked: [String] = []   // their ids, in the order picked
    @State private var showing: PHAsset?
    @State private var big: UIImage?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                HStack(spacing: 10) {
                    Text("Recents").font(.title3.weight(.heavy))
                    Button { allPhotos() } label: { Text("All photos").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent) }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    if room > 1 {
                        Button { toggleSeveral() } label: {
                            Label(several ? "Selecting" : "Select", systemImage: "square.on.square")
                                .font(.subheadline.weight(.bold)).foregroundStyle(several ? Theme.onAccent : Color.primary)
                                .padding(.horizontal, 13).frame(height: 36)
                                .background(several ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                        }
                        .buttonStyle(.plain).accessibilityLabel(several ? "Stop picking several" : "Pick several")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                if !allowed {
                    VStack(spacing: 12) {
                        Text("Cheat Days can't see your photos here.").font(.subheadline).foregroundStyle(.secondary)
                        Button { allPhotos() } label: {
                            Text("Choose from all photos").font(.subheadline.weight(.bold)).foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 18).frame(height: 42).background(Theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { grid }
            }
            .background(Theme.bg.ignoresSafeArea())
            .overlay { if busy { ZStack { Color.black.opacity(0.35).ignoresSafeArea(); ProgressView().controlSize(.large).tint(.white) } } }
            .navigationTitle("New post").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close") }
                ToolbarItem(placement: .confirmationAction) { Button("Next") { next() }.fontWeight(.bold).disabled(picked.isEmpty || busy) }
            }
            .task { await load() }
            .task(id: showing?.localIdentifier) { await enlarge() }
        }
        .presentationBackground(Theme.bg)
    }

    // MARK: the one picked, big

    private var preview: some View {
        Color.black.opacity(0.5)
            .overlay {
                if let big { Image(uiImage: big).resizable().scaledToFit() }
                else if allowed && !assets.isEmpty { ProgressView() }
                else { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.tertiary) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let a = showing, a.mediaType == .video {
                    Label(clock(a.duration), systemImage: "video.fill").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 26).background(.black.opacity(0.55), in: Capsule()).padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if several && picked.count > 1 {
                    Text("\(picked.count) of \(room)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 26).background(.black.opacity(0.55), in: Capsule()).padding(10)
                }
            }
            .frame(maxWidth: .infinity).frame(height: min(UIScreen.main.bounds.width, UIScreen.main.bounds.height * 0.42))
            .clipped()
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    // MARK: the grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                Button { camera() } label: {
                    Color(.secondarySystemGroupedBackground).aspectRatio(1, contentMode: .fit)
                        .overlay { Image(systemName: "camera.fill").font(.system(size: 24)).foregroundStyle(.primary) }
                }
                .buttonStyle(.plain).accessibilityLabel("Camera")
                ForEach(assets, id: \.localIdentifier) { a in
                    let at = picked.firstIndex(of: a.localIdentifier), dim = several && photosOrLocked(a)
                    Button { tap(a) } label: {
                        SquareThumb(asset: a)
                            .overlay { if showing?.localIdentifier == a.localIdentifier { Color.white.opacity(0.28) } }
                            .overlay(alignment: .topTrailing) {
                                if several && !dim {
                                    ZStack {
                                        Circle().fill(at == nil ? AnyShapeStyle(Color.black.opacity(0.25)) : AnyShapeStyle(Theme.accent))
                                        Circle().stroke(.white, lineWidth: 1.5)
                                        if let at { Text("\(at + 1)").font(.caption2.weight(.heavy)).foregroundStyle(Theme.onAccent) }
                                    }
                                    .frame(width: 22, height: 22).padding(5)
                                }
                            }
                            .opacity(dim ? 0.35 : 1)
                    }
                    .buttonStyle(.plain).disabled(dim)
                }
            }
            .padding(.bottom, 20)
        }
    }

    /// A video can't be one of several (a post is photos, or one video).
    private func photosOrLocked(_ a: PHAsset) -> Bool { a.mediaType == .video }

    private func toggleSeveral() {
        UISelectionFeedbackGenerator().selectionChanged()
        several.toggle()
        // back to one: the one showing; into several: the one showing first, unless it's a video
        if several { picked = [] } else if let s = showing { picked = [s.localIdentifier] }
    }

    private func tap(_ a: PHAsset) {
        let id = a.localIdentifier
        if several {
            if let i = picked.firstIndex(of: id) { picked.remove(at: i) }
            else if picked.count < room { picked.append(id) }
            else { UINotificationFeedbackGenerator().notificationOccurred(.warning); return }
            if picked.contains(id) || showing == nil { showing = a }
        } else {
            picked = [id]; showing = a
        }
    }

    // MARK: loading

    private func load() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            // once the picker has finished coming up: asked while it was still arriving, the question didn't show,
            // and Recents sat empty until something else brought it out
            try? await Task.sleep(for: .milliseconds(700))
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { allowed = false; return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 200
        opts.predicate = photosOnly ? NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            : NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let found = PHAsset.fetchAssets(with: opts)
        var out: [PHAsset] = []
        found.enumerateObjects { a, _, _ in out.append(a) }
        assets = out
        if let first = out.first, showing == nil { showing = first; picked = [first.localIdentifier] }
        if out.isEmpty { allowed = status == .authorized }
    }

    /// The one showing, big enough for the top of the screen (a video's first frame).
    private func enlarge() async {
        guard let a = showing else { big = nil; return }
        let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true
        let id = a.localIdentifier
        PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 1200, height: 1200), contentMode: .aspectFit, options: o) { img, _ in
            DispatchQueue.main.async { if let img, showing?.localIdentifier == id { big = img } }
        }
    }

    /// Next: the photos picked, in order and at a size to edit, or the one video copied where the editor can read it.
    private func next() {
        let chosen = picked.compactMap { id in assets.first { $0.localIdentifier == id } }
        guard !chosen.isEmpty else { return }
        busy = true
        if let v = chosen.first, v.mediaType == .video {
            let o = PHVideoRequestOptions(); o.isNetworkAccessAllowed = true; o.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: v, options: o) { av, _, _ in
                guard let u = (av as? AVURLAsset)?.url else { DispatchQueue.main.async { busy = false }; return }
                let to = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + u.pathExtension)
                try? FileManager.default.copyItem(at: u, to: to)
                DispatchQueue.main.async { busy = false; done([], to) }
            }
            return
        }
        Task {
            var out: [UIImage] = []
            for a in chosen where a.mediaType == .image { if let img = await Self.full(a) { out.append(img) } }
            busy = false
            if !out.isEmpty { done(out, nil) }
        }
    }

    private static func full(_ a: PHAsset) async -> UIImage? {
        await withCheckedContinuation { c in
            let o = PHImageRequestOptions(); o.isNetworkAccessAllowed = true; o.deliveryMode = .highQualityFormat; o.resizeMode = .exact
            // highQualityFormat calls back once, with the finished picture
            var answered = false   // and if it ever called twice, the second is let go: answering twice is a crash
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 2400, height: 2400), contentMode: .aspectFit, options: o) { img, _ in
                if !answered { answered = true; c.resume(returning: img) }
            }
        }
    }
}

private struct SquareThumb: View {
    let asset: PHAsset
    @State private var img: UIImage?
    var body: some View {
        Color(white: 0.15).aspectRatio(1, contentMode: .fit)
            .overlay { if let img { Image(uiImage: img).resizable().scaledToFill() } }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(String(format: "%d:%02d", Int(asset.duration) / 60, Int(asset.duration) % 60)).font(.caption2.weight(.heavy)).foregroundStyle(.white).shadow(radius: 2).padding(5)
                }
            }
            .task(id: asset.localIdentifier) {
                let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 260, height: 260), contentMode: .aspectFill, options: o) { i, _ in
                    DispatchQueue.main.async { if let i { img = i } }
                }
            }
    }
}
