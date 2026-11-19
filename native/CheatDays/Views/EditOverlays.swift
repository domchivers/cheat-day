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

    struct Word: Codable, Equatable { var text: String; var at: Double }

    static let textStyles = ["Shadow", "Box", "Plain"]
    static let captionStyles = ["Pop", "Box", "Plain"]
    static let colours = ["white", "yellow", "black", "red", "green"]
    static let stickers = ["💪", "🔥", "🏋️", "🍕", "🥗", "🍔", "🥩", "🍳", "😋", "🎉", "✅", "⭐️", "❤️", "👀", "😮‍💨", "🏃"]

    static func colour(_ name: String) -> Color {
        switch name {
        case "yellow": return Color(red: 1, green: 0.8, blue: 0.2)
        case "black": return .black
        case "red": return Color(red: 1, green: 0.35, blue: 0.37)
        case "green": return Color(red: 0.36, green: 0.82, blue: 0.56)
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
        case "step":
            Text(item.text).font(.system(size: 22, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 9).frame(maxWidth: 330)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        let ink = EditText.colour(item.colour)
        let t = Text(item.text).font(.system(size: 30, weight: .heavy)).multilineTextAlignment(.center).frame(maxWidth: 330)
        switch item.style {
        case "Box":
            t.foregroundStyle(item.colour == "white" || item.colour == "yellow" ? Color.black : Color.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case "Plain":
            t.foregroundStyle(ink)
        default:
            t.foregroundStyle(ink).shadow(color: .black.opacity(0.7), radius: 4, y: 2)
        }
    }

    /// The words said, the one being said lit (yellow behind it, or in yellow).
    @ViewBuilder private var caption: some View {
        let words = item.words ?? item.text.split(separator: " ").map { EditText.Word(text: String($0), at: item.from) }
        let lit = item.lit(at: at)
        let line = words.indices.reduce(Text("")) { sum, i in
            let w = Text((i == 0 ? "" : " ") + words[i].text)
            return sum + (i == lit && item.style != "Pop" ? w.foregroundColor(EditText.colour("yellow")) : w)
        }
        let base = line.font(.system(size: 26, weight: .black)).multilineTextAlignment(.center).frame(maxWidth: 330)
        switch item.style {
        case "Box":
            base.foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case "Plain":
            base.foregroundStyle(.white).shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        default:
            // Pop: the word being said in a yellow box of its own, the rest white
            HStack(spacing: 5) {
                ForEach(words.indices, id: \.self) { i in
                    Text(words[i].text).font(.system(size: 26, weight: .black))
                        .foregroundStyle(i == lit ? Color.black : Color.white)
                        .padding(.horizontal, i == lit ? 4 : 0)
                        .background(i == lit ? EditText.colour("yellow") : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .shadow(color: i == lit ? .clear : .black.opacity(0.8), radius: 3, y: 1)
                }
            }
            .frame(maxWidth: 360)
        }
    }
}

/// Whether a one-time answer has been given (the speech handler can be called more than once).
private final class Once: @unchecked Sendable { var done = false }

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
        for item in items {
            switch item.kind {
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

    /// Captions from what's said in the edit (Stage B): its sound as heard, made into words on the phone itself
    /// (nothing sent, nothing paid), each with when it's said, grouped a few words a caption.
    static func captions(_ clips: [Clip], soundOf: UUID?) async throws -> [EditText] {
        struct Problem: LocalizedError { let errorDescription: String? }
        let ok = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard ok == .authorized else { throw Problem(errorDescription: "Captions need Speech Recognition: turn it on in Settings › Cheat Days.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw Problem(errorDescription: "Captions are made on the phone itself, and this phone can't do that in your language yet.")
        }
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
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let said: SFTranscription = try await withCheckedThrowingContinuation { c in
            let once = Once()
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !once.done else { return }
                if let result, result.isFinal { once.done = true; c.resume(returning: result.bestTranscription) }
                else if let error { once.done = true; c.resume(throwing: error) }
            }
        }
        // a caption: up to three words, broken at a pause or the end of a sentence
        var out: [EditText] = []
        var group: [SFTranscriptionSegment] = []
        func close() {
            guard let first = group.first, let last = group.last else { return }
            let words = group.map { EditText.Word(text: $0.substring, at: $0.timestamp) }
            out.append(EditText(kind: "caption", text: words.map(\.text).joined(separator: " "), style: "Pop", x: 0.5, y: 0.76,
                                from: first.timestamp, to: last.timestamp + max(0.3, last.duration), words: words))
            group = []
        }
        for seg in said.segments {
            if let last = group.last, seg.timestamp - (last.timestamp + last.duration) > 0.6 { close() }
            group.append(seg)
            let ends = seg.substring.last.map { ".!?,".contains($0) } ?? false
            if group.count >= 3 || ends { close() }
        }
        close()
        // each held until the next one comes, if that's soon
        for i in out.indices.dropLast() where out[i + 1].from - out[i].to < 0.8 { out[i].to = out[i + 1].from }
        if out.isEmpty { throw Problem(errorDescription: "No words were heard in this edit.") }
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
    var to: Double { from + length }

    /// Where it is `t` seconds into the video.
    func place(at t: Double) -> MoveKey {
        MoveKey.value(keys, at: t - from, base: MoveKey(at: 0, x: x, y: y, size: size, opacity: opacity))
    }
}
