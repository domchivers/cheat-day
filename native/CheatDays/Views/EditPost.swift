import AVFoundation
import SwiftUI

/// Your post, after it's on the feed. The picture stays the picture it is, but it can be cropped and placed again
/// (a video trimmed, cropped and given another cover; several photos put in another order, or one taken out), and
/// everything about it can change: the caption, the song, and the food, meal or workout that goes with it.
struct EditPostSheet: View {
    let post: JSON
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @FocusState private var typing: Bool
    // what goes with it
    @State private var what: JSON?
    @State private var whatChanged = false
    @State private var attaching = false
    @State private var shelf = 0
    @State private var song: Song?
    @State private var choosingSong = false
    // its photos, in order: each where it is now, and as cropped again here
    @State private var pics: [Pic] = []
    @State private var showing = 0
    @State private var picsChanged = false
    @State private var editing: Recrop?
    // its video: fetched to the phone to work on; how it was edited again; its new cover
    @State private var local: URL?
    @State private var clip: ClipEdit?
    @State private var poster: UIImage?
    @State private var cover: Double?
    @State private var cutting = false
    @State private var choosingCover = false
    @State private var busy = false
    @State private var problem: String?
    @State private var opened = false

    private struct Pic: Identifiable { let id = UUID(); var url: String; var fresh: UIImage? }
    private struct Recrop: Identifiable { let id = UUID(); let image: UIImage; let index: Int }

    private var isVideo: Bool { Feed.video(post) != nil }
    private var kind: String { str(post["kind"]) }
    private var shape: CGFloat { CGFloat(min(1.91, max(0.5, num(dict(post["extra"])["aspect"]) ?? 0.8))) }
    private var firstShape: CGFloat { pics.first?.fresh.map { $0.size.width / max($0.size.height, 1) } ?? min(1.91, max(0.8, shape)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if isVideo || !pics.isEmpty {
                        picture.padding(.top, 14)
                        pictureButtons.padding(.top, 12)
                        if pics.count > 1 { strip.padding(.top, 10) }
                    }
                    TextField("Write a caption…", text: $caption, axis: .vertical).lineLimit(2...8).focused($typing)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .contentShape(Rectangle()).onTapGesture { typing = true }
                        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
                    if kind != "moment" { attachment.padding(.horizontal, 14) }
                    songRow.padding(.horizontal, 14).padding(.top, 10)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 10) }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .keyboardDone()
            .navigationTitle("Edit post").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Done") { typing = false; save() }.fontWeight(.bold) }
                }
            }
            .onAppear(perform: start)
            .onDisappear { SongPlayer.shared.stop() }
            .task { await fetchVideo() }
            .sheet(isPresented: $attaching) { AttachPicker(start: shelf) { what = $0; whatChanged = true } }
            .sheet(isPresented: $choosingSong) { SongPicker { song = $0 } }
            .sheet(isPresented: $choosingCover) {
                if let local { CoverPicker(url: local, edit: clip ?? ClipEdit(cover: cover), start: poster) { at, still in cover = at; clip?.cover = at; if let still { poster = still } } }
            }
            .fullScreenCover(item: $editing) { e in
                // the first photo can take another shape; the ones after keep the first one's
                let own = e.image.size.width / max(e.image.size.height, 1)
                StoryEditor(image: e.image, video: nil, aspect: e.index > 0 ? firstShape : min(1.91, max(0.8, own)), close: { editing = nil }, finish: { out in
                    if pics.indices.contains(e.index) { pics[e.index].fresh = out; picsChanged = true }
                    editing = nil
                }, lockShape: e.index > 0)
            }
            .fullScreenCover(isPresented: $cutting) {
                if let local {
                    StoryEditor(image: nil, video: local, close: { cutting = false }, finishVideo: { e in
                        clip = e; cover = nil; cutting = false
                        Task { poster = await e.still(local) }
                    })
                }
            }
        }
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(busy)
    }

    // MARK: the picture

    private var picture: some View {
        Color.black.opacity(0.35)
            .overlay {
                if isVideo {
                    if let poster { Image(uiImage: poster).resizable().scaledToFit() } else { FeedPhoto(src: str(post["photo"])) }
                } else if pics.indices.contains(showing) {
                    if let f = pics[showing].fresh { Image(uiImage: f).resizable().scaledToFit() } else { FeedPhoto(src: pics[showing].url) }
                }
            }
            .frame(width: 210, height: 262)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                if isVideo {
                    Image(systemName: "video.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(.black.opacity(0.55), in: Circle()).padding(8)
                } else if pics.count > 1 {
                    Text("\(min(showing, pics.count - 1) + 1)/\(pics.count)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 26).background(.black.opacity(0.55), in: Capsule()).padding(8)
                }
            }
    }

    /// What can be done to the picture, as buttons under it.
    private var pictureButtons: some View {
        HStack(spacing: 10) {
            if isVideo {
                pill("crop", local == nil ? "Getting the video…" : "Trim and crop") { cutting = true }.disabled(local == nil).opacity(local == nil ? 0.5 : 1)
                pill("photo", "Cover") { choosingCover = true }.disabled(local == nil).opacity(local == nil ? 0.5 : 1)
            } else {
                pill("crop", "Crop and edit") { recrop(showing) }
            }
        }
    }

    private func pill(_ symbol: String, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Theme.accent).padding(.horizontal, 16).frame(height: 40).background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func recrop(_ i: Int) {
        guard pics.indices.contains(i) else { return }
        let p = pics[i]
        Task { if let img = await (p.fresh != nil ? p.fresh : ImageStore.load(p.url)) { editing = Recrop(image: img, index: i) } }
    }

    /// Several photos: the row of them, to show one, and hold one to crop, move or remove it.
    private var strip: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(pics.enumerated()), id: \.element.id) { i, pic in
                        Button { withAnimation(.snappy(duration: 0.2)) { showing = i } } label: {
                            Group {
                                if let f = pic.fresh { Image(uiImage: f).resizable().scaledToFill() } else { FeedPhoto(src: pic.url, fill: true) }
                            }
                            .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(i == showing ? Theme.accent : .clear, lineWidth: 2.5).padding(-3.5))
                            .overlay(alignment: .bottomLeading) {
                                Text("\(i + 1)").font(.caption2.weight(.heavy)).monospacedDigit().foregroundStyle(.white)
                                    .frame(width: 18, height: 18).background(.black.opacity(0.6), in: Circle()).padding(3)
                            }
                        }
                        .buttonStyle(.plain).accessibilityLabel("Photo \(i + 1)")
                        .contextMenu {
                            Button { recrop(i) } label: { Label("Crop and edit", systemImage: "crop") }
                            if i > 0 { Button { move(i, to: 0) } label: { Label("Make it first", systemImage: "arrow.left.to.line") } }
                            if i > 0 { Button { move(i, to: i - 1) } label: { Label("Move left", systemImage: "arrow.left") } }
                            if i < pics.count - 1 { Button { move(i, to: i + 1) } label: { Label("Move right", systemImage: "arrow.right") } }
                            if pics.count > 1 { Button(role: .destructive) { drop(i) } label: { Label("Remove", systemImage: "trash") } }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 5)
                .frame(minWidth: UIScreen.main.bounds.width)
            }
            .scrollIndicators(.hidden)
            Text("Hold a photo to move, crop or remove it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func move(_ i: Int, to j: Int) {
        guard pics.indices.contains(i), pics.indices.contains(j) else { return }
        withAnimation(.snappy) { let p = pics.remove(at: i); pics.insert(p, at: j); showing = j; picsChanged = true }
    }
    private func drop(_ i: Int) {
        guard pics.count > 1, pics.indices.contains(i) else { return }
        withAnimation(.snappy) { pics.remove(at: i); showing = min(showing, pics.count - 1); picsChanged = true }
    }

    // MARK: what goes with it

    private var attachment: some View {
        VStack(spacing: 0) {
            if let w = what {
                let k = str(w["kind"]), protein = num(dict(w["macros"])["p"])
                HStack(spacing: 12) {
                    FoodDot(name: k == "workout" ? "Workout" : str(w["name"]), size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(str(w["name"])).font(.body.weight(.semibold)).lineLimit(1)
                        Text(k == "workout" ? "\(Int(num(dict(w["extra"])["minutes"]) ?? 0)) min · \(Fmt.int(num(w["kcal"]) ?? 0)) kcal"
                             : "\(Fmt.int(num(w["kcal"]) ?? 0)) kcal\(protein.map { " · \(Int($0)) g protein" } ?? "")").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button("Change") { shelf = k == "workout" ? 2 : k == "meal" ? 1 : 0; attaching = true }.font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    // a post has to be of something: only one with a picture can go without
                    if isVideo || !pics.isEmpty {
                        Button("Remove") { withAnimation(.snappy) { what = nil; whatChanged = true } }.font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain).padding(.leading, 6)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            } else {
                row("fork.knife", "Add a food or meal") { shelf = 0; attaching = true }
                Divider().padding(.leading, 14)
                row("dumbbell.fill", "Add a workout") { shelf = 2; attaching = true }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var songRow: some View {
        VStack(spacing: 0) {
            if let s = song {
                let on = SongPlayer.shared.playing == "edit:" + s.id
                HStack(spacing: 12) {
                    Button { SongPlayer.shared.toggle(s, key: "edit:" + s.id) } label: {
                        Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(on ? "Stop the song" : "Play the song")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.body.weight(.semibold)).lineLimit(1)
                        Text("Song").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Change") { SongPlayer.shared.stop(); typing = false; choosingSong = true }.font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    Button("Remove") { SongPlayer.shared.stop(); withAnimation(.snappy) { song = nil } }.font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain).padding(.leading, 6)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            } else {
                row("music.note", "Add a song") { typing = false; choosingSong = true }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row(_ symbol: String, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 24)
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: opening and saving

    private func start() {
        guard !opened else { return }   // coming back from the editor mustn't undo what's been changed here
        opened = true
        caption = Feed.shared.caption(post)
        song = Music.of(post)
        if ["food", "meal", "workout"].contains(kind) {
            what = ["kind": kind, "name": post["name"] ?? "", "kcal": post["kcal"] ?? 0, "macros": post["macros"] ?? NSNull(), "payload": post["payload"] ?? [:] as JSON, "extra": dict(post["extra"])]
        }
        if !isVideo && Feed.hasPhoto(post) { pics = PostPhotos.all(post).map { Pic(url: $0) } }
    }

    /// The video, onto the phone: its frames are needed to trim, crop and choose a cover.
    private func fetchVideo() async {
        guard local == nil, let remote = Feed.video(post), let (tmp, _) = try? await URLSession.shared.download(from: remote) else { return }
        let to = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        if (try? FileManager.default.moveItem(at: tmp, to: to)) != nil { local = to }
    }

    /// The numbers and details an attached food, meal or workout puts in a post's extra, as opposed to the picture's.
    private static let attachKeys = ["grams", "unit", "meal", "portions", "minutes"]

    private func save() {
        busy = true; problem = nil
        Task {
            var change: JSON = ["caption": String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))]
            var extra = dict(post["extra"])
            let api = Supabase.shared
            do {
                if isVideo {
                    if let clip, let local {
                        let (mp4, _) = try await Stories.compress(local, filter: clip.look, range: clip.range, muted: clip.muted, crop: clip.crop, overlay: clip.overlay, turns: clip.turns)
                        extra["video"] = try await api.upload(mp4, ext: "mp4", type: "video/mp4")
                    }
                    if let poster, let jpeg = Feed.prepare(poster) {
                        change["photo"] = try await api.uploadPhoto(jpeg)
                        extra["aspect"] = Double(poster.size.width / max(poster.size.height, 1))
                    }
                } else if picsChanged, !pics.isEmpty {
                    var urls: [String] = []
                    for p in pics {
                        if let f = p.fresh, let jpeg = Feed.prepare(f) { urls.append(try await api.uploadPhoto(jpeg)) } else { urls.append(p.url) }
                    }
                    change["photo"] = urls[0]
                    extra["photos"] = urls.count > 1 ? urls : nil
                    if let f = pics[0].fresh { extra["aspect"] = Double(f.size.width / max(f.size.height, 1)) }
                }
            } catch {
                busy = false; problem = "Couldn't save the picture: \(error.localizedDescription)"
                return
            }
            extra["song"] = song.map { ["id": $0.id, "title": $0.title] as JSON }
            if whatChanged {
                for k in Self.attachKeys { extra[k] = nil }
                if let w = what {
                    change["kind"] = w["kind"] ?? "food"; change["name"] = w["name"] ?? ""; change["kcal"] = w["kcal"] ?? 0
                    change["macros"] = w["macros"] ?? NSNull(); change["payload"] = w["payload"] ?? [:] as JSON
                    for (k, v) in dict(w["extra"]) where Self.attachKeys.contains(k) { extra[k] = v }
                } else {
                    change["kind"] = "photo"; change["name"] = ""; change["kcal"] = 0; change["macros"] = [:] as JSON; change["payload"] = [:] as JSON
                }
            }
            change["extra"] = extra
            let ok = await Feed.shared.update(post, change: change)
            busy = false
            if ok { UINotificationFeedbackGenerator().notificationOccurred(.success); dismiss() } else { problem = "Couldn't save that just now. Try again." }
        }
    }
}
