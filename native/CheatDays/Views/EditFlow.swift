import Photos
import PhotosUI
import SwiftUI

/// Make an edit (19 Nov; design/make-an-edit-mockup.html), from the + on your profile or Your story: your videos
/// (several at once) into the multi-clip editor, and then a post, a story, or the video saved to Photos.
struct EditFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var clips: [Clip]?
    @State private var joined: URL?
    @State private var sharing = false
    @State private var posting: VideoBox?
    @State private var story: VideoBox?
    @State private var library = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var note: String?
    @State private var working = false
    @State private var drafts: [EditDrafts.Draft] = []
    @State private var draftID: String?          // the draft being carried on with, let go once it's shared
    @State private var draftSound: UUID?
    @State private var draftLook: EditLook?
    @State private var draftTexts: [EditText]?
    @State private var draftAttached: JSON?
    @State private var draftSounds: [EditSound]?
    @State private var attached: JSON?   // a meal, recipe or workout picked in the editor: the post carries it

    struct VideoBox: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let clips {
                MultiClipEditor(clips: clips, draftID: draftID, startSoundOf: draftSound, startLook: draftLook,
                                startTexts: draftTexts, startAttached: draftAttached, startSounds: draftSounds,
                                close: { self.clips = nil; draftID = nil; draftSound = nil; draftLook = nil; draftTexts = nil; draftAttached = nil; draftSounds = nil; attached = nil; refreshDrafts() },
                                done: { url in
                                    joined = url; self.clips = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sharing = true }
                                },
                                autosaved: { draftID = $0 },   // a new edit's own draft, let go once it's shared
                                keepsDraft: true,
                                attach: { attached = $0 })
            } else if let joined {
                // the edit, playing, with what to do with it
                ZStack(alignment: .top) {
                    Color.black.ignoresSafeArea()
                    LoopingVideo(url: joined).aspectRatio(9.0 / 16.0, contentMode: .fit).frame(maxHeight: .infinity)
                    HStack {
                        Button { backToClips() } label: {
                            Image(systemName: "chevron.backward").font(.headline).frame(width: 40, height: 40).background(.white.opacity(0.15), in: Circle())
                        }
                        .accessibilityLabel("Back to the clips")
                        Spacer()
                        Button("Share") { sharing = true }
                            .font(.subheadline.weight(.bold)).padding(.horizontal, 18).frame(height: 40)
                            .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).padding(.top, 8)
                    // its sound heard with the ringer off, as the editor's was; given back once it's left
                    Color.clear.frame(width: 0, height: 0)
                        .onAppear { Sound.on(.moviePlayback) }
                        .onDisappear { Sound.off() }
                    if let note {
                        Text(note).font(.subheadline.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 16).frame(height: 38)
                            .background(.white, in: Capsule()).padding(.top, 70).transition(.opacity)
                    }
                }
            } else {
                PostPicker(room: 10, photosOnly: false,
                           done: { _, video in
                               // (one video, as a picker without clips would send it: a clip of its own)
                               guard let video else { return }
                               Task { if let c = await ClipJoin.clip(video) { clips = [c] } }
                           },
                           clips: { clips = $0 },
                           camera: {},
                           allPhotos: { library = true },
                           close: { dismiss() },
                           editMode: true,
                           drafts: drafts,
                           openDraft: { d in draftID = d.id; draftSound = d.soundOf; draftLook = d.look; draftTexts = d.texts; draftAttached = d.attachedJSON; draftSounds = d.sounds; clips = d.clips },
                           deleteDraft: { d in EditDrafts.queue.async { EditDrafts.delete(d.id) }; refreshDrafts() })
            }
            if working { Color.black.opacity(0.4).ignoresSafeArea(); ProgressView().tint(.white) }
        }
        .preferredColorScheme(.dark)
        .onAppear { refreshDrafts() }
        // All albums, or a library the app can't see: the system's own picker
        .photosPicker(isPresented: $library, selection: $picks, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: picks) { _, now in
            guard !now.isEmpty else { return }
            working = true
            Task { let c = await MultiClipEditor.clips(from: now); picks = []; working = false; if !c.isEmpty { clips = c } }
        }
        .sheet(isPresented: $sharing) { shareSheet.presentationDetents([.height(330)]).presentationDragIndicator(.visible) }
        // a post or a story of it: once that's done, so is this
        .sheet(item: $posting, onDismiss: { dismiss() }) { b in ComposeSheet(preset: attached, video: b.url) }
        .fullScreenCover(item: $story, onDismiss: { dismiss() }) { b in StoryComposer(video: b.url) }
    }

    private var shareSheet: some View {
        VStack(spacing: 10) {
            Text("Share your edit").font(.headline).padding(.top, 18)
            option("square.grid.3x3", "Post", "On your profile and the feed") { go { posting = VideoBox(url: $0) } }
            option("plus.circle", "Story", "For 24 hours") { go { story = VideoBox(url: $0) } }
            option("square.and.arrow.down", "Save to Photos", "Keep the video") { sharing = false; save() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .presentationBackground(Theme.bg)
    }

    private func option(_ icon: String, _ title: String, _ sub: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 42, height: 42)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The sheet put away first, then on to the post or story with the edit.
    private func go(_ open: @escaping (URL) -> Void) {
        guard let joined else { return }
        sharing = false
        if let id = draftID { EditDrafts.queue.async { EditDrafts.delete(id) }; draftID = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { open(joined) }
    }

    /// Back from the finished video to its clips, as they were left (its auto-saved draft).
    private func backToClips() {
        joined = nil
        guard let id = draftID else { refreshDrafts(); return }
        EditDrafts.queue.async {
            let d = EditDrafts.all().first { $0.id == id }
            DispatchQueue.main.async { if let d { draftSound = d.soundOf; draftLook = d.look; draftTexts = d.texts; draftAttached = d.attachedJSON; draftSounds = d.sounds; clips = d.clips } else { draftID = nil; refreshDrafts() } }
        }
    }

    /// The drafts as they are once any saving still going has finished.
    private func refreshDrafts() {
        EditDrafts.queue.async { let all = EditDrafts.all(); DispatchQueue.main.async { drafts = all } }
    }

    private func save() {
        guard let joined else { return }
        Task {
            let ok = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            var saved = false
            if ok == .authorized || ok == .limited {
                saved = (try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: joined) }) != nil
            }
            withAnimation { note = saved ? "Saved to Photos" : "Couldn't save it: allow Photos in Settings" }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { note = nil }
        }
    }
}
