import AVFoundation
import Speech
import SwiftUI

/// Something shown over an edit for part of it (Stage B, 20 Nov; design/editor-all-tools-mockup.html, 1 and 5): text, a
/// sticker, a caption of what's said, a recipe step, a recipe's macros, an exercise with its sets, or a meal's calories
/// counting up. Each is a bar on the timeline: when it shows and when it goes.
struct EditText: Identifiable, Codable, Equatable {
    var id = UUID()
    /// "text", "sticker", "caption", "step", "macros", "workout", "calories"
    var kind: String
    var text: String
    var detail = ""             // a second line: an exercise's sets, the protein under the calories, a recipe's macros
    var style = "Shadow"        // text: Shadow, Box, Plain; captions: Pop, Box, Plain
    var colour = "white"
    var x = 0.5, y = 0.5        // its middle, as fractions of the frame from the top left
    var size = 1.0
    var from: Double
    var to: Double
    var words: [Word]? = nil    // a caption's words, each when it's said
    var number = 0.0            // the calories counted up to
    /// A caption's lit word's colour, its own (design/captions-editing-mockup.html); nil, yellow.
    var highlight: String? = nil
    /// A text's typeface (design/editor-text-stickers-mockup.html): "classic" (nil), "rounded", "serif", "mono", "marker".
    var font: String? = nil
    /// A story sticker on the video (kind "card"): the sticker as stories keep it, as JSON (StoryItem draws it).
    var card: String? = nil
    /// What made it, when it's one of a set made again together: "recipe" (the recipe panel's).
    var part: String? = nil
    /// The timeline row it's on, chosen by holding and dragging it there (design/capcut-timeline-mockup.html); nil:
    /// put in a row of its own kind. The higher row (lower number) is drawn on top.
    var lane: Int? = nil
    /// A caption switched off by its row's eye, or by a voiceover captioned over it: not drawn, not in the video.
    var hidden: Bool? = nil
    /// The voiceover that switched it off, to switch it on again when that's taken off.
    var under: UUID? = nil
    /// The voiceover it captions (CaptionLayers); nil, the video's own talking.
    var voice: UUID? = nil
    // a caption's colours and opacities (design/caption-colour-mockup.html; nil, as before: white words, the
    // highlight whole, a black box at 70%)
    var wordColour: String? = nil
    var wordAlpha: Double? = nil
    var litAlpha: Double? = nil
    var boxColour: String? = nil
    var boxAlpha: Double? = nil
    /// A text's colour's opacity; nil, whole.
    var colourAlpha: Double? = nil
    /// A caption of the video's own put where it is by hand: not lifted over a voiceover's.
    var byHand: Bool? = nil

    /// A word said, and when in the video; and where it was said, so it goes where that goes (21 Nov: a clip trimmed
    /// or moved left its captions behind): the clip (or voiceover) it's in, that file's name, and the moment in it.
    struct Word: Codable, Equatable {
        var text: String
        var at: Double
        var clip: UUID? = nil      // the clip, or the voiceover, it was said in
        var file: String? = nil    // that clip's file's name: a clip split in two keeps its words in either half
        var src: Double? = nil     // the moment in that file (or recording)
    }

    static let textStyles = ["Shadow", "Box", "Outline", "Plain"]
    static let fonts = ["classic", "rounded", "serif", "mono", "marker", "anton", "bebas", "poster", "comic", "brush", "retro", "hand",
                        "fashion", "groovy", "pixel", "neon", "script"]
    /// The fonts built into the app (23 Nov, design/more-fonts-mockup.html; free, under the SIL Open Font Licence, whose
    /// copies are with them in Fonts/): each one's PostScript name, and its size against the others' (a pixel font's
    /// letters are far wider, a condensed one's narrower).
    private static let bundled: [String: (name: String, scale: CGFloat)] = [
        "anton": ("Anton-Regular", 1.1), "bebas": ("BebasNeue-Regular", 1.2), "poster": ("ArchivoBlack-Regular", 0.95),
        "comic": ("Bangers-Regular", 1.1), "brush": ("Pacifico-Regular", 0.9), "retro": ("Lobster-Regular", 1.0),
        "hand": ("CaveatBrush-Regular", 1.15), "fashion": ("AbrilFatface-Regular", 1.0), "groovy": ("Righteous-Regular", 1.0),
        "pixel": ("PressStart2P-Regular", 0.6), "neon": ("Monoton-Regular", 0.8), "script": ("DancingScript-Regular", 1.1),
    ]
    /// The text colours (21 Nov: five were too few), as hex; any other is picked with the wheel.
    static let palette = ["#FFFFFF", "#000000", "#FFD60A", "#FF9F0A", "#FF453A", "#FF375F", "#BF5AF2", "#5E5CE6", "#0A84FF",
                          "#64D2FF", "#30D158", "#A2845E", "#FFB3C7", "#B5F2C8", "#C9B8FF", "#FFE5A0", "#8E8E93", "#3A3A3C"]

    /// The typeface at `size`, heavy as text on a video wants it.
    static func font(_ id: String?, size: CGFloat) -> Font {
        // (fixed: the video's text mustn't grow with the phone's text size)
        if let id, let b = bundled[id] {
            let f: Font = .custom(b.name, fixedSize: size * b.scale)
            return id == "script" ? f.weight(.bold) : f
        }
        switch id {
        case "rounded": return .system(size: size, weight: .heavy, design: .rounded)
        case "serif": return .system(size: size, weight: .bold, design: .serif)
        case "mono": return .system(size: size, weight: .bold, design: .monospaced)
        case "marker": return .custom("MarkerFelt-Wide", size: size)
        default: return .system(size: size, weight: .heavy)
        }
    }

    /// Text on a colour: dark on light ones, white on dark.
    static func ink(on name: String) -> Color {
        if name.hasPrefix("#") { return StoryArt.onColor(String(name.dropFirst())) }
        return name == "white" || name == "yellow" ? .black : .white
    }

    /// The sticker, as stories keep it.
    var cardJSON: JSON? { card.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON } }
    static let captionStyles = ["Pop", "Bold", "Box", "Plain"]
    static let highlights = ["yellow", "green", "red", "blue", "white", "none"]
    /// How much a caption holds: a word, a few, a line's worth, a sentence (the panel's "On screen at a time").
    static let captionGroups: [(id: String, name: String)] = [("word", "1 word"), ("few", "A few words"), ("line", "A line"), ("sentence", "A sentence")]
    /// The lit word's colour.
    var lit: Color { EditText.colour(highlight ?? "yellow").opacity(litAlpha ?? 1) }
    var saidInk: Color { EditText.colour(wordColour ?? "white").opacity(wordAlpha ?? 1) }
    var boxInk: Color { EditText.colour(boxColour ?? "black").opacity(boxAlpha ?? 0.7) }
    /// The word in Pop's box: black on the named highlights, as it's always been; on any other, by how light it is.
    var popInk: Color {
        guard let name = highlight, name.hasPrefix("#") else { return .black }
        // (the five there were, picked again from the saved ones: as they always were)
        let five: [String] = ["yellow", "green", "red", "blue", "white"].map { (n: String) -> String in ColourCode.hex(named: n) }
        return five.contains(name.uppercased()) ? Color.black : EditText.ink(on: name)
    }
    /// Bold's edge: black, or white round dark words.
    var boldEdge: Color {
        guard let name = wordColour else { return .black }
        return EditText.ink(on: name) == Color.black ? Color.black : Color.white
    }
    static let colours = ["white", "yellow", "black", "red", "green"]
    static let stickers = ["💪", "🔥", "🏋️", "🍕", "🥗", "🍔", "🥩", "🍳", "😋", "🎉", "✅", "⭐️", "❤️", "👀", "😮‍💨", "🏃"]

    static func colour(_ name: String) -> Color {
        if name.hasPrefix("#") { return StoryArt.color(name) }
        switch name {
        case "yellow": return Color(red: 1, green: 0.8, blue: 0.2)
        case "black": return .black
        case "red": return Color(red: 1, green: 0.35, blue: 0.37)
        case "green": return Color(red: 0.36, green: 0.82, blue: 0.56)
        case "blue": return Color(red: 0.36, green: 0.66, blue: 0.95)
        default: return .white
        }
    }

    /// The bar's colour on the timeline, by kind (as the mockup colours them).
    var barColour: Color {
        switch kind {
        case "sticker", "calories": return Color(red: 1, green: 0.8, blue: 0.2)
        case "caption": return Color(red: 0.48, green: 0.82, blue: 1)
        case "step", "macros": return Color(red: 0.36, green: 0.82, blue: 0.56)
        case "workout": return Color(red: 1, green: 0.48, blue: 0.48)
        case "label": return Color(red: 1, green: 0.62, blue: 0.3)
        default: return Color(red: 0.77, green: 0.63, blue: 1)
        }
    }

    var barLabel: String {
        switch kind {
        case "caption": return text
        case "calories": return "\(Int(number)) kcal"
        default: return text.isEmpty ? kind.capitalized : text
        }
    }

    /// The word being said at `t`, if it's a caption.
    func lit(at t: Double) -> Int? {
        guard let words, !words.isEmpty else { return nil }
        return words.lastIndex { $0.at <= t + 0.001 } ?? 0
    }
}

/// One thing over the edit as it's drawn: laid out on the 390-point design width (as stories are), so the preview
/// and the finished video agree at any size. `at` is the moment shown, for a caption's lit word and the count.
struct EditTextView: View {
    let item: EditText
    let at: Double

    var body: some View {
        content   // (its size is the scale it is drawn at: the editor's preview and the finished video both size it)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case "sticker":
            Text(item.text).font(.system(size: 72))
        case "caption":
            caption
        case "card":
            StoryItem(o: item.cardJSON ?? [:])
        case "step":
            // its number ("2/5") in yellow before it, as the recipe's look has it (design/editor-recipe-mockup.html)
            let line = (item.detail.isEmpty ? Text("") : Text(item.detail + "  ").foregroundColor(EditText.colour("yellow"))) + Text(item.text)
            switch item.style {
            case "Caption":
                line.font(.system(size: 26, weight: .black)).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 340)
                    .shadow(color: .black, radius: 0, x: 1.5, y: 1.5).shadow(color: .black, radius: 0, x: -1.5, y: -1.5)
                    .shadow(color: .black, radius: 0, x: 1.5, y: -1.5).shadow(color: .black, radius: 0, x: -1.5, y: 1.5)
            case "Minimal":
                line.font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 320)
                    .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
            default:
                line.font(.system(size: 22, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.leading)
                    .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: 340, alignment: .leading)
                    .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case "ingredients":
            // a line each, as many as fit and how many more
            let lines = item.text.split(separator: "\n").map(String.init)
            VStack(alignment: .leading, spacing: 3) {
                Text("INGREDIENTS").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(EditText.colour("yellow"))
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).font(.system(size: item.style == "Minimal" ? 15 : 17, weight: .bold)).foregroundStyle(.white.opacity(lines[i].hasPrefix("+") ? 0.6 : 1))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 300, alignment: .leading)
            .background(.black.opacity(item.style == "Minimal" ? 0.35 : 0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case "macros":
            VStack(spacing: 4) {
                Text(item.text).font(.system(size: 30, weight: .black, design: .rounded))
                Text(item.detail).font(.system(size: 17, weight: .bold)).opacity(0.85)
            }
            .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12)
            .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        case "workout":
            VStack(spacing: 3) {
                Text(item.text).font(.system(size: 24, weight: .heavy))
                if !item.detail.isEmpty { Text(item.detail).font(.system(size: 18, weight: .bold)).monospacedDigit().opacity(0.9) }
            }
            .foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color(red: 0.85, green: 0.25, blue: 0.3).opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case "label":
            // a template slot's words (design/templates-mockup.html): what it is, and its numbers under
            VStack(alignment: .leading, spacing: 2) {
                if !item.text.isEmpty { Text(item.text).font(.system(size: 22, weight: .heavy)) }
                if !item.detail.isEmpty { Text(item.detail).font(.system(size: 16, weight: .bold)).monospacedDigit().opacity(0.88) }
            }
            .foregroundStyle(.white).modifier(HugWidth.UpTo(most: 320))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case "calories":
            // counting up over its first second and a bit, easing in to the number
            let k = min(1, max(0, (at - item.from) / 1.2)), eased = 1 - pow(1 - k, 3)
            VStack(spacing: 2) {
                Text("\(Int((item.number * eased).rounded()))").font(.system(size: 64, weight: .black, design: .rounded)).monospacedDigit()
                Text("kcal").font(.system(size: 20, weight: .heavy))
                if !item.detail.isEmpty { Text(item.detail).font(.system(size: 17, weight: .bold)).opacity(k >= 1 ? 0.9 : 0) }
            }
            .foregroundStyle(.white).padding(.horizontal, 26).padding(.vertical, 14)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        default:
            plainText
        }
    }

    @ViewBuilder private var plainText: some View {
        let ink = EditText.colour(item.colour).opacity(item.colourAlpha ?? 1)
        let t = Text(item.text).font(EditText.font(item.font, size: 30)).multilineTextAlignment(.center).modifier(HugWidth.UpTo(most: 330))
        switch item.style {
        case "Box":
            t.foregroundStyle(EditText.ink(on: item.colour))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case "Outline":
            // edged all round in black, or white for a dark colour
            let edge = EditText.ink(on: item.colour) == .black ? Color.black : Color.white
            t.foregroundStyle(ink)
                .shadow(color: edge, radius: 0, x: 1.5, y: 1.5).shadow(color: edge, radius: 0, x: -1.5, y: -1.5)
                .shadow(color: edge, radius: 0, x: 1.5, y: -1.5).shadow(color: edge, radius: 0, x: -1.5, y: 1.5)
        case "Plain":
            t.foregroundStyle(ink)
        default:
            t.foregroundStyle(ink).shadow(color: .black.opacity(0.7), radius: 4, y: 2)
        }
    }

    /// The words said, the one being said lit in the caption's own colour (behind it, or the word in it). Long ones
    /// go onto a second line rather than off the sides.
    @ViewBuilder private var caption: some View {
        let words = item.words ?? item.text.split(separator: " ").map { EditText.Word(text: String($0), at: item.from) }
        // no highlight: every word the same (21 Nov: "might not want it")
        let lit = item.highlight == "none" ? nil : item.lit(at: at)
        let ink = item.lit
        // one line: never onto a second, a long one a little smaller instead (21 Nov: "says 1 line but is more")
        let oneLine = item.detail == "1"
        let letters = words.reduce(0) { $0 + $1.text.count + 1 }
        let size: CGFloat = oneLine ? min(26, 26 * 19 / CGFloat(max(19, letters))) : 26
        let line = words.indices.reduce(Text("")) { sum, i in
            let w = Text((i == 0 ? "" : " ") + words[i].text)
            return sum + (i == lit && item.style != "Pop" ? w.foregroundColor(ink) : w)
        }
        let base = line.font(.system(size: 26, weight: .black)).multilineTextAlignment(.center)
            .lineLimit(oneLine ? 1 : nil).minimumScaleFactor(oneLine ? 0.5 : 1).modifier(HugWidth.UpTo(most: 330))
        switch item.style {
        case "Box":
            base.foregroundStyle(item.saidInk).padding(.horizontal, 12).padding(.vertical, 6)
                .background(item.boxInk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case "Plain":
            base.foregroundStyle(item.saidInk).shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        case "Bold":
            // bigger, edged in black all round
            line.font(.system(size: 30, weight: .black)).multilineTextAlignment(.center)
                .lineLimit(oneLine ? 1 : nil).minimumScaleFactor(oneLine ? 0.5 : 1).modifier(HugWidth.UpTo(most: 340)).foregroundStyle(item.saidInk)
                .shadow(color: item.boldEdge, radius: 0, x: 1.5, y: 1.5).shadow(color: item.boldEdge, radius: 0, x: -1.5, y: -1.5)
                .shadow(color: item.boldEdge, radius: 0, x: 1.5, y: -1.5).shadow(color: item.boldEdge, radius: 0, x: -1.5, y: 1.5)
        default:
            // Pop: the word being said in a box of its own, the rest white
            WordRows(spacing: 5, rowSpacing: 4) {
                ForEach(words.indices, id: \.self) { i in
                    let on = i == lit
                    Text(words[i].text).font(.system(size: size, weight: .black))
                        .foregroundStyle(on ? item.popInk : item.saidInk)
                        .padding(.horizontal, on ? 4 : 0)
                        .background(on ? ink : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .shadow(color: on ? .clear : .black.opacity(0.8), radius: 3, y: 1)
                }
            }
            .modifier(HugWidth.UpTo(most: oneLine ? 2000 : 340))
        }
    }
}

/// Words side by side, onto the next row when there's no more room, each row centred.
struct WordRows: Layout {
    var spacing: CGFloat = 5, rowSpacing: CGFloat = 4

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]], used: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            let need = (out[out.count - 1].isEmpty ? 0 : spacing) + s.width
            if !out[out.count - 1].isEmpty, used + need > width { out.append([]); used = 0 }
            used += (out[out.count - 1].isEmpty ? 0 : spacing) + s.width
            out[out.count - 1].append(i)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? .infinity
        let rs = rows(sizes, width: width)
        var w: CGFloat = 0, h: CGFloat = 0
        for (k, r) in rs.enumerated() {
            let rw = r.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, r.count - 1))
            w = max(w, rw)
            h += (r.map { sizes[$0].height }.max() ?? 0) + (k > 0 ? rowSpacing : 0)
        }
        return CGSize(width: min(w, width), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for r in rows(sizes, width: bounds.width) {
            let rw = r.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, r.count - 1))
            let rh = r.map { sizes[$0].height }.max() ?? 0
            var x = bounds.midX - rw / 2
            for i in r {
                subviews[i].place(at: CGPoint(x: x, y: y + (rh - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += rh + rowSpacing
        }
    }
}

/// What's heard in a recording, every part of it (a part comes at each pause), in order, each word once: then
/// answered once, when the task's finished.
private final class Hearer: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    private var c: CheckedContinuation<[Heard], Error>?
    private var words: [Heard] = []
    // kept until it's answered (the task may not keep its delegate)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: Set<Hearer> = []
    var task: SFSpeechRecognitionTask?
    init(_ c: CheckedContinuation<[Heard], Error>) {
        self.c = c
        super.init()
        Self.lock.lock(); Self.live.insert(self); Self.lock.unlock()
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
        // a part may come with the parts before it again: only words after the last kept. Its words' times are
        // the recording's; if they're the part's own instead (before where the part's speech starts), moved on
        let end = words.last.map { $0.at + $0.long } ?? -1
        let segs = result.bestTranscription.segments
        let starts = result.speechRecognitionMetadata?.speechStartTimestamp ?? 0
        let shift = (segs.first.map { $0.timestamp + 0.05 < starts } ?? false) ? starts : 0
        for seg in segs where !seg.substring.isEmpty {
            let at = seg.timestamp + shift
            guard at >= end - 0.05 else { continue }
            if let last = words.last, abs(last.at - at) < 0.01 { continue }
            words.append(Heard(text: seg.substring, at: at, long: seg.duration))
        }
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully ok: Bool) {
        guard let c else { return }
        self.c = nil
        // (finished badly but with words heard: those)
        if ok || !words.isEmpty { c.resume(returning: words) }
        else { c.resume(throwing: task.error ?? NSError(domain: "Captions", code: 1, userInfo: [NSLocalizedDescriptionKey: "No words were heard in this edit."])) }
        self.task = nil
        Self.lock.lock(); Self.live.remove(self); Self.lock.unlock()
    }
}

/// A word heard, and when (seconds into the recording) and for how long.
private struct Heard { var text: String; var at: Double; var long: Double }

/// A picture of one overlay for the finished video, and when it shows (EditCompositor lays it on).
struct OverlayPiece {
    var image: CIImage
    var from: Double
    var to: Double
    var x: Double
    var y: Double
}

enum EditOverlays {
    static let design: CGFloat = 390

    /// The GIF stickers' frames, by address, read before the video's made (`prepare`).
    @MainActor static var gifs: [String: UIImage] = [:]

    /// The addresses of the GIF stickers among the items.
    static func gifURLs(_ items: [EditText]) -> [String] {
        items.compactMap { (item: EditText) -> String? in
            guard item.kind == "card", let o = item.cardJSON, str(o["type"]) == "gif" else { return nil }
            return str(o["url"])
        }
    }

    /// Each GIF sticker's frames fetched, if they aren't already; false when any didn't come (the video's not made then).
    @discardableResult @MainActor static func prepare(_ items: [EditText]) async -> Bool {
        var all = true
        for url in gifURLs(items) where gifs[url] == nil {
            if let img = await AnimatedGIF.fetch(url, maxPixel: 480) { gifs[url] = img } else { all = false }
        }
        return all
    }

    /// Every overlay as pictures at the finished video's size: one for most; one a word for a caption (that word lit),
    /// and the count's steps for the calories.
    @MainActor static func pieces(_ items: [EditText], frame: CGSize) -> [OverlayPiece] {
        let scale = frame.width / design
        var out: [OverlayPiece] = []
        func shot(_ item: EditText, at: Double, from: Double, to: Double) {
            guard to > from + 0.01 else { return }
            let r = ImageRenderer(content: EditTextView(item: item, at: at).padding(24))
            r.scale = scale * CGFloat(item.size)   // its size drawn in, not scaled after (20 Nov: a big one was cropped)
            if let ui = r.uiImage, let ci = CIImage(image: ui) { out.append(OverlayPiece(image: ci, from: from, to: to, x: item.x, y: item.y)) }
        }
        for item in items where item.hidden != true {
            switch item.kind {
            case "card" where str(item.cardJSON?["type"]) == "gif":
                // a GIF moves in the finished video: each of its frames for its own moment, round again till it's
                // off (the frames made once, the same pictures each time round)
                let o = item.cardJSON ?? [:]
                // never through shot(): ImageRenderer draws a GIF's view as a yellow box (22 Nov). One of one frame is
                // that frame, held; one that never came is left out (finish() won't make the video without it)
                guard let gif = gifs[str(o["url"])] else { continue }
                let moving = (gif.images?.count ?? 0) > 1 && gif.duration > 0.05
                let frames: [UIImage] = moving ? (gif.images ?? []) : [gif.images?.first ?? gif]
                let w = num(o["w"]) ?? 200, h = num(o["h"]) ?? 200
                let side = 170 * scale * CGFloat(item.size)   // as StoryItem draws it, in the video's pixels
                let size = CGSize(width: side, height: side * h / max(1, w))
                let pics: [CIImage] = frames.compactMap { f in
                    guard let cg = f.cgImage else { return nil }
                    let ci = CIImage(cgImage: cg)
                    return ci.transformed(by: CGAffineTransform(scaleX: size.width / max(1, ci.extent.width), y: size.height / max(1, ci.extent.height)))
                }
                guard !pics.isEmpty else { continue }
                let each = moving ? gif.duration / Double(pics.count) : item.to - item.from
                var t = item.from, i = 0
                while t < item.to - 0.001 {
                    let end = min(item.to, t + each)
                    out.append(OverlayPiece(image: pics[i % pics.count], from: t, to: end, x: item.x, y: item.y))
                    t = end; i += 1
                }
            case "caption":
                let words = item.words ?? []
                if words.isEmpty { shot(item, at: item.from, from: item.from, to: item.to); continue }
                for i in words.indices {
                    let start = i == 0 ? item.from : words[i].at
                    let end = i + 1 < words.count ? words[i + 1].at : item.to
                    shot(item, at: words[i].at, from: start, to: end)
                }
            case "calories":
                // fifteen steps of the count, then the number held
                let steps = 15
                for s in 0..<steps {
                    let a = item.from + 1.2 * Double(s) / Double(steps), b = item.from + 1.2 * Double(s + 1) / Double(steps)
                    shot(item, at: a, from: a, to: min(b, item.to))
                }
                shot(item, at: item.from + 1.3, from: item.from + 1.2, to: item.to)
            default:
                shot(item, at: item.from, from: item.from, to: item.to)
            }
        }
        return out
    }

    /// The captions made again from their words, each holding as much as `by` says (a word, a few, a line's worth,
    /// a sentence), never more than `lines` lines' worth (21 Nov, CapCut's way): straight away, as every word keeps
    /// when it's said. Each new one looks like the caption its first word was in.
    static func regroup(_ caps: [EditText], by: String, lines: Int) -> [EditText] {
        let sorted = caps.sorted { $0.from < $1.from }
        // every word, with when it ends and the caption it was in
        var all: [(w: EditText.Word, end: Double, from: Int)] = []
        for (k, c) in sorted.enumerated() {
            let ws = c.words ?? []
            for i in ws.indices { all.append((ws[i], i + 1 < ws.count ? ws[i + 1].at : c.to, k)) }
        }
        guard !all.isEmpty else { return caps }
        let most = lines > 1 ? 36 : 18   // letters a line holds at the caption's size (24 wrapped: 21 Nov)
        var out: [EditText] = []
        var group: [(w: EditText.Word, end: Double, from: Int)] = []
        func close() {
            guard let first = group.first, let last = group.last else { return }
            var c = sorted[first.from]
            c.id = UUID()
            c.words = group.map(\.w)
            c.text = group.map(\.w.text).joined(separator: " ")
            c.from = first.w.at
            c.to = max(first.w.at + 0.3, last.end)
            c.detail = lines > 1 ? "" : "1"   // (drawn on one line, never wrapped)
            out.append(c)
            group = []
        }
        for item in all {
            if let last = group.last {
                let pause = item.w.at - last.end
                let length = group.map(\.w.text.count).reduce(0, +) + group.count + item.w.text.count
                let ended = last.w.text.last.map { ".!?".contains($0) } ?? false
                let comma = last.w.text.last.map { ",;:".contains($0) } ?? false
                let full: Bool
                switch by {
                case "word": full = true
                case "line": full = length > most || pause > 1.0
                case "sentence": full = ended || length > most * 2 || pause > 1.2
                default: full = group.count >= 3 || ended || comma || pause > 0.6 || length > most
                }
                if full || length > most * (by == "sentence" ? 2 : 1) { close() }
            }
            group.append(item)
        }
        close()
        // each held until the next one comes, if that's soon
        for i in out.indices.dropLast() where out[i + 1].from - out[i].to < 0.8 { out[i].to = out[i + 1].from }
        return out
    }

    /// A caption in two, the second starting at word `at` (each keeps its words' times), or nil at its ends.
    static func split(_ c: EditText, at: Int) -> (EditText, EditText)? {
        guard let ws = c.words, at > 0, at < ws.count else { return nil }
        var a = c, b = c
        b.id = UUID()
        a.words = Array(ws[..<at]); b.words = Array(ws[at...])
        a.text = a.words!.map(\.text).joined(separator: " "); b.text = b.words!.map(\.text).joined(separator: " ")
        a.to = ws[at].at; b.from = ws[at].at
        return (a, b)
    }

    /// Two captions as one, looking as the first does.
    static func join(_ a: EditText, _ b: EditText) -> EditText {
        var c = a
        c.words = (a.words ?? []) + (b.words ?? [])
        c.text = a.text + " " + b.text
        c.from = min(a.from, b.from); c.to = max(a.to, b.to)
        return c
    }

    /// Captions from what's said in the edit (Stage B): its sound as heard, made into words on the phone itself
    /// (nothing sent, nothing paid), each with when it's said, grouped a few words a caption.
    struct CaptionProblem: LocalizedError { let errorDescription: String? }

    static func captions(_ clips: [Clip], soundOf: UUID?) async throws -> [EditText] {
        typealias Problem = CaptionProblem
        // the edit's sound as it will be heard, as one file
        guard let (comp, _, mix) = await ClipJoin.compose(clips, soundOf: soundOf),
              !(try await comp.loadTracks(withMediaType: .audio)).isEmpty,
              let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw Problem(errorDescription: "There's no sound in this edit to make captions from.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        export.outputURL = file; export.outputFileType = .m4a; export.audioMix = mix
        export.audioTimePitchAlgorithm = .spectral
        await export.export()
        guard export.status == .completed else { throw Problem(errorDescription: "Couldn't hear this edit's sound.") }
        let words = try await hear(file)
        let out = group(words)
        if out.isEmpty { throw Problem(errorDescription: "No words were heard in this edit.") }
        return out
    }

    /// A voiceover's (or a separated clip sound's) captions, heard from its own recording (21 Nov: a voiceover added
    /// after had none, and making them again meant all of them): its words at their times in the video.
    static func captions(of s: EditSound) async throws -> [EditText] {
        guard let file = s.file else { throw CaptionProblem(errorDescription: "This sound has nothing to hear.") }
        let heard = try await hear(file).filter { $0.at >= s.start - 0.05 && $0.at <= s.fileTime(s.to) + 0.05 }
            .map { Heard(text: $0.text, at: s.videoTime($0.at), long: $0.long / s.speed) }
        var out = group(heard)
        if out.isEmpty { throw CaptionProblem(errorDescription: "No words were heard in \(s.name).") }
        // each word held to the voiceover it was said in, wherever that's moved
        for k in out.indices {
            out[k].words = out[k].words?.map { var w = $0; w.clip = s.id; w.src = s.fileTime(w.at); return w }
        }
        return out
    }

    /// Each caption word not yet tied to where it was said, tied to the clip it's heard over in `clips`.
    static func anchor(_ texts: [EditText], clips: [Clip]) -> [EditText] {
        let starts = ClipJoin.starts(clips)
        return texts.map { t in
            guard t.kind == "caption", let words = t.words else { return t }
            var u = t
            u.words = words.map { w in
                guard w.src == nil, let i = starts.lastIndex(where: { $0 <= w.at + 0.001 }), w.at < starts[i] + clips[i].span + 0.001 else { return w }
                let c = clips[i]
                var x = w
                x.clip = c.id; x.file = c.source.lastPathComponent; x.src = c.start + (w.at - starts[i]) * max(c.speed, 0.01)
                return x
            }
            return u
        }
    }

    /// The captions put where their words now are (21 Nov: "when you move stuff around or adjust length it breaks
    /// the captions"): a word goes with the moment it was said in, wherever its clip (or voiceover) now plays; a
    /// word trimmed out goes; a caption whose words now play apart (a clip trimmed or moved between them) becomes
    /// one for each part. A caption never runs past the clip its last word's in, nor over the next. Captions with
    /// words not tied anywhere are left as they are.
    static func reanchor(_ texts: [EditText], clips: [Clip], sounds: [EditSound]) -> [EditText] {
        let starts = ClipJoin.starts(clips)
        // where a word plays now, and where the stretch it's in ends
        func place(_ w: EditText.Word) -> (at: Double, end: Double)? {
            guard let src = w.src else { return nil }
            if let id = w.clip, let s = sounds.first(where: { $0.id == id }) {
                guard src >= s.start - 0.01, src <= s.fileTime(s.to) + 0.01 else { return nil }
                return (s.videoTime(src), s.to)
            }
            guard let i = ClipCuts.clip(for: w, in: clips) else { return nil }
            let c = clips[i]
            return (starts[i] + max(0, src - c.start) / max(c.speed, 0.01), starts[i] + c.span)
        }
        var out: [EditText] = []
        for t in texts {
            guard t.kind == "caption", let words = t.words, !words.isEmpty, words.allSatisfy({ $0.src != nil }) else { out.append(t); continue }
            let placed = words.compactMap { w in place(w).map { (word: w, at: $0.at, end: $0.end) } }.sorted { $0.at < $1.at }
            guard !placed.isEmpty else { continue }
            // apart where they're more than a moment apart (a clip trimmed or moved between them)
            var runs: [[(word: EditText.Word, at: Double, end: Double)]] = []
            for p in placed {
                if let last = runs.last?.last, p.at - last.at < 1.2 { runs[runs.count - 1].append(p) } else { runs.append([p]) }
            }
            let whole = runs.count == 1 && placed.count == words.count
            let tail = whole ? min(2, max(0.3, t.to - (words.last?.at ?? t.from))) : 0.5
            for (n, run) in runs.enumerated() {
                var c = t
                if n > 0 { c.id = UUID() }
                c.words = run.map { var w = $0.word; w.at = $0.at; return w }
                if !whole { c.text = run.map { $0.word.text }.joined(separator: " ") }
                c.from = run[0].at
                c.to = max(c.from + 0.1, min(run.last!.at + tail, run.last!.end))
                out.append(c)
            }
        }
        // none over the next in its layer: a voiceover's may run over the video's own (the list itself kept in its
        // order: it's the order they're drawn in)
        return CaptionLayers.clamped(out, voices: CaptionLayers.voiceIDs(sounds))
    }

    /// New captions put in with the ones there (21 Nov: "adding in sound after… you'd have to do it all over
    /// again"). With `over`, a stretch made again: what was in it goes and the new ones in it come in. Without, the
    /// gaps filled: only new ones that don't run into one already there. New ones take the look of the ones there;
    /// none runs over the next.
    static func merge(_ old: [EditText], _ made: [EditText], over: ClosedRange<Double>? = nil) -> [EditText] {
        let caps = old.filter { $0.kind == "caption" }
        var keep: [EditText], add: [EditText]
        if let r = over {
            keep = caps.filter { $0.to <= r.lowerBound + 0.05 || $0.from >= r.upperBound - 0.05 }
            add = made.filter { $0.from >= r.lowerBound - 0.05 && $0.from < r.upperBound }
        } else {
            keep = caps
            add = made.filter { n in !caps.contains { min($0.to, n.to) - max($0.from, n.from) > 0.05 } }
        }
        if let like = caps.first {
            for i in add.indices {
                add[i].takeLook(from: like)
                add[i].byHand = like.byHand
            }
        }
        var all = (keep + add).sorted { $0.from < $1.from }
        for i in all.indices.dropLast() where all[i].to > all[i + 1].from { all[i].to = max(all[i].from + 0.1, all[i + 1].from) }
        return all
    }

    /// The words said in a recording, on the phone.
    private static func hear(_ file: URL) async throws -> [Heard] {
        typealias Problem = CaptionProblem
        let ok = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard ok == .authorized else { throw Problem(errorDescription: "Captions need Speech Recognition: turn it on in Settings › Cheat Days.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw Problem(errorDescription: "Captions are made on the phone itself, and this phone can't do that in your language yet.")
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // Heard on the phone, a long recording comes back a part at a time, each part ending at a pause, and the
        // first part said it was the last (21 Nov: a 45 s edit's captions stopped after a few seconds; a 10 s one
        // spoken without a pause was whole). So every part is kept until the task says it's finished.
        return try await withCheckedThrowingContinuation { c in
            let hearer = Hearer(c)
            hearer.task = recognizer.recognitionTask(with: request, delegate: hearer)
        }
    }

    /// Words heard made into captions.
    private static func group(_ segments: [Heard]) -> [EditText] {
        // a caption: up to three words, broken at a pause or the end of a sentence
        var out: [EditText] = []
        var group: [Heard] = []
        func close() {
            guard let first = group.first, let last = group.last else { return }
            let words = group.map { EditText.Word(text: $0.text, at: $0.at) }
            out.append(EditText(kind: "caption", text: words.map(\.text).joined(separator: " "), style: "Pop", x: 0.5, y: 0.76,
                                from: first.at, to: last.at + max(0.3, last.long), words: words))
            group = []
        }
        for seg in segments {
            if let last = group.last, seg.at - (last.at + last.long) > 0.6 { close() }
            group.append(seg)
            let ends = seg.text.last.map { ".!?,".contains($0) } ?? false
            if group.count >= 3 || ends { close() }
        }
        close()
        // each held until the next one comes, if that's soon
        for i in out.indices.dropLast() where out[i + 1].from - out[i].to < 0.8 { out[i].to = out[i + 1].from }
        return out
    }

    /// How a recipe is laid over the video (design/editor-recipe-mockup.html): which parts, their look, where the
    /// steps go (a clip each, the ones moved by hand, or spread evenly), any step's words shortened, and the end's numbers.
    struct RecipePlan: Equatable {
        var title = true, ingredients = true, method = true, macros = true
        var look = "Card"                   // "Card", "Caption", "Minimal"
        var spread = false                  // the steps shared out evenly, not one a clip
        var clipOf: [Int: Int] = [:]        // a step moved to another clip
        var words: [Int: String] = [:]      // a step's words changed
        var countUp = true
        var show: Set<String> = ["p", "c", "f"]
        static let looks = ["Card", "Caption", "Minimal"]
    }

    /// A saved meal's method, a line a step.
    static func steps(of meal: JSON) -> [String] {
        let payload = meal["payload"] as? JSON ?? [:]
        var steps: [String] = list(payload["steps"]).map { str($0["text"]) }
        if steps.allSatisfy({ $0.isEmpty }) { steps = (payload["steps"] as? [String]) ?? [] }
        return steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Its ingredients, a line each with how much: at most six, then how many more.
    static func ingredients(of meal: JSON) -> [String] {
        let items = list((meal["payload"] as? JSON)?["items"])
        var out: [String] = items.compactMap { it in
            let name = str(it["name"])
            guard !name.isEmpty else { return nil }
            guard let g = num(it["grams"]), g > 0 else { return name }
            let unit = str(it["unit"]).isEmpty ? "g" : str(it["unit"])
            return "\(Fmt.int(g)) \(unit) \(name)"
        }
        if out.count > 6 { let more = out.count - 5; out = Array(out.prefix(5)) + ["+\(more) more"] }
        return out
    }

    /// A saved recipe as a cooking reel over the clips (21 Nov): its card at the start, its ingredients after, its method
    /// a step at a time, a portion's numbers on the last clip. Each is marked as the recipe's, to be made again together.
    static func reel(_ meal: JSON, clips: [Clip], plan: RecipePlan) -> [EditText] {
        let starts = ClipJoin.starts(clips), total = ClipJoin.total(clips)
        guard !clips.isEmpty, total > 0.2 else { return [] }
        let name = str(meal["name"]), kcal = num(meal["kcal"]) ?? 0
        let m = meal["macros"] as? JSON ?? [:]
        let p = Int(num(m["p"]) ?? 0), c = Int(num(m["c"]) ?? 0), fat = Int(num(m["f"]) ?? 0)
        let steps = Self.steps(of: meal), items = Self.ingredients(of: meal)
        var out: [EditText] = []
        func add(_ t: EditText) { var t = t; t.part = "recipe"; out.append(t) }
        // the end: the last clip, or the last 2.5 s of one
        let endAt = plan.macros ? (clips.count > 1 ? starts[clips.count - 1] : max(0, total - 2.5)) : total
        var at = 0.0
        if plan.title {
            let o: JSON = ["type": "recipe", "name": name, "kcal": Int(kcal), "p": p, "c": c, "f": fat,
                           "n": list((meal["payload"] as? JSON)?["items"]).count, "steps": steps.count]
            if let d = try? JSONSerialization.data(withJSONObject: o), let json = String(data: d, encoding: .utf8) {
                var t = EditText(kind: "card", text: name.isEmpty ? "Recipe" : name, x: 0.5, y: 0.36, from: 0, to: min(endAt, 2.2))
                t.card = json
                add(t)
                at = t.to
            }
        }
        if plan.ingredients, !items.isEmpty, at < endAt - 0.3 {
            add(EditText(kind: "ingredients", text: items.joined(separator: "\n"), style: plan.look, x: 0.5, y: 0.3, from: at, to: min(endAt, at + 2.8)))
        }
        if plan.method, !steps.isEmpty {
            // a clip each (the clips before the end's), unless there are more steps than that or they're spread
            let room = max(1, plan.macros && clips.count > 1 ? clips.count - 1 : clips.count)
            let even = plan.spread || steps.count > room
            for i in steps.indices {
                var from: Double, to: Double
                if even {
                    let step = endAt / Double(steps.count)
                    from = step * Double(i); to = step * Double(i + 1)
                } else {
                    let k = min(max(0, plan.clipOf[i] ?? i), clips.count - 1)
                    from = starts[k]; to = starts[k] + clips[k].span
                }
                guard to > from + 0.2 else { continue }
                add(EditText(kind: "step", text: plan.words[i] ?? steps[i], detail: "\(i + 1)/\(steps.count)", style: plan.look,
                             x: 0.5, y: 0.8, from: from, to: to))
            }
        }
        if plan.macros {
            var bits: [String] = []
            if plan.show.contains("p") { bits.append("P \(p) g") }
            if plan.show.contains("c") { bits.append("C \(c) g") }
            if plan.show.contains("f") { bits.append("F \(fat) g") }
            let detail = bits.joined(separator: " · ")
            if plan.countUp {
                add(EditText(kind: "calories", text: name, detail: detail, x: 0.5, y: 0.42, from: endAt, to: total, number: kcal))
            } else {
                add(EditText(kind: "macros", text: "\(Int(kcal)) kcal", detail: detail, x: 0.5, y: 0.42, from: endAt, to: total))
            }
        }
        return out
    }

    /// A meal's steps, one a clip, and its macros on the last (recipe mode).
    static func recipe(_ meal: JSON, clips: [Clip]) -> [EditText] {
        let starts = ClipJoin.starts(clips)
        let payload = meal["payload"] as? JSON ?? [:]
        var steps: [String] = list(payload["steps"]).map { str($0["text"]) }
        if steps.allSatisfy({ $0.isEmpty }) { steps = (payload["steps"] as? [String]) ?? [] }
        steps = steps.filter { !$0.isEmpty }
        if steps.isEmpty { steps = list(payload["items"]).map { str($0["name"]) }.filter { !$0.isEmpty } }
        var out: [EditText] = []
        let shown = min(steps.count, max(0, clips.count - 1))
        for i in 0..<shown {
            out.append(EditText(kind: "step", text: "\(i + 1). " + steps[i], x: 0.5, y: 0.8, from: starts[i], to: starts[i] + clips[i].span))
        }
        if let last = clips.indices.last {
            let m = meal["macros"] as? JSON ?? [:]
            let detail = "P \(Int(num(m["p"]) ?? 0)) g · C \(Int(num(m["c"]) ?? 0)) g · F \(Int(num(m["f"]) ?? 0)) g"
            out.append(EditText(kind: "macros", text: "\(Int(num(meal["kcal"]) ?? 0)) kcal", detail: detail, x: 0.5, y: 0.5,
                                from: starts[last], to: starts[last] + clips[last].span))
        }
        return out
    }

    /// A workout's exercises, one a clip, each with its sets and weight (workout mode).
    static func workout(_ w: JSON, clips: [Clip]) -> [EditText] {
        let starts = ClipJoin.starts(clips)
        let lifts = list((w["payload"] as? JSON)?["lifts"])
        var out: [EditText] = []
        for i in 0..<min(lifts.count, clips.count) {
            let l = lifts[i]
            let name = str(l["exercise"]).isEmpty ? str(l["name"]) : str(l["exercise"])
            let sets = Int(num(l["sets"]) ?? 0), reps = Int(num(l["reps"]) ?? 0), kg = num(l["kg"]) ?? 0
            var detail = sets > 0 && reps > 0 ? "\(sets) × \(reps)" : ""
            if kg > 0 { detail += (detail.isEmpty ? "" : " · ") + Fmt.int(kg) + " kg" }
            out.append(EditText(kind: "workout", text: name, detail: detail, x: 0.5, y: 0.16, from: starts[i], to: starts[i] + clips[i].span))
        }
        return out
    }
}

/// A second clip or photo over the edit (Stage D; design/editor-all-tools-mockup.html, 7): a reaction, a before and
/// after. Where and how big it is, and how see-through; with keyframes it moves and grows over time.
struct EditPip: Identifiable, Codable, Equatable {
    var id = UUID()
    var source: URL
    var start = 0.0            // where in its own file it starts
    var length: Double         // how much of it shows
    var from: Double           // where it starts in the video
    var full = 0.0             // its file's length
    var aspect = 9.0 / 16.0    // its width over its height, the right way up
    var x = 0.72, y = 0.28     // its middle, as fractions of the frame
    var size = 0.36            // its width, as a fraction of the frame's
    var opacity = 1.0
    var keys: [MoveKey] = []   // seconds from its start
    var lane: Int? = nil       // the timeline row it's on, as a text's
    var off: Bool? = nil       // its row's eye switched off: kept, but not shown (23 Nov)
    var to: Double { from + length }

    /// Those to be seen: none whose row's switched off.
    static func shown(_ all: [EditPip]) -> [EditPip] { all.filter { (p: EditPip) -> Bool in p.off != true } }

    /// Where it is `t` seconds into the video.
    func place(at t: Double) -> MoveKey {
        MoveKey.value(keys, at: t - from, base: MoveKey(at: 0, x: x, y: y, size: size, opacity: opacity))
    }
}
