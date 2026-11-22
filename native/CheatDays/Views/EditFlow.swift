import AVFoundation
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
    @State private var draftPips: [EditPip]?
    @State private var attached: JSON?   // a meal, recipe or workout picked in the editor: the post carries it
    @State private var joinedLength = 0.0
    @State private var longFor: Share?   // a post or story of an edit over the limit: asking what to keep
    @State private var choosing: Share?  // picking which part to keep
    @State private var draftCut: [EditText]?
    @State private var didShare = false          // posted or shared, not backed out of
    @State private var broken: EditDrafts.Draft?  // a draft tapped that's missing some of itself
    @State private var importFailure: ImportFailure?
    @State private var joinedShape: CGFloat = VideoShape.tall

    struct VideoBox: Identifiable { let id = UUID(); let url: URL }
    enum Share: String, Identifiable { case post, story; var id: String { rawValue } }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea().importFailed($importFailure)
            Color.clear.frame(width: 0, height: 0).modifier(BrokenDraft(draft: $broken, open: { open($0) }, delete: { removeDraft($0) }))
            if let clips {
                MultiClipEditor(clips: clips, draftID: draftID, startSoundOf: draftSound, startLook: draftLook,
                                startTexts: draftTexts, startAttached: draftAttached, startSounds: draftSounds, startPips: draftPips, startCut: draftCut,
                                close: { closed() },
                                done: { url in
                                    joined = url; self.clips = nil; joinedLength = 0
                                    Task {
                                        joinedShape = await VideoShape.of(url)
                                        joinedLength = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sharing = true }
                                },
                                autosaved: { draftID = $0 },   // a new edit's own draft, let go once it's shared
                                keepsDraft: true,
                                attach: { attached = $0 })
            } else if let joined {
                // the edit, playing, with what to do with it
                ZStack(alignment: .top) {
                    Color.black.ignoresSafeArea()
                    LoopingVideo(url: joined).aspectRatio(joinedShape, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                           openDraft: { d in if d.missing != nil { broken = d } else { open(d) } },
                           deleteDraft: { d in removeDraft(d) })
            }
            if working { Color.black.opacity(0.4).ignoresSafeArea(); ProgressView().tint(.white) }
        }
        .preferredColorScheme(.dark)
        .onAppear { refreshDrafts() }
        // All albums, or a library the app can't see: the system's own picker
        .photosPicker(isPresented: $library, selection: $picks, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: picks) { _, now in
            guard !now.isEmpty else { return }
            picks = []
            load(now)
        }
        .sheet(isPresented: $sharing) { shareSheet.presentationDetents([.height(330)]).presentationDragIndicator(.visible) }
        // a post or a story of it: shared, so is this done; backed out of, back to the finished video (22 Nov audit:
        // either way this closed, and the draft had gone already)
        .sheet(item: $posting, onDismiss: { composerClosed() }) { b in postComposer(b.url) }
        .fullScreenCover(item: $story, onDismiss: { composerClosed() }) { b in storyComposer(b.url) }
        // over the limit: what to keep (design: the 21 Nov chat; the whole of it can still be saved to Photos)
        .alert("Longer than \(Int(Stories.longest)) seconds", isPresented: Binding(get: { longFor != nil }, set: { if !$0 { longFor = nil } })) {
            Button("Use the first \(Int(Stories.longest)) seconds") { if let k = longFor { longFor = nil; send(k) } }
            Button("Choose which \(Int(Stories.longest)) seconds") { let k = longFor; longFor = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { choosing = k } }
            Button("Save the whole video to Photos") { longFor = nil; save() }
            Button("Cancel", role: .cancel) { longFor = nil }
        } message: {
            Text("A \(longFor == .story ? "story" : "post") keeps \(Int(Stories.longest)) seconds of it. Saved to Photos, it keeps all \(Self.clock(joinedLength)).")
        }
        .sheet(item: $choosing) { k in
            if let joined {
                PartPicker(url: joined, length: joinedLength, shape: joinedShape) { from in
                    choosing = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sendPart(k, from: from) }
                }
            }
        }
    }

    private var shareSheet: some View {
        VStack(spacing: 10) {
            Text("Share your edit").font(.headline).padding(.top, 18)
            option("square.grid.3x3", "Post", "On your profile and the feed") { share(.post) }
            option("plus.circle", "Story", "For 24 hours") { share(.story) }
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

    /// A post or story of the edit; one over the limit asks first what to keep (21 Nov: it was cut at the limit
    /// without a word).
    private func share(_ kind: Share) {
        guard joinedLength > Stories.longest + 0.05 else { send(kind); return }
        sharing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { longFor = kind }
    }

    private func send(_ kind: Share, _ url: URL? = nil) {
        go(url) { u in if kind == .post { posting = VideoBox(url: u) } else { story = VideoBox(url: u) } }
    }

    /// The part picked, as a file of its own, then on to the post or story with it.
    private func sendPart(_ kind: Share, from: Double) {
        guard let joined else { return }
        working = true
        Task {
            let part = await ClipJoin.part(joined, from: from, length: Stories.longest)
            working = false
            if let part { send(kind, part) } else { flash("Couldn't keep that part. Try again.") }
        }
    }

    private func flash(_ s: String) {
        Task {
            withAnimation { note = s }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { note = nil }
        }
    }

    /// The sheet put away first, then on to the post or story with the edit (or `url`, part of it).
    private func go(_ url: URL? = nil, _ open: @escaping (URL) -> Void) {
        guard let file = url ?? joined else { return }
        sharing = false
        didShare = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { open(file) }
    }

    /// A post of it: its draft's let go only once the post is up (a failed upload can still go back to it).
    private func postComposer(_ url: URL) -> some View {
        let id: String? = draftID, opened = Date()
        return ComposeSheet(preset: attached, video: url, shared: { didShare = true },
                            sent: { Self.letGo(id, sharedAt: opened) })
    }

    private func storyComposer(_ url: URL) -> some View {
        let id: String? = draftID, opened = Date()
        return StoryComposer(video: url, shared: {
            didShare = true
            Self.letGo(id, sharedAt: opened)
        })
    }

    private static func letGo(_ id: String?, sharedAt: Date) {
        guard let id else { return }
        EditDrafts.queue.async { EditDrafts.delete(id, sharedAt: sharedAt) }
    }

    private func composerClosed() {
        if didShare { dismiss() } else { Sound.on(.moviePlayback) }
    }

    private func closed() {
        clips = nil; draftID = nil; draftSound = nil; draftLook = nil; draftTexts = nil; draftAttached = nil
        draftSounds = nil; draftPips = nil; draftCut = nil; attached = nil
        refreshDrafts()
    }

    private func open(_ d: EditDrafts.Draft) {
        draftID = d.id; draftSound = d.soundOf; draftLook = d.look; draftTexts = d.texts; draftAttached = d.attachedJSON
        draftSounds = d.sounds; draftPips = d.pips; draftCut = d.cut
        joined = nil
        clips = d.clips
    }

    private func removeDraft(_ d: EditDrafts.Draft) {
        let id: String = d.id
        EditDrafts.queue.async { EditDrafts.delete(id) }
        refreshDrafts()
    }

    private func load(_ items: [PhotosPickerItem]) {
        working = true
        Task {
            let loaded: (clips: [Clip], failed: [Int]) = await MultiClipEditor.load(items)
            working = false
            let got: [Clip] = loaded.clips
            let go: () -> Void = { if !got.isEmpty { clips = got } }
            if loaded.failed.isEmpty { go(); return }
            try? await Task.sleep(for: .milliseconds(450))
            importFailure = ImportFailure(total: items.count, failed: loaded.failed, retry: { load(items) }, carryOn: got.isEmpty ? nil : go)
        }
    }

    /// Back from the finished video to its clips, as they were left (its auto-saved draft). The video stays up till
    /// they're in hand.
    private func backToClips() {
        guard let id = draftID else { flash("Couldn't open the clips. Save the video to Photos first."); return }
        EditDrafts.queue.async {
            let d: EditDrafts.Draft? = EditDrafts.all().first { $0.id == id }
            DispatchQueue.main.async {
                if let d, d.missing == nil { open(d) } else { flash("Couldn't open the clips. Save the video to Photos first.") }
            }
        }
    }

    /// The drafts as they are once any saving still going has finished.
    private func refreshDrafts() {
        EditDrafts.queue.async { let all = EditDrafts.all(); DispatchQueue.main.async { drafts = all } }
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func save() {
        guard let joined else { return }
        Task {
            let ok: PHAuthorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            let said: String
            if ok == .authorized || ok == .limited {
                do {
                    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: joined) }
                    said = "Saved to Photos"
                } catch {
                    said = "Couldn't save it. Check your storage and try again."
                }
            } else {
                said = "Couldn't save it: allow Photos in Settings"
            }
            withAnimation { note = said }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { note = nil }
        }
    }
}

/// A draft tapped that's missing some of itself: said, and opened without that if there's enough left.
private struct BrokenDraft: ViewModifier {
    @Binding var draft: EditDrafts.Draft?
    let open: (EditDrafts.Draft) -> Void
    let delete: (EditDrafts.Draft) -> Void

    func body(content: Content) -> some View {
        let showing = Binding<Bool>(get: { draft != nil }, set: { (on: Bool) in if !on { draft = nil } })
        return content.alert("This draft is damaged", isPresented: showing, presenting: draft) { (d: EditDrafts.Draft) in
            if !d.withoutMissing.clips.isEmpty {
                Button("Open without them") { open(d.withoutMissing) }
            }
            Button("Delete draft", role: .destructive) { delete(d) }
            Button("Cancel", role: .cancel) {}
        } message: { (d: EditDrafts.Draft) in
            Text(d.missing ?? "")
        }
    }
}
