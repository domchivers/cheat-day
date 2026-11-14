import CoreImage
import ImageIO
import CoreImage.CIFilterBuiltins
import SwiftUI

/// How a story's text, stickers and drawing look, shared by the editor and the viewer so a story looks the same on
/// every phone. Everything is sized for a 390-point-wide story and scaled to the one it's shown in; positions are
/// fractions of the story's width and height.
enum StoryArt {
    static let design: CGFloat = 390
    static let aspect: CGFloat = 9.0 / 16.0

    static let fonts = ["classic", "modern", "serif", "neon", "type"]
    static let fontNames = ["classic": "Classic", "modern": "Modern", "serif": "Serif", "neon": "Neon", "type": "Type"]
    static let colors = ["FFFFFF", "000000", "8CC4FF", "C4A1FF", "F4A0A6", "F2C66B", "5CD18F", "FF6B3D"]

    static func font(_ name: String, _ size: CGFloat) -> Font {
        switch name {
        case "modern": return .system(size: size, weight: .black, design: .default).width(.condensed)
        case "serif": return .system(size: size, weight: .bold, design: .serif).italic()
        case "neon": return .system(size: size, weight: .semibold, design: .rounded)
        case "type": return .system(size: size * 0.9, weight: .medium, design: .monospaced)
        default: return .system(size: size, weight: .heavy, design: .rounded)
        }
    }

    static func color(_ hex: String) -> Color {
        let v = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFFFFF
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    /// Text on a highlight: dark text on light colours, white on dark.
    static func onColor(_ hex: String) -> Color {
        let v = UInt64(hex, radix: 16) ?? 0xFFFFFF
        let l = 0.299 * Double((v >> 16) & 0xFF) + 0.587 * Double((v >> 8) & 0xFF) + 0.114 * Double(v & 0xFF)
        return l > 150 ? .black : .white
    }

    // MARK: filters

    static let filters = ["Normal", "Warm", "Cool", "Mono", "Vivid", "Fade", "Pop", "Noir"]
    static let context = CIContext()

    /// What Adjust can change, each with the letter it's written down as: a look is a filter's name and then any of
    /// these that aren't at rest, as in "Warm;b=20;t=-4". Written into the one string, the photo, the playing clip
    /// and the exported video all get them without being told separately.
    static let tunes: [(String, String, String, Double, Double)] = [
        ("b", "Brightness", "sun.max", -100, 100), ("c", "Contrast", "circle.lefthalf.filled", -100, 100),
        ("w", "Warmth", "thermometer.medium", -100, 100), ("s", "Saturation", "drop", -100, 100),
        ("sh", "Sharpen", "triangle", 0, 100), ("v", "Vignette", "circle.dashed", 0, 100),
        ("t", "Straighten", "rotate.right", -15, 15)]

    static func look(_ filter: String, _ tune: [String: Double]) -> String {
        filter + tune.filter { $0.value != 0 }.sorted { $0.key < $1.key }.map { ";\($0.key)=" + String(format: "%.1f", $0.value) }.joined()
    }

    /// A picture through a look. `frame` is the picture's own edges, for when it comes in stretched out for ever
    /// (a video's frames do): straightening and the vignette turn about its middle.
    static func filtered(_ input: CIImage, _ look: String, frame: CGRect? = nil) -> CIImage {
        let parts = look.split(separator: ";").map(String.init)
        var img = named(input, parts.first ?? "Normal")
        guard parts.count > 1 else { return img }
        var t: [String: Double] = [:]
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=")
            if kv.count == 2, let v = Double(kv[1]) { t[String(kv[0])] = v }
        }
        let ext = frame ?? input.extent
        let whole = !ext.isInfinite && ext.width > 1 && ext.height > 1
        if let deg = t["t"], deg != 0, whole {
            // tilted about its middle and grown just enough that no corner comes up empty
            let a: Double = -deg * Double.pi / 180, long = Double(max(ext.width / ext.height, ext.height / ext.width))
            let grow = CGFloat(cos(abs(a)) + long * sin(abs(a)))
            let turn = CGAffineTransform(translationX: ext.midX, y: ext.midY).rotated(by: CGFloat(a)).scaledBy(x: grow, y: grow).translatedBy(x: -ext.midX, y: -ext.midY)
            img = img.transformed(by: turn)
            if frame == nil { img = img.cropped(to: ext) }
        }
        if let b = t["b"], b != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: b / 100 * 1.2]) }
        if (t["c"] ?? 0) != 0 || (t["s"] ?? 0) != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + (t["c"] ?? 0) / 100 * 0.3, kCIInputSaturationKey: 1 + (t["s"] ?? 0) / 100])
        }
        if let w = t["w"], w != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 6500 - w / 100 * 1800, y: 0)
            img = f.outputImage ?? img
        }
        if let sh = t["sh"], sh > 0 { img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sh / 100 * 1.5]) }
        if let v = t["v"], v > 0, whole {
            img = img.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
                kCIInputRadiusKey: hypot(ext.width, ext.height) / 2 * 0.72, kCIInputIntensityKey: v / 100, "inputFalloff": 0.5])
        }
        return img
    }

    private static func named(_ input: CIImage, _ name: String) -> CIImage {
        switch name {
        case "Warm":
            let f = CIFilter.temperatureAndTint(); f.inputImage = input
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 5200, y: 0)
            return (f.outputImage ?? input).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.12])
        case "Cool":
            let f = CIFilter.temperatureAndTint(); f.inputImage = input
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 8200, y: 0)
            return f.outputImage ?? input
        case "Mono": return input.applyingFilter("CIPhotoEffectMono")
        case "Noir": return input.applyingFilter("CIPhotoEffectNoir")
        case "Vivid": return input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4, kCIInputContrastKey: 1.08])
        case "Fade": return input.applyingFilter("CIPhotoEffectFade")
        case "Pop":
            let v = CIFilter.vibrance(); v.inputImage = input; v.amount = 0.8
            return (v.outputImage ?? input).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12, kCIInputBrightnessKey: 0.02])
        default: return input
        }
    }

    static func filtered(_ image: UIImage, _ name: String) -> UIImage {
        guard name != "Normal", let ci = CIImage(image: image) else { return image }
        let out = filtered(ci, name)
        guard let cg = context.createCGImage(out, from: ci.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// One thing placed on a story, drawn at the 390-point design size.
struct StoryItem: View {
    let o: JSON
    var votes: (a: Int, b: Int, mine: Int?)? = nil
    var vote: ((Int) -> Void)? = nil
    /// A question sticker someone's watching: tapping it lets them answer (it goes to the poster's chat).
    var answer: (() -> Void)? = nil

    var body: some View {
        if str(o["type"]) == "text" { text }   // text wraps at its own width; everything else keeps its size, never squeezed
        else { sticker.fixedSize() }
    }

    /// A picture of your own stuck on the story, in a white frame. While it's being made the picture is on the phone
    /// (PhotoStickers); once posted it's fetched from where it was uploaded.
    private var photo: some View {
        let w = num(o["w"]) ?? 3, h = num(o["h"]) ?? 4
        let width: CGFloat = 190, height = max(90, min(340, width * h / max(1, w)))
        return ZStack {
            Color(white: 0.15)
            if let img = PhotoStickers.local[str(o["local"])] { Image(uiImage: img).resizable().scaledToFill() }
            else if !str(o["url"]).isEmpty { FeedPhoto(src: str(o["url"]), fill: true) }
        }
        .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 4))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
    }

    @ViewBuilder private var sticker: some View {
        switch str(o["type"]) {
        case "text": text
        case "food": food
        case "macros": macros
        case "streak": pill("🔥", "\(Int(num(o["days"]) ?? 0))-day streak", Color(red: 1, green: 0.54, blue: 0.16), .white)
        case "left": pill("🎯", "\(Fmt.int(num(o["kcal"]) ?? 0)) kcal left today", .white.opacity(0.18), .white, glass: true)
        case "workout": workout
        case "poll": poll
        case "time": Text(str(o["text"])).font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 6)
        case "place": pill("📍", str(o["text"]), .white, .black)
        case "mention": Text("@" + str(o["name"])).font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(StoryArt.color("8CC4FF"))
            .padding(.horizontal, 14).padding(.vertical, 8).background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case "emoji": Text(str(o["text"])).font(.system(size: 90))
        case "sticker3d": Image("sticker-" + str(o["code"])).resizable().interpolation(.high).scaledToFit().frame(width: 130, height: 130)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 5)
        case "photo": photo
        case "gif":
            let w = num(o["w"]) ?? 200, h = num(o["h"]) ?? 200
            AnimatedGIF(url: str(o["url"])).frame(width: 170, height: 170 * h / max(1, w))
        case "ring": ring
        case "steps": pill("👟", "\(Fmt.int(num(o["steps"]) ?? 0)) steps", .white, .black)
        case "badge": badge
        case "rank": rank
        case "cheat": cheat
        case "question": question
        case "hashtag": Text("#" + str(o["text"])).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(StoryArt.color("C4A1FF"))
            .padding(.horizontal, 14).padding(.vertical, 8).background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        default: EmptyView()
        }
    }

    private var text: some View {
        let size = CGFloat(num(o["size"]) ?? 30), c = str(o["color"]).isEmpty ? "FFFFFF" : str(o["color"]), fontName = str(o["font"])
        let highlight = o["bg"] as? Bool ?? false, glow = (o["glow"] as? Bool ?? false) || fontName == "neon"
        let align: TextAlignment = str(o["align"]) == "left" ? .leading : str(o["align"]) == "right" ? .trailing : .center
        return Text(str(o["text"])).font(StoryArt.font(fontName, size)).multilineTextAlignment(align)
            .foregroundStyle(highlight ? StoryArt.onColor(c) : StoryArt.color(c))
            .padding(.horizontal, highlight ? 12 : 0).padding(.vertical, highlight ? 6 : 0)
            .background { if highlight { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StoryArt.color(c)) } }
            .shadow(color: glow ? StoryArt.color(c).opacity(0.9) : (highlight ? .clear : .black.opacity(0.45)), radius: glow ? 10 : 4)
            .shadow(color: glow ? StoryArt.color(c).opacity(0.6) : .clear, radius: glow ? 20 : 0)
            .frame(maxWidth: 330)
    }

    /// Three looks, tapped through in the editor: a white card, glass, bold.
    private var food: some View {
        let style = Int(num(o["style"]) ?? 0)
        let name = str(o["name"]), kcal = Fmt.int(num(o["kcal"]) ?? 0), p = num(o["p"]).map { "\(Int($0)) g protein" }
        return VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: style == 2 ? 20 : 16, weight: .heavy, design: .rounded)).lineLimit(2)
            HStack(spacing: 6) {
                Text("\(kcal) kcal")
                if let p { Text(p).foregroundStyle(style == 0 ? Color(red: 0.12, green: 0.6, blue: 0.34) : StoryArt.color("5CD18F")) }
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .foregroundStyle(style == 0 ? .black : .white)
        .padding(.horizontal, 15).padding(.vertical, 11)
        .background {
            switch style {
            case 1: RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.38))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
            case 2: RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LinearGradient(colors: [Color(red: 0.11, green: 0.18, blue: 0.32), Color(red: 0.17, green: 0.13, blue: 0.31)], startPoint: .topLeading, endPoint: .bottomTrailing))
            default: RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .frame(maxWidth: 260)
    }

    private var macros: some View {
        HStack(spacing: 14) {
            ForEach([("P", "p", "5CD18F"), ("C", "c", "8CC4FF"), ("F", "f", "F2C66B")], id: \.0) { l in
                VStack(spacing: 1) {
                    Text("\(Int(num(o[l.1]) ?? 0))g").font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(StoryArt.color(l.2)).lineLimit(1)
                    Text(l.0 == "P" ? "protein" : l.0 == "C" ? "carbs" : "fat").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            VStack(spacing: 1) {
                Text(Fmt.int(num(o["kcal"]) ?? 0)).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                Text("kcal").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(LinearGradient(colors: [Color(red: 0.11, green: 0.18, blue: 0.32), Color(red: 0.17, green: 0.13, blue: 0.31)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }

    private var workout: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("🏋️ " + str(o["name"])).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(1)
            Text("\(Int(num(o["minutes"]) ?? 0)) min" + (str(o["detail"]).isEmpty ? "" : " · " + str(o["detail"]))).font(.system(size: 13, weight: .bold)).foregroundStyle(StoryArt.color("A9B8E6"))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(LinearGradient(colors: [Color(red: 0.11, green: 0.18, blue: 0.32), Color(red: 0.17, green: 0.13, blue: 0.31)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }

    /// A question and two answers. Once you've voted (or it's yours), the split shows on each answer.
    private var poll: some View {
        let a = str(o["a"]).isEmpty ? "Yes" : str(o["a"]), b = str(o["b"]).isEmpty ? "No" : str(o["b"])
        let total = (votes?.a ?? 0) + (votes?.b ?? 0)
        let showing = votes?.mine != nil || (votes != nil && vote == nil)
        return VStack(spacing: 10) {
            Text(str(o["q"])).font(.system(size: 19, weight: .heavy, design: .rounded)).foregroundStyle(.black).multilineTextAlignment(.center).lineLimit(3)
            HStack(spacing: 8) {
                answer(a, 0, count: votes?.a ?? 0, total: total, showing: showing)
                answer(b, 1, count: votes?.b ?? 0, total: total, showing: showing)
            }
        }
        .padding(14).frame(width: 270)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }

    private func answer(_ title: String, _ i: Int, count: Int, total: Int, showing: Bool) -> some View {
        let pct = total > 0 ? Double(count) / Double(total) : 0, mine = votes?.mine == i
        return Button { vote?(i) } label: {
            ZStack(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(Color(white: 0.92))
                    if showing { Capsule().fill(mine ? StoryArt.color("8CC4FF") : Color(white: 0.8)).frame(width: max(14, g.size.width * pct)) }
                }
                HStack {
                    Text(title).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(.black).lineLimit(1)
                    Spacer(minLength: 2)
                    if showing { Text("\(Int((pct * 100).rounded()))%").font(.system(size: 13, weight: .heavy)).foregroundStyle(.black.opacity(0.7)) }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 40)
        }
        .buttonStyle(.plain)
        // not .disabled: that greys the words, so a poll looked washed out in the editor, on your own story and once
        // you'd voted. It just stops taking taps.
        .allowsHitTesting(vote != nil && votes?.mine == nil)
    }

    /// Eaten against the day's budget, as a ring.
    private var ring: some View {
        let eaten = num(o["eaten"]) ?? 0, budget = max(1, num(o["budget"]) ?? 1), f = min(1, eaten / budget)
        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 9)
                Circle().trim(from: 0, to: f).stroke(AngularGradient(colors: [StoryArt.color("8CC4FF"), StoryArt.color("C4A1FF"), StoryArt.color("8CC4FF")], center: .center),
                                                   style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int((f * 100).rounded()))%").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Fmt.int(eaten)) kcal").font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                Text("of \(Fmt.int(budget)) today").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(LinearGradient(colors: [Color(red: 0.11, green: 0.18, blue: 0.32), Color(red: 0.17, green: 0.13, blue: 0.31)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }

    private var badge: some View {
        let b = Badge.all.first { $0.id == str(o["id"]) }
        return VStack(spacing: 6) {
            if let b { BadgeCoin(badge: b, size: 86) }
            Text(b?.name ?? "Badge").font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5).background(.black.opacity(0.45), in: Capsule())
        }
    }

    private var rank: some View {
        let r = Rank(level: max(1, Int(num(o["level"]) ?? 1)))
        return HStack(spacing: 10) {
            RankBadge(rank: r, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ranked").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white.opacity(0.7)).textCase(.uppercase)
                Text(r.name).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(r.color)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cheat: some View {
        let d = Int(num(o["days"]) ?? 0)
        return VStack(spacing: 2) {
            Text(d == 0 ? "IT'S CHEAT DAY" : "CHEAT DAY IN").font(.system(size: 13, weight: .black)).tracking(1).foregroundStyle(.white.opacity(0.85))
            if d > 0 { Text("\(d) \(d == 1 ? "day" : "days")").font(.system(size: 34, weight: .black, design: .rounded)).foregroundStyle(.white) }
            else { Text("🎉").font(.system(size: 34)) }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.35), Color(red: 0.85, green: 0.3, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
    }

    /// "Ask me anything": friends tap it and their answer comes to you in Messages.
    private var question: some View {
        VStack(spacing: 10) {
            Text(str(o["q"]).isEmpty ? "Ask me anything" : str(o["q"])).font(.system(size: 19, weight: .heavy, design: .rounded)).foregroundStyle(.white).multilineTextAlignment(.center)
            Button { answer?() } label: {
                Text("Type something…").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black.opacity(0.45))
                    .frame(maxWidth: .infinity).padding(.vertical, 11).background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain).allowsHitTesting(answer != nil)   // not .disabled, which greys its words (see the poll's answers)
        }
        .padding(14).frame(width: 260)
        .background(LinearGradient(colors: [StoryArt.color("8CC4FF"), StoryArt.color("C4A1FF")], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
    }

    private func pill(_ icon: String, _ text: String, _ bg: Color, _ fg: Color, glass: Bool = false) -> some View {
        HStack(spacing: 6) { Text(icon); Text(text) }
            .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(fg).lineLimit(1)
            .padding(.horizontal, 15).padding(.vertical, 10)
            .background {
                if glass { Capsule().fill(Color.black.opacity(0.38)).overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1)) } else { Capsule().fill(bg) }
            }
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}

/// Drawn lines: pen, marker, neon and eraser, as fractions of the story so they scale with it.
struct StoryDrawing: View {
    let strokes: [JSON]
    var body: some View {
        Canvas { ctx, size in
            for s in strokes {
                let pts = ((s["points"] as? [Any]) ?? []).compactMap { p -> CGPoint? in
                    guard let a = p as? [Any], a.count == 2, let x = num(a[0]), let y = num(a[1]) else { return nil }
                    return CGPoint(x: x * size.width, y: y * size.height)
                }
                guard let first = pts.first else { continue }
                var path = Path(); path.move(to: first)
                if pts.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
                for p in pts.dropFirst() { path.addLine(to: p) }
                let kind = str(s["kind"]), w = (num(s["width"]) ?? 0.015) * size.width
                let c = StoryArt.color(str(s["color"]).isEmpty ? "FFFFFF" : str(s["color"]))
                let style = StrokeStyle(lineWidth: kind == "marker" ? w * 2.2 : w, lineCap: kind == "marker" ? .square : .round, lineJoin: .round)
                switch kind {
                case "eraser":
                    ctx.blendMode = .clear; ctx.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: w * 2.5, lineCap: .round, lineJoin: .round)); ctx.blendMode = .normal
                case "neon":
                    var glow = ctx; glow.addFilter(.shadow(color: c, radius: w * 1.4))
                    glow.stroke(path, with: .color(c), style: style)
                    ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: w * 0.45, lineCap: .round, lineJoin: .round))
                case "marker": ctx.stroke(path, with: .color(c.opacity(0.55)), style: style)
                default: ctx.stroke(path, with: .color(c), style: style)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Everything placed on a story, positioned and scaled for the size it's shown at. Polls can be voted on.
struct StoryLayer: View {
    let items: [JSON]
    var story: String? = nil   // the story, for poll votes; nil in the editor
    private var stories: Stories { Stories.shared }

    var body: some View {
        GeometryReader { g in
            let k = g.size.width / StoryArt.design
            ZStack {
                ForEach(items.indices, id: \.self) { i in
                    let o = items[i]
                    if str(o["type"]) == "drawing" { StoryDrawing(strokes: list(o["strokes"])) }
                    else {
                        StoryItem(o: o, votes: poll(o), vote: voteAction(o), answer: answerAction(o))
                            .scaleEffect((num(o["scale"]) ?? 1) * k)
                            .rotationEffect(.degrees(num(o["rotation"]) ?? 0))
                            .position(x: (num(o["x"]) ?? 0.5) * g.size.width, y: (num(o["y"]) ?? 0.5) * g.size.height)
                            .allowsHitTesting((str(o["type"]) == "poll" || str(o["type"]) == "question") && story != nil)
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .alert(str(asking?["q"]).isEmpty ? "Ask me anything" : str(asking?["q"]), isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            TextField("Your answer", text: $reply)
            Button("Send") {
                let q = str(asking?["q"]), t = reply.trimmingCharacters(in: .whitespacesAndNewlines), to = story.map { stories.owner($0) } ?? ""
                reply = ""
                if !t.isEmpty, !to.isEmpty { Task { await Messages.shared.send(to: to, text: "Answering \"\(q.isEmpty ? "Ask me anything" : q)\": \(t)") } }
            }
            Button("Cancel", role: .cancel) { reply = "" }
        } message: { Text("It goes to their messages.") }
    }

    private func poll(_ o: JSON) -> (a: Int, b: Int, mine: Int?)? {
        guard str(o["type"]) == "poll", let story else { return nil }
        return stories.tally(story, str(o["id"]))
    }
    @State private var asking: JSON?
    @State private var reply = ""
    private func answerAction(_ o: JSON) -> (() -> Void)? {
        guard str(o["type"]) == "question", let story, stories.owner(story) != stories.me else { return nil }
        return { asking = o }
    }

    private func voteAction(_ o: JSON) -> ((Int) -> Void)? {
        guard str(o["type"]) == "poll", let story, stories.owner(story) != stories.me else { return nil }
        return { choice in Task { await stories.vote(story, poll: str(o["id"]), choice) } }
    }
}

/// An animated GIF from GIPHY, kept once loaded. SwiftUI's Image doesn't move, so this is a UIImageView playing the
/// frames ImageIO reads out of it.
struct AnimatedGIF: UIViewRepresentable {
    let url: String
    /// The largest side to decode frames at: the tray's small tiles needn't decode every frame full size.
    var maxPixel: Int = 400
    private static let cache = NSCache<NSString, UIImage>()

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView(); v.contentMode = .scaleAspectFit; v.clipsToBounds = true
        v.isUserInteractionEnabled = false   // never takes a touch from the button or sticker it sits in
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        load(into: v)
        return v
    }
    func updateUIView(_ v: UIImageView, context: Context) { if v.accessibilityIdentifier != url { load(into: v) } }

    private func load(into v: UIImageView) {
        v.accessibilityIdentifier = url
        let key = "\(url)|\(maxPixel)"
        if let kept = Self.cache.object(forKey: key as NSString) { v.image = kept; v.startAnimating(); return }
        guard let u = URL(string: url) else { return }
        let want = url, px = maxPixel
        Task.detached(priority: .userInitiated) {
            guard let (d, _) = try? await URLSession.shared.data(from: u), let img = Self.animated(d, maxPixel: px) else { return }
            Self.cache.setObject(img, forKey: key as NSString)
            await MainActor.run { if v.accessibilityIdentifier == want { v.image = img; v.startAnimating() } }
        }
    }

    static func animated(_ data: Data, maxPixel: Int = 400) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = [], total = 0.0
        for i in 0..<n {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            total += max(0.02, delay)
            frames.append(UIImage(cgImage: cg))
        }
        return UIImage.animatedImage(with: frames, duration: total)
    }
}

/// The 3D stickers built into the app (Microsoft's Fluent Emoji, MIT licence): tools/fluent3d.py.
enum BuiltInStickers {
    static let all: [(code: String, emoji: String)] = {
        guard let url = Bundle.main.url(forResource: "stickers", withExtension: "json"), let d = try? Data(contentsOf: url),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [[String: String]] else { return [] }
        return rows.compactMap { r in r["code"].map { ($0, r["emoji"] ?? "") } }
    }()
}

/// Pictures stuck on a story that's still being made, by the name their sticker carries ("local"). They're uploaded
/// when the story is shared.
@MainActor enum PhotoStickers {
    static var local: [String: UIImage] = [:]

    /// The picture made small enough for a sticker (900 pixels on its long side), kept, and its name.
    static func keep(_ img: UIImage) -> String {
        let long = max(img.size.width, img.size.height), k = min(1, 900 / max(1, long))
        let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        local[id] = small
        return id
    }
}
