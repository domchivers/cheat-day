import Foundation

/// The parts of a caption that each have a colour and an opacity of their own (design/caption-colour-mockup.html).
enum CaptionPart: String, CaseIterable {
    case lit, words, box

    var name: String {
        switch self {
        case .lit: return "Word being said"
        case .words: return "Words"
        case .box: return "Box"
        }
    }
}

extension EditText {
    /// Another's look and place: Apply to all, and captions made new among others.
    mutating func takeLook(from o: EditText) {
        takeColours(from: o)
        style = o.style
        x = o.x; y = o.y; size = o.size
    }

    mutating func takeColours(from o: EditText) {
        highlight = o.highlight; litAlpha = o.litAlpha
        wordColour = o.wordColour; wordAlpha = o.wordAlpha
        boxColour = o.boxColour; boxAlpha = o.boxAlpha
    }

    func hex(of part: CaptionPart) -> String {
        switch part {
        case .lit:
            let name: String = highlight ?? "yellow"
            return ColourCode.hex(named: name == "none" ? "yellow" : name)
        case .words: return ColourCode.hex(named: wordColour ?? "white")
        case .box: return ColourCode.hex(named: boxColour ?? "black")
        }
    }

    func alpha(of part: CaptionPart) -> Double {
        switch part {
        case .lit: return litAlpha ?? 1
        case .words: return wordAlpha ?? 1
        case .box: return boxAlpha ?? 0.7
        }
    }

    mutating func paint(_ part: CaptionPart, hex: String) {
        switch part {
        case .lit: highlight = hex
        case .words: wordColour = hex
        case .box:
            boxColour = hex
            if boxAlpha == 0 { boxAlpha = nil }   // (back from no box)
        }
    }

    mutating func fade(_ part: CaptionPart, to alpha: Double) {
        switch part {
        case .lit: litAlpha = alpha
        case .words: wordAlpha = alpha
        case .box: boxAlpha = alpha
        }
    }

    /// No colour for a part: no highlight, no box.
    mutating func clear(_ part: CaptionPart) {
        switch part {
        case .lit: highlight = "none"
        case .words: break
        case .box: boxAlpha = 0
        }
    }

    func isClear(_ part: CaptionPart) -> Bool {
        switch part {
        case .lit: return highlight == "none"
        case .words: return false
        case .box: return boxAlpha == 0
        }
    }
}

/// Colours as "#RRGGBB", and as the wheel has them.
enum ColourCode {
    struct HSB: Equatable {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    /// The names captions and text had before they had hexes.
    static func hex(named name: String) -> String {
        if name.hasPrefix("#") { return name.uppercased() }
        switch name {
        case "yellow": return "#FFCC33"
        case "black": return "#000000"
        case "red": return "#FF595E"
        case "green": return "#5CD18F"
        case "blue": return "#5CA8F2"
        default: return "#FFFFFF"
        }
    }

    static func make(red: Double, green: Double, blue: Double) -> String {
        "#" + two(red) + two(green) + two(blue)
    }

    private static func two(_ v: Double) -> String {
        let byte: Int = Int((min(1, max(0, v)) * 255).rounded())
        return String(format: "%02X", byte)
    }

    /// What's typed, as a colour, once it's a whole one.
    static func typed(_ text: String) -> String? {
        let code: String = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "").uppercased()
        let digits: Set<Character> = Set("0123456789ABCDEF")
        guard code.count == 6, code.allSatisfy({ (c: Character) -> Bool in digits.contains(c) }) else { return nil }
        return "#" + code
    }

    static func hsb(_ hex: String) -> HSB {
        let v: UInt64 = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFFFFF
        let red: Double = Double((v >> 16) & 0xFF) / 255
        let green: Double = Double((v >> 8) & 0xFF) / 255
        let blue: Double = Double(v & 0xFF) / 255
        let high: Double = max(red, max(green, blue))
        let low: Double = min(red, min(green, blue))
        let gap: Double = high - low
        var sector = 0.0
        if gap > 0 {
            if high == red { sector = (green - blue) / gap }
            else if high == green { sector = (blue - red) / gap + 2 }
            else { sector = (red - green) / gap + 4 }
        }
        if sector < 0 { sector += 6 }
        return HSB(hue: sector / 6, saturation: high > 0 ? gap / high : 0, brightness: high)
    }

    static func hex(_ c: HSB) -> String {
        let h: Double = (c.hue - c.hue.rounded(.down)) * 6
        let sector: Int = Int(h) % 6
        let f: Double = h - h.rounded(.down)
        let v: Double = c.brightness
        let p: Double = v * (1 - c.saturation)
        let q: Double = v * (1 - c.saturation * f)
        let t: Double = v * (1 - c.saturation * (1 - f))
        switch sector {
        case 0: return make(red: v, green: t, blue: p)
        case 1: return make(red: q, green: v, blue: p)
        case 2: return make(red: p, green: v, blue: t)
        case 3: return make(red: p, green: q, blue: v)
        case 4: return make(red: t, green: p, blue: v)
        default: return make(red: v, green: p, blue: q)
        }
    }
}

/// Something dragged on the video: where it goes, held on the middle when it's near it.
extension EditText {
    /// A caption's words retyped: the same count keep their moments; more or fewer are spread over its time, still tied
    /// to the clip or voiceover that said it and spread over the stretch of it the old ones were (23 Nov: made afresh
    /// with no tie, the caption stayed put when its voiceover was moved).
    static func retyped(_ old: [Word], parts: [String], from: Double, to: Double) -> [Word] {
        if parts.count == old.count {
            return zip(parts, old).map { (p: (String, Word)) -> Word in
                var w: Word = p.1
                w.text = p.0
                return w
            }
        }
        guard !parts.isEmpty else { return old }
        let n: Double = Double(parts.count)
        let step: Double = (to - from) / n
        let tied: Bool = !old.isEmpty && old.allSatisfy { (w: Word) -> Bool in w.src != nil }
        let low: Double = old.first?.src ?? 0, high: Double = old.last?.src ?? 0
        return parts.indices.map { (j: Int) -> Word in
            var w = Word(text: parts[j], at: from + step * Double(j))
            if tied {
                w.clip = old.first?.clip
                w.file = old.first?.file
                w.src = low + (high - low) * Double(j) / max(n - 1, 1)
            }
            return w
        }
    }
}

/// Which caption shows as the one picked.
enum CaptionFocus {
    /// Edit captions' white row: the one being said as it plays; paused, the one picked while the line's still in it.
    static func row(picked: EditText?, saying: UUID?, at t: Double, playing: Bool) -> UUID? {
        guard !playing, let picked, t >= picked.from, t < picked.to else { return saying }
        return picked.id
    }

    /// The caption held up by itself on the paused video: the one picked, unless the line's gone on into another.
    static func held(picked: UUID?, in texts: [EditText], at t: Double, playing: Bool) -> UUID? {
        guard !playing, let picked else { return nil }
        let shown: [EditText] = texts.filter { (x: EditText) -> Bool in x.kind == "caption" && x.hidden != true }
        guard let mine = shown.first(where: { (x: EditText) -> Bool in x.id == picked }) else { return nil }
        if t >= mine.from && t < mine.to { return picked }
        let another: Bool = shown.contains { (x: EditText) -> Bool in t >= x.from && t < x.to }
        return another ? nil : picked
    }
}

enum OverlayDrag {
    struct Place: Equatable {
        var x: Double
        var y: Double
        var middleX: Bool
        var middleY: Bool
    }

    static let reach = 6.0   // points of the screen

    static func place(fromX: Double, fromY: Double, dx: Double, dy: Double, width: Double, height: Double) -> Place {
        let w: Double = max(width, 1), h: Double = max(height, 1)
        let x: Double = min(0.95, max(0.05, fromX + dx / w))
        let y: Double = min(0.95, max(0.05, fromY + dy / h))
        let midX: Bool = abs(x - 0.5) * w <= reach
        let midY: Bool = abs(y - 0.5) * h <= reach
        return Place(x: midX ? 0.5 : x, y: midY ? 0.5 : y, middleX: midX, middleY: midY)
    }
}
