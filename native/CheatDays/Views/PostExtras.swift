import AVFoundation
import SwiftUI

/// What the editor did to a post's clip.
struct ClipEdit {
    var look = "Normal"
    var range: ClosedRange<Double>? = nil
    var muted = false
    /// The part of the picture kept, as fractions from its top left; nil for all of it.
    var crop: CGRect? = nil
    var shape: CGFloat? = nil
    /// Text, stickers and drawing as one see-through picture in the frame's shape, laid over every frame.
    var overlay: UIImage? = nil
    /// The moment shown before it plays; nil for where it starts.
    var cover: Double? = nil
    /// Quarter turns to the right.
    var turns = 0
    /// Turned freely by two fingers, in degrees to the right. When it is, the part kept isn't a plain rectangle of
    /// the picture, so in place of `crop` there's how big it was made and where it was carried to (as fractions of
    /// the frame), and the frame's corners may show the dark behind.
    var spin: Double = 0
    var zoom: CGFloat = 1
    var move: CGSize = .zero
    /// The clip doesn't cover its frame (turned, made smaller, or carried off to one side): it's laid on black
    /// by `spin`, `zoom` and `move`, not cut from the picture by `crop`.
    var loose = false
    /// The editor as it was left, to open it again the same: going back into the editor after Next started it from
    /// nothing (no filter, no text, the whole clip), and Next again then threw away what had been done before.
    var kept: Kept? = nil
    struct Kept {
        var filter: String
        var tune: [String: Double]
        var items: [JSON]
        var strokes: [JSON]
        var range: ClosedRange<Double>?
        var scale: CGFloat
        var offset: CGSize
        var covers: Bool
    }

    /// A frame of the clip as friends will see it: through the look, cut to the part kept, with what's on it.
    func still(_ url: URL, at seconds: Double? = nil, width: CGFloat = 1440) async -> UIImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: width, height: width)
        // near enough to the moment asked for: the nearest key frame could be seconds away
        let near = CMTime(seconds: 0.08, preferredTimescale: 600)
        g.requestedTimeToleranceBefore = near; g.requestedTimeToleranceAfter = near
        let t = seconds ?? cover ?? range?.lowerBound ?? 0
        guard let (cg, _) = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { return nil }
        let frame = UIImage(cgImage: cg), edit = self
        return await Task.detached(priority: .userInitiated) { edit.dress(frame) }.value
    }

    func dress(_ frame: UIImage) -> UIImage {
        let lit = StoryArt.filtered((0..<(((turns % 4) + 4) % 4)).reduce(frame) { img, _ in img.quarterTurned() }, look)
        if loose {
            let w = lit.size.width, h = lit.size.height, own = w / max(h, 1), sh = shape ?? own
            let fw = sh > own ? w : h * sh, fh = fw / sh
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: fw.rounded(), height: fh.rounded()), format: format).image { c in
                UIColor.black.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: fw, height: fh))
                c.cgContext.saveGState()
                c.cgContext.translateBy(x: fw / 2 + move.width * fw, y: fh / 2 + move.height * fh)
                c.cgContext.rotate(by: CGFloat(spin) * .pi / 180)
                lit.draw(in: CGRect(x: -w * zoom / 2, y: -h * zoom / 2, width: w * zoom, height: h * zoom))
                c.cgContext.restoreGState()
                overlay?.draw(in: CGRect(x: 0, y: 0, width: fw.rounded(), height: fh.rounded()))
            }
        }
        guard let cg = lit.cgImage else { return lit }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), c = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let cut = CGRect(x: c.minX * w, y: c.minY * h, width: c.width * w, height: c.height * h).integral
        guard let piece = cg.cropping(to: cut) else { return lit }
        let size = CGSize(width: piece.width, height: piece.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: piece).draw(in: CGRect(origin: .zero, size: size))
            overlay?.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

extension UIImage {
    /// The picture turned a quarter to the right.
    func quarterTurned() -> UIImage {
        let old = size, new = CGSize(width: old.height, height: old.width)
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        return UIGraphicsImageRenderer(size: new, format: format).image { c in
            c.cgContext.translateBy(x: new.width / 2, y: new.height / 2)
            c.cgContext.rotate(by: .pi / 2)
            draw(in: CGRect(x: -old.width / 2, y: -old.height / 2, width: old.width, height: old.height))
        }
    }
}

/// Choosing the frame of a video that shows before it plays: on the feed, and on the profile's grid. The big
/// picture is that frame exactly as it will be posted; a finger along the strip under it moves through the clip.
struct CoverPicker: View {
    let url: URL
    let edit: ClipEdit
    var done: (Double, UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var at: Double
    @State private var shown: UIImage?
    @State private var frames: [UIImage] = []
    @State private var span: ClosedRange<Double>
    @State private var own: CGFloat?   // the clip's own shape, the way up it's been turned
    @State private var finishing = false

    init(url: URL, edit: ClipEdit, start: UIImage?, done: @escaping (Double, UIImage?) -> Void) {
        self.url = url; self.edit = edit; self.done = done
        let from = edit.range?.lowerBound ?? 0
        _at = State(initialValue: edit.cover ?? from)
        _shown = State(initialValue: start)
        _span = State(initialValue: edit.range ?? from...(from + 1))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The clip itself, stopped on the moment under the finger, in its frame as it was placed there, with
                // what's written on it over the top. A player goes to a moment in a blink; making a finished still for
                // every move of the finger (as this did) took long enough to feel like wading. The finished still
                // is made once, on Done.
                GeometryReader { g in
                    if let own {
                        let shape = edit.shape ?? own
                        let cw = min(g.size.width, g.size.height * shape), ch = cw / shape
                        let fill = own > shape ? CGSize(width: ch * own, height: ch) : CGSize(width: cw, height: cw / own)
                        let odd = edit.turns % 2 != 0
                        ZStack {
                            Color.black
                            LoopingVideo(url: url, paused: true, muted: true, filter: edit.look, scrub: at)
                                .frame(width: odd ? fill.height : fill.width, height: odd ? fill.width : fill.height)
                                .rotationEffect(.degrees(Double(edit.turns) * 90))
                                .frame(width: fill.width, height: fill.height)
                                .scaleEffect(edit.zoom)
                                .rotationEffect(.degrees(edit.spin))
                                .offset(x: edit.move.width * cw, y: edit.move.height * ch)
                                .allowsHitTesting(false)
                            if let top = edit.overlay { Image(uiImage: top).resizable().frame(width: cw, height: ch).allowsHitTesting(false) }
                        }
                        .frame(width: cw, height: ch).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                    } else if let shown {
                        Image(uiImage: shown).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .position(x: g.size.width / 2, y: g.size.height / 2)
                    } else { ProgressView().position(x: g.size.width / 2, y: g.size.height / 2) }
                }
                .padding(.horizontal, 28).padding(.vertical, 18)
                VStack(spacing: 12) {
                    Text(clock(at - span.lowerBound)).font(.footnote.weight(.bold)).monospacedDigit().foregroundStyle(.secondary)
                    strip.frame(height: 60).padding(.horizontal, 22)
                    Text("Slide to choose what people see before it plays.").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.bottom, 22)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Cover").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if finishing { ProgressView() } else {
                        Button("Done") {
                            finishing = true
                            Task {
                                let still = await edit.still(url, at: at)   // the one finished picture, as it will be posted
                                done(at, still ?? shown)
                                dismiss()
                            }
                        }
                        .fontWeight(.bold)
                    }
                }
            }
            .task { await load() }
        }
        .presentationBackground(Theme.bg)
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%04.1f", Int(max(0, s)) / 60, max(0, s).truncatingRemainder(dividingBy: 60)) }

    private var strip: some View {
        GeometryReader { g in
            let w = g.size.width, box: CGFloat = 44
            let frac = span.upperBound > span.lowerBound ? CGFloat((at - span.lowerBound) / (span.upperBound - span.lowerBound)) : 0
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(uiImage: frames[i]).resizable().scaledToFill().frame(width: w / CGFloat(max(1, frames.count)), height: 52).clipped()
                    }
                }
                .frame(width: w, height: 52).background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).opacity(0.75)
                RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white, lineWidth: 3)
                    .frame(width: box, height: 60).shadow(color: .black.opacity(0.4), radius: 4)
                    .offset(x: frac * (w - box))
            }
            .frame(height: 60)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = Double(min(1, max(0, (v.location.x - box / 2) / max(1, w - box))))
                at = span.lowerBound + f * (span.upperBound - span.lowerBound)
            })
            .accessibilityLabel("Cover frame")
        }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        let length = (try? await asset.load(.duration).seconds) ?? 0
        let from = edit.range?.lowerBound ?? 0, to = min(edit.range?.upperBound ?? length, from + 30, max(length, from + 0.1))
        span = from...max(from + 0.1, to - 0.05)
        at = min(span.upperBound, max(span.lowerBound, at))
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            let n = (try? await track.load(.naturalSize)) ?? .zero, t = (try? await track.load(.preferredTransform)) ?? .identity
            let r = CGRect(origin: .zero, size: n).applying(t)
            if abs(r.width) > 1, abs(r.height) > 1 {
                let a = abs(r.width) / abs(r.height)
                own = edit.turns % 2 != 0 ? 1 / a : a
            }
        }
        var got: [UIImage] = []
        for i in 0..<9 {
            if let f = await edit.still(url, at: span.lowerBound + (span.upperBound - span.lowerBound) * Double(i) / 8, width: 200) { got.append(f); frames = got }
        }
    }
}

/// A post's photos on the feed: one fills its frame; several are swiped across, with which one it is in the corner
/// and dots along the bottom.
struct PostPhotos: View {
    let post: JSON
    @State private var page = 0

    static func all(_ p: JSON) -> [String] {
        let many = dict(p["extra"])["photos"] as? [String] ?? []
        return many.count > 1 ? many : [str(p["photo"])]
    }

    var body: some View {
        let urls = Self.all(post)
        if urls.count < 2 { FeedPhoto(src: urls.first ?? "", fill: true) }
        else {
            TabView(selection: $page) {
                ForEach(urls.indices, id: \.self) { i in
                    Color.clear.overlay { FeedPhoto(src: urls[i], fill: true) }.clipped().tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .topTrailing) {
                Text("\(page + 1)/\(urls.count)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule()).padding(12)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 5) {
                    ForEach(urls.indices, id: \.self) { i in
                        Circle().fill(.white.opacity(i == page ? 1 : 0.45)).frame(width: i == page ? 7 : 6, height: i == page ? 7 : 6)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6).background(.black.opacity(0.35), in: Capsule()).padding(.bottom, 10)
                .animation(.snappy(duration: 0.2), value: page)
            }
        }
    }
}

/// Posts started and kept to finish later: each a folder on this phone with its photos or video, and a note of the
/// caption, what's attached, the song and how the video was edited. They never leave the phone.
enum Drafts {
    private static var root: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    /// Newest first.
    static func all() -> [JSON] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap { id -> JSON? in
            guard !id.hasPrefix("tmp-"), let d = try? Data(contentsOf: folder(id).appendingPathComponent("draft.json")) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? JSON
        }
        .sorted { str($0["saved"]) > str($1["saved"]) }
    }

    static func thumb(_ d: JSON) -> UIImage? { UIImage(contentsOfFile: folder(str(d["id"])).appendingPathComponent("thumb.jpg").path) }

    static func delete(_ id: String) { if !id.isEmpty { try? FileManager.default.removeItem(at: folder(id)) } }

    /// Written beside the old one and swapped in, so a draft saved again is never half there.
    static func save(_ id: String, meta: JSON, shots: [(UIImage, UIImage)], movie: URL?, clip: ClipEdit, poster: UIImage?) {
        let fm = FileManager.default, tmp = root.appendingPathComponent("tmp-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        var m = meta
        m["id"] = id; m["saved"] = ISO8601DateFormatter().string(from: Date()); m["shots"] = shots.count
        for (i, s) in shots.enumerated() {
            try? s.0.jpegData(compressionQuality: 0.9)?.write(to: tmp.appendingPathComponent("s\(i).jpg"))
            try? s.1.jpegData(compressionQuality: 0.9)?.write(to: tmp.appendingPathComponent("o\(i).jpg"))
        }
        if let movie {
            let name = "movie." + (movie.pathExtension.isEmpty ? "mov" : movie.pathExtension)
            try? fm.copyItem(at: movie, to: tmp.appendingPathComponent(name))
            var c: JSON = ["look": clip.look, "muted": clip.muted]
            if let r = clip.range { c["lo"] = r.lowerBound; c["hi"] = r.upperBound }
            if let k = clip.crop { c["crop"] = [Double(k.minX), Double(k.minY), Double(k.width), Double(k.height)] }
            if let s = clip.shape { c["shape"] = Double(s) }
            if let t = clip.cover { c["cover"] = t }
            c["turns"] = clip.turns
            if clip.loose { c["spin"] = clip.spin; c["zoom"] = Double(clip.zoom); c["move"] = [Double(clip.move.width), Double(clip.move.height)] }
            m["movie"] = name; m["clip"] = c
            try? clip.overlay?.pngData()?.write(to: tmp.appendingPathComponent("overlay.png"))
            try? poster?.jpegData(compressionQuality: 0.9)?.write(to: tmp.appendingPathComponent("poster.jpg"))
        }
        if let face = movie != nil ? poster : shots.first?.1 {
            let k = 200 / max(1, max(face.size.width, face.size.height))
            let small = face.preparingThumbnail(of: CGSize(width: face.size.width * k, height: face.size.height * k)) ?? face
            try? small.jpegData(compressionQuality: 0.8)?.write(to: tmp.appendingPathComponent("thumb.jpg"))
        }
        if !JSONSerialization.isValidJSONObject(m) { m["what"] = nil }
        guard JSONSerialization.isValidJSONObject(m), let d = try? JSONSerialization.data(withJSONObject: m) else { try? fm.removeItem(at: tmp); return }
        try? d.write(to: tmp.appendingPathComponent("draft.json"))
        try? fm.removeItem(at: folder(id))
        try? fm.moveItem(at: tmp, to: folder(id))
    }

    static func load(_ d: JSON) -> (shots: [(UIImage, UIImage)], movie: URL?, clip: ClipEdit, poster: UIImage?) {
        let dir = folder(str(d["id"]))
        func pic(_ name: String) -> UIImage? { UIImage(contentsOfFile: dir.appendingPathComponent(name).path) }
        var shots: [(UIImage, UIImage)] = []
        for i in 0..<Int(num(d["shots"]) ?? 0) { if let o = pic("o\(i).jpg") { shots.append((pic("s\(i).jpg") ?? o, o)) } }
        var clip = ClipEdit(), movie: URL?
        let name = str(d["movie"])
        if !name.isEmpty, FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            movie = dir.appendingPathComponent(name)
            let c = dict(d["clip"])
            clip.look = str(c["look"]).isEmpty ? "Normal" : str(c["look"])
            clip.muted = c["muted"] as? Bool ?? false
            if let lo = num(c["lo"]), let hi = num(c["hi"]), hi > lo { clip.range = lo...hi }
            if let k = c["crop"] as? [Double], k.count == 4 { clip.crop = CGRect(x: k[0], y: k[1], width: k[2], height: k[3]) }
            clip.shape = num(c["shape"]).map { CGFloat($0) }
            clip.cover = num(c["cover"])
            clip.turns = Int(num(c["turns"]) ?? 0)
            if let sp = num(c["spin"]), let m = c["move"] as? [Double], m.count == 2 {
                clip.loose = true; clip.spin = sp; clip.zoom = CGFloat(num(c["zoom"]) ?? 1); clip.move = CGSize(width: m[0], height: m[1])
            }
            clip.overlay = pic("overlay.png")
        }
        return (shots, movie, clip, movie == nil ? nil : pic("poster.jpg"))
    }

    /// A draft's video on its way to being posted: moved out of the draft's folder, which is about to go.
    static func release(_ movie: URL) -> URL {
        guard movie.path.hasPrefix(root.path) else { return movie }
        let to = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + movie.pathExtension)
        return (try? FileManager.default.copyItem(at: movie, to: to)) != nil ? to : movie
    }

    static func when(_ d: JSON) -> String {
        guard let date = ISO8601DateFormatter().date(from: str(d["saved"])) else { return "Saved" }
        if Calendar.current.isDateInToday(date) { return "Saved today" }
        if Calendar.current.isDateInYesterday(date) { return "Saved yesterday" }
        return "Saved " + date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Who's in a post: your friends, to tick. They're named on the post and it shows under Tagged on their profile.
struct TagPicker: View {
    @Binding var picked: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    static func names(_ ids: [String]) -> String {
        let n = ids.map { Feed.shared.name($0) }.filter { !$0.isEmpty }
        switch n.count {
        case 0: return ""
        case 1: return n[0]
        case 2: return "\(n[0]) and \(n[1])"
        default: return "\(n[0]), \(n[1]) and \(n.count - 2) more"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                let people = Friends.shared.people.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                if Friends.shared.people.isEmpty {
                    Text("Add a friend and you can tag them in your posts.").foregroundStyle(.secondary)
                } else if people.isEmpty {
                    Text("No friend called that.").foregroundStyle(.secondary)
                }
                ForEach(people) { f in
                    let on = picked.contains(f.id)
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        if on { picked.removeAll { $0 == f.id } } else if picked.count < 20 { picked.append(f.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(id: f.id, size: 38)
                            Text(f.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(on ? Theme.accent : Color(.tertiaryLabel))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")
            .navigationTitle("Tag people").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.bold) } }
        }
    }
}

/// How loud a post's song is, and (on a video that has sound) how loud the video's own sound is against it: the two
/// are heard together, and these set one against the other. A song that's playing follows its slider as it moves.
struct MixSliders: View {
    @Binding var song: Double
    @Binding var clip: Double
    let hasClip: Bool

    var body: some View {
        VStack(spacing: 4) {
            row("music.note", "Song", $song)
            if hasClip { row("video.fill", "Video", $clip) }
        }
        .onChange(of: song) { _, v in SongPlayer.shared.volume(Float(v)) }
    }

    private func row(_ symbol: String, _ name: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Slider(value: value, in: 0...1).tint(Theme.accent).accessibilityLabel(name + " volume")
            Text("\(Int((value.wrappedValue * 100).rounded()))%").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }
}

/// A post's clip playing in its frame as it was placed there in the editor (its shape, size, turn and position, and
/// what's written on it over the top): for hearing it on the write-up screen without it jumping to another framing.
struct PlacedClip: View {
    let url: URL
    let edit: ClipEdit
    var volume: Float = 1
    @State private var own: CGFloat?   // the clip's own shape, the way up it's been turned

    var body: some View {
        GeometryReader { g in
            if let own {
                let shape = edit.shape ?? own
                let cw = min(g.size.width, g.size.height * shape), ch = cw / shape
                let fill = own > shape ? CGSize(width: ch * own, height: ch) : CGSize(width: cw, height: cw / own)
                let odd = edit.turns % 2 != 0
                ZStack {
                    Color.black
                    LoopingVideo(url: url, muted: edit.muted, filter: edit.look, range: edit.range, volume: volume)
                        .frame(width: odd ? fill.height : fill.width, height: odd ? fill.width : fill.height)
                        .rotationEffect(.degrees(Double(edit.turns) * 90))
                        .frame(width: fill.width, height: fill.height)
                        .scaleEffect(edit.zoom)
                        .rotationEffect(.degrees(edit.spin))
                        .offset(x: edit.move.width * cw, y: edit.move.height * ch)
                    if let top = edit.overlay { Image(uiImage: top).resizable().frame(width: cw, height: ch) }
                }
                .frame(width: cw, height: ch).clipped()
                .position(x: g.size.width / 2, y: g.size.height / 2)
                .allowsHitTesting(false)
            }
        }
        .task {
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return }
            let n = (try? await track.load(.naturalSize)) ?? .zero, t = (try? await track.load(.preferredTransform)) ?? .identity
            let r = CGRect(origin: .zero, size: n).applying(t)
            guard abs(r.width) > 1, abs(r.height) > 1 else { return }
            let a = abs(r.width) / abs(r.height)
            own = edit.turns % 2 != 0 ? 1 / a : a
        }
    }
}

/// A post's picture in the feed, pinched bigger: it grows from between the fingers and goes where they go, over
/// whatever's around it, and springs back when they lift. Nothing stays zoomed. `held` is the post being pinched,
/// for the feed to lift its row above the others and hold the list still meanwhile.
struct PinchToZoom: ViewModifier {
    let id: String
    @Binding var held: String?
    var on = true
    @State private var scale: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var anchor = UnitPoint.center
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        if !on { content } else {
            let shown = content
                .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
                .scaleEffect(scale, anchor: anchor)
                .offset(pan)
                .zIndex(held == id ? 5 : 0)
            if #available(iOS 18.0, *) {
                shown.gesture(PinchFollow(began: { at in
                    anchor = UnitPoint(x: at.x / max(1, size.width), y: at.y / max(1, size.height)); held = id
                }, changed: { s, move in scale = min(5, max(1, s)); pan = move }, ended: end))
            } else {
                // before iOS 18 a pinch can't be followed as it moves: it grows where it was pinched, and stays put
                shown.simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        if held != id { anchor = v.startAnchor; held = id }
                        scale = min(5, max(1, v.magnification))
                    }
                    .onEnded { _ in end() })
            }
        }
    }

    private func end() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { scale = 1; pan = .zero }
        // it stays above its neighbours until it's back in its place
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { if scale == 1, held == id { held = nil } }
    }
}

/// A pinch with where it is as well as how big: the point between the fingers moves with them.
@available(iOS 18.0, *)
struct PinchFollow: UIGestureRecognizerRepresentable {
    /// Begun, here in the view's own points.
    var began: (CGPoint) -> Void
    /// This many times the size, and carried this far since it began.
    var changed: (CGFloat, CGSize) -> Void
    var ended: () -> Void

    final class Coordinator { var start = CGPoint.zero }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer { UIPinchGestureRecognizer() }
    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        let here = context.converter.location(in: .global)
        switch recognizer.state {
        case .began:
            context.coordinator.start = here
            began(context.converter.localLocation)
        case .changed:
            // with one finger lifted the point between them jumps to the one that's left: not followed
            guard recognizer.numberOfTouches >= 2 else { return }
            changed(recognizer.scale, CGSize(width: here.x - context.coordinator.start.x, height: here.y - context.coordinator.start.y))
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }
}

/// A song's cover. The songs have no pictures of their own (public-domain clips), so each gets one made for it: its
/// mood's colours, tilted its own way by its name, always the same for the same song.
struct SongCover: View {
    let song: Song
    var size: CGFloat = 64

    private var colours: [Color] {
        switch song.mood {
        case "Gym": return [Color(red: 0.98, green: 0.30, blue: 0.32), Color(red: 0.55, green: 0.18, blue: 0.75)]
        case "Epic": return [Color(red: 0.36, green: 0.32, blue: 0.92), Color(red: 0.10, green: 0.62, blue: 0.95)]
        case "Chill": return [Color(red: 0.12, green: 0.72, blue: 0.70), Color(red: 0.20, green: 0.42, blue: 0.90)]
        case "Funny": return [Color(red: 0.99, green: 0.76, blue: 0.20), Color(red: 0.30, green: 0.78, blue: 0.42)]
        default: return [Color(red: 1.0, green: 0.58, blue: 0.22), Color(red: 0.96, green: 0.30, blue: 0.55)]
        }
    }
    private var seed: Int { song.id.utf8.reduce(7) { ($0 &* 31 &+ Int($1)) % 9973 } }

    var body: some View {
        let turn = Double(seed % 360)
        ZStack {
            LinearGradient(colors: colours, startPoint: UnitPoint(x: 0.5 + 0.5 * cos(turn * .pi / 180), y: 0.5 + 0.5 * sin(turn * .pi / 180)),
                           endPoint: UnitPoint(x: 0.5 - 0.5 * cos(turn * .pi / 180), y: 0.5 - 0.5 * sin(turn * .pi / 180)))
            Circle().fill(.white.opacity(0.16)).frame(width: size * 0.9).offset(x: size * (0.3 - Double(seed % 7) * 0.1), y: size * 0.35)
            Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The song on a video, shown when its name is tapped: its cover and name, and its sound on or off. The video
/// carries on behind (tapping the name used to switch the song off, and the video seemed to stop with it).
struct SongCard: View {
    let song: Song
    /// The viewer's own sound switch: the video's sound and the song's together.
    @Binding var muted: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                SongCover(song: song, size: 68)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.title3.weight(.bold)).lineLimit(2)
                    Text(song.mood.isEmpty ? "Song" : song.mood + " · song").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button { muted.toggle() } label: {
                    Label(muted ? "Turn sound on" : "Turn sound off", systemImage: muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).frame(height: 46)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                Button { dismiss() } label: {
                    Text("Done").font(.subheadline.weight(.bold)).foregroundStyle(Theme.onAccent).frame(width: 96, height: 46).background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
    }
}

/// The heart that a double tap puts on a post: it springs up a little too big and settles, tilted its own way each
/// time, with small hearts thrown out round it, then lifts away and fades. (It was a plain white heart that grew
/// and went.)
struct HeartBurst: View {
    @State private var pop = false
    @State private var away = false
    @State private var tilt = Double.random(in: -14...14)
    static let fill = LinearGradient(colors: [Color(red: 1, green: 0.47, blue: 0.56), Color(red: 0.98, green: 0.16, blue: 0.34)], startPoint: .top, endPoint: .bottom)

    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let a = Double(i) / 7 * 2 * Double.pi + tilt * 0.05
                Image(systemName: "heart.fill").font(.system(size: i % 2 == 0 ? 20 : 14))
                    .foregroundStyle(Self.fill)
                    .scaleEffect(pop ? 1 : 0.2)
                    .offset(x: pop ? cos(a) * 94 : 0, y: pop ? sin(a) * 94 : 0)
                    .opacity(pop && !away ? 0.95 : 0)
                    .animation(.easeOut(duration: 0.5).delay(0.06), value: pop)
            }
            Image(systemName: "heart.fill").font(.system(size: 104))
                .foregroundStyle(Self.fill)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
                .rotationEffect(.degrees(tilt))
                .scaleEffect(pop ? 1 : 0.2)
                .offset(y: away ? -48 : 0)
                .opacity(away ? 0 : 1)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onAppear {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { pop = true }
            withAnimation(.easeIn(duration: 0.3).delay(0.6)) { away = true }
        }
    }
}
