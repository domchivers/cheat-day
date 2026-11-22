import SwiftUI

/// A picture filling whatever room it's given, with nothing of it outside.
struct FillPicture: View {
    let image: CGImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
    }
}

/// The clip's own frame in each of the filters.
struct FilterStrip: View {
    let clip: Clip
    let picked: String
    let pick: (String) -> Void
    @State private var still: CGImage?
    @State private var made: [String: CGImage] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StoryArt.filters, id: \.self) { (name: String) in tile(name) }
            }
        }
        .task(id: "\(clip.source.path)|\(clip.start)|\(clip.end)") { await load() }
    }

    private func tile(_ name: String) -> some View {
        let image: CGImage? = made[name] ?? still
        return ProTile(name: name, on: name == picked, tall: 66, pick: { pick(name) }, preview: { FillPicture(image: image) })
            .frame(width: 58)
    }

    private func load() async {
        guard let picture = await PreviewArt.still(clip, at: PreviewArt.middle(clip)) else { return }
        guard !Task.isCancelled else { return }
        still = picture
        let names: [String] = StoryArt.filters
        let all: [String: CGImage] = await Task.detached(priority: .userInitiated) { () -> [String: CGImage] in
            PreviewArt.looks(picture, names: names)
        }.value
        if !Task.isCancelled { made = all }
    }
}

/// Every transition, playing between the two clips it would join.
struct JoinStrip: View {
    let from: Clip
    let into: Clip
    let picked: String
    let direction: String
    let pick: (String) -> Void
    @State private var frames: [String: [CGImage]] = [:]
    @Environment(\.accessibilityReduceMotion) private var still

    private var source: String {
        "\(from.source.path)|\(from.end)|\(into.source.path)|\(into.start)|\(direction)"
    }

    var body: some View {
        let names: [String] = ["None"] + ClipTransition.kinds
        return TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: still)) { context in
            strip(names, step: step(at: context.date.timeIntervalSinceReferenceDate))
        }
        .frame(height: 85)
        .task(id: source) { await load(names) }
    }

    private func step(at seconds: Double) -> Int {
        let p: Double = still ? 0.5 : PreviewArt.progress(at: seconds)
        return Int((p * Double(PreviewArt.steps - 1)).rounded())
    }

    private func strip(_ names: [String], step: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { (name: String) in tile(name, step: step) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func tile(_ name: String, step: Int) -> some View {
        let all: [CGImage] = frames[name] ?? []
        let image: CGImage? = all.isEmpty ? nil : all[min(step, all.count - 1)]
        return ProTile(name: name, on: name == picked, tall: 66, pick: { pick(name) }, preview: { FillPicture(image: image) })
            .frame(width: 62)
    }

    private func load(_ names: [String]) async {
        guard let a = await PreviewArt.still(from, at: max(from.start, from.end - 0.15)) else { return }
        guard let b = await PreviewArt.still(into, at: min(into.end, into.start + 0.15)) else { return }
        let way: String = direction
        // (one kind at a time: each shows as it's ready)
        for name in names {
            guard !Task.isCancelled else { return }
            let made: [CGImage] = await Task.detached(priority: .userInitiated) { () -> [CGImage] in
                PreviewArt.join(a, b, kind: name, direction: way)
            }.value
            if !Task.isCancelled { frames[name] = made }
        }
    }
}

/// One of Motion's moves, playing on the clip itself.
struct MoveChoice: Identifiable {
    var id: String
    var icon: String
    var keys: [MoveKey]
}

struct MotionStrip: View {
    let clip: Clip
    let choices: [MoveChoice]
    let pick: (MoveChoice) -> Void
    @State private var picture: CGImage?
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: still)) { context in
            tiles(progress: still ? 0.5 : PreviewArt.progress(at: context.date.timeIntervalSinceReferenceDate, length: 1.8, rest: 0.4))
        }
        .frame(height: 85)
        .task(id: "\(clip.source.path)|\(clip.start)|\(clip.end)") {
            let made: CGImage? = await PreviewArt.still(clip, at: PreviewArt.middle(clip))
            if !Task.isCancelled { picture = made }
        }
    }

    private func tiles(progress: Double) -> some View {
        HStack(spacing: 8) {
            ForEach(choices) { (choice: MoveChoice) in tile(choice, progress: progress) }
        }
    }

    private func tile(_ choice: MoveChoice, progress: Double) -> some View {
        let at: Double = clip.span * progress
        let m: MoveKey = MoveKey.value(choice.keys, at: at, base: MoveKey(at: 0))
        return ProTile(name: choice.id, on: clip.moves == choice.keys, tall: 66, pick: { pick(choice) }, preview: {
            moved(m).overlay(alignment: .topTrailing) { way(choice.icon) }
        })
    }

    private func moved(_ m: MoveKey) -> some View {
        GeometryReader { g in
            FillPicture(image: picture)
                .scaleEffect(CGFloat(m.size))
                .offset(x: CGFloat(m.x - 0.5) * g.size.width, y: CGFloat(m.y - 0.5) * g.size.height)
        }
        .clipped()
    }

    private func way(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 9, weight: .bold))
            .frame(width: 18, height: 18)
            .background(Color.black.opacity(0.6), in: Circle())
            .padding(4)
    }
}

/// The shapes, or what's behind a clip of another shape, on the edit's own frame.
struct ShapeStrip: View {
    let clip: Clip?
    let background: Bool
    let picked: String
    let pick: (String) -> Void
    @State private var picture: CGImage?

    var body: some View {
        let options: [String] = background ? EditLook.fills : EditLook.shapes
        return HStack(spacing: 8) {
            ForEach(options, id: \.self) { (option: String) in tile(option) }
        }
        .task(id: "\(clip?.source.path ?? "")|\(clip?.start ?? 0)") {
            guard let clip else { return }
            let made: CGImage? = await PreviewArt.still(clip, at: PreviewArt.middle(clip))
            if !Task.isCancelled { picture = made }
        }
    }

    private func tile(_ option: String) -> some View {
        ProTile(name: Self.name(option), on: option == picked, pick: { pick(option) }, preview: { preview(option) })
    }

    @ViewBuilder private func preview(_ option: String) -> some View {
        if background { behind(option) } else { cut(option) }
    }

    private func cut(_ shape: String) -> some View {
        let size: CGSize = Self.size(shape, own: ownShape)
        return FillPicture(image: picture)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private var ownShape: CGFloat {
        guard let picture, picture.height > 0 else { return 9.0 / 16.0 }
        return CGFloat(picture.width) / CGFloat(picture.height)
    }

    /// A shape drawn inside a tile: no taller than 52, no wider than 64.
    static func size(_ shape: String, own: CGFloat) -> CGSize {
        let ratio: CGFloat
        switch shape {
        case "9:16": ratio = 9.0 / 16.0
        case "4:5": ratio = 0.8
        case "1:1": ratio = 1
        default: ratio = max(0.1, own)
        }
        let h: CGFloat = min(52, 64 / ratio)
        return CGSize(width: h * ratio, height: h)
    }

    private func behind(_ fill: String) -> some View {
        ZStack {
            switch fill {
            case "Fill":
                FillPicture(image: picture)
            case "Blur":
                FillPicture(image: picture).blur(radius: 6).overlay(Color.black.opacity(0.28))
                whole
            default:
                Color.black
                whole
            }
        }
        .clipped()
    }

    @ViewBuilder private var whole: some View {
        if let picture { Image(decorative: picture, scale: 1).resizable().scaledToFit() }
    }

    static func name(_ option: String) -> String {
        switch option {
        case "Original": return "First clip's"
        case "Fill": return "Fill the frame"
        case "Blur": return "Blurred behind"
        case "Black": return "On black"
        default: return option
        }
    }
}
