import UIKit
import Vision

/// Reads a nutrition table on the phone, with no AI: the iPhone's own text recognition finds the words and numbers,
/// then plain rules pick out energy, protein, carbs, fat and the serving size, choosing the per-100 column on UK and
/// Australian layouts. Quicker than the AI, works offline, and copies the printed numbers exactly. When the numbers
/// don't add up, it gives up and the AI reads the photo instead.
enum NutritionTable {
    /// A piece of recognised text and where it sat (Vision's 0–1 coordinates, origin bottom left).
    struct Piece { let text: String; let box: CGRect }

    struct Parsed: Equatable {
        var kcal100: Double
        var p100: Double?
        var c100: Double?
        var f100: Double?
        var servingSize: Double?
        var kcalServing: Double?
        var unit = "g"
        var name = ""
    }

    // MARK: reading the text

    static func recognize(_ image: UIImage) async -> [Piece] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { cont in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            let finish = { (pieces: [Piece]) in if !once.done { once.done = true; cont.resume(returning: pieces) } }   // never resume twice
            let req = VNRecognizeTextRequest { r, _ in
                let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
                finish(obs.compactMap { o in o.topCandidates(1).first.map { Piece(text: $0.string, box: o.boundingBox) } })
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false   // numbers and units, not prose
            req.recognitionLanguages = ["en-GB", "en-AU", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([req]) } catch { finish([]) }
            }
        }
    }

    /// The whole job: the photo in, a food item out, or nil to let the AI try.
    static func read(_ image: UIImage) async -> JSON? {
        let pieces = await recognize(image)
        guard let p = parse(pieces) else { return nil }
        var item: JSON = ["source": "label", "name": p.name, "unit": p.unit, "kcalPer100": p.kcal100.rounded(), "askName": p.name.isEmpty]
        if p.p100 != nil || p.c100 != nil || p.f100 != nil { item["p100"] = p.p100 ?? 0; item["c100"] = p.c100 ?? 0; item["f100"] = p.f100 ?? 0 }
        if let s = p.servingSize { item["servingSize"] = s; item["kcalPerServing"] = (p.kcalServing ?? p.kcal100 * s / 100).rounded() }
        return item
    }

    // MARK: the rules

    private struct Cell { let text: String; let x: Double }
    private struct Row { var cells: [Cell]; var text: String { cells.map(\.text).joined(separator: " ") } }

    /// Pieces at the same height make a row, top to bottom, each read left to right.
    private static func rows(_ pieces: [Piece]) -> [Row] {
        let sorted = pieces.sorted { $0.box.midY > $1.box.midY }
        var out: [(y: Double, h: Double, row: Row)] = []
        for p in sorted {
            let cell = Cell(text: p.text, x: p.box.midX)
            if let i = out.firstIndex(where: { abs($0.y - p.box.midY) < max($0.h, p.box.height) * 0.6 }) { out[i].row.cells.append(cell) }
            else { out.append((p.box.midY, p.box.height, Row(cells: [cell]))) }
        }
        return out.map { var r = $0.row; r.cells.sort { $0.x < $1.x }; return r }
    }

    private static let number = try! NSRegularExpression(pattern: #"(<\s*)?(\d+(?:[.,]\d+)?)\s*(kcal|kj|cal|mg|g|ml)?"#, options: .caseInsensitive)

    /// The numbers in a row, in reading order, with their unit and position.
    private static func numbers(_ row: Row) -> [(v: Double, unit: String, x: Double)] {
        var out: [(Double, String, Double)] = []
        for c in row.cells {
            let ns = c.text as NSString
            for m in number.matches(in: c.text, range: NSRange(location: 0, length: ns.length)) {
                guard let v = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ",", with: ".")) else { continue }
                let unit = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3)).lowercased()
                out.append((m.range(at: 1).location == NSNotFound ? v : v / 2, unit, c.x))   // "<0.5g" counts as 0.25
            }
        }
        return out.map { (v: $0.0, unit: $0.1, x: $0.2) }
    }

    static func parse(_ pieces: [Piece]) -> Parsed? {
        let rs = rows(pieces)
        let all = rs.map { $0.text.lowercased() }.joined(separator: "\n")

        // which column is per 100: from the header row's position, else its order, else the label's style
        let header = rs.first { r in let t = r.text.lowercased(); return t.range(of: #"100\s*(g|ml)"#, options: .regularExpression) != nil }
        var col100: Double?, colServe: Double?
        var hundredFirst = true
        if let h = header {
            for c in h.cells {
                let t = c.text.lowercased()
                if t.range(of: #"100\s*(g|ml)"#, options: .regularExpression) != nil { col100 = c.x }
                else if t.contains("serv") || t.contains("portion") || t.range(of: #"per\s+\d"#, options: .regularExpression) != nil || t.contains("each") { colServe = c.x }
            }
            let ht = h.text.lowercased()
            if let a = ht.range(of: #"100\s*(g|ml)"#, options: .regularExpression), let b = ht.range(of: #"serv|portion|each"#, options: .regularExpression) { hundredFirst = a.lowerBound < b.lowerBound }
            if let col100, let colServe { hundredFirst = col100 < colServe }
        } else if all.contains("servings per") || all.contains("avg quantity") || all.contains("average quantity") {
            hundredFirst = false   // an Australian panel: per serve first, then per 100
        }
        let unit = all.range(of: #"100\s*ml"#, options: .regularExpression) != nil ? "ml" : "g"

        /// The per-100 value and the per-serving value from a row's numbers.
        func pick(_ ns: [(v: Double, unit: String, x: Double)]) -> (per100: Double?, serve: Double?) {
            guard !ns.isEmpty else { return (nil, nil) }
            if let col100, ns.count >= 1 {
                let near = ns.min { abs($0.x - col100) < abs($1.x - col100) }
                let serve = colServe.flatMap { cs in ns.min { abs($0.x - cs) < abs($1.x - cs) } }
                return (near?.v, serve?.v == near?.v && ns.count == 1 ? nil : serve?.v)
            }
            if ns.count == 1 { return (ns[0].v, nil) }
            return hundredFirst ? (ns[0].v, ns[1].v) : (ns[1].v, ns[0].v)
        }

        func row(_ match: (String) -> Bool) -> Row? { rs.first { match($0.text.lowercased()) } }
        let mass = { (n: (v: Double, unit: String, x: Double)) in n.unit == "g" || n.unit == "" }

        // energy: kcal where printed (it can share a row with kJ, or sit on its own row), else kJ ÷ 4.184
        var kcal100: Double?, kcalServe: Double?
        let energyRows = rs.filter { let t = $0.text.lowercased(); return t.contains("energy") || t.contains("kcal") || t.contains("calories") || t.range(of: #"\bkj\b"#, options: .regularExpression) != nil }
        let kcals = energyRows.flatMap { numbers($0).filter { $0.unit == "kcal" || $0.unit == "cal" } }
        if !kcals.isEmpty { (kcal100, kcalServe) = pick(kcals) }
        else {
            let kjs = energyRows.flatMap { numbers($0).filter { $0.unit == "kj" } }
            let (a, b) = pick(kjs)
            kcal100 = a.map { $0 / 4.184 }; kcalServe = b.map { $0 / 4.184 }
        }
        guard let k = kcal100, k > 0, k <= 950 else { return nil }

        func nutrient(_ match: @escaping (String) -> Bool) -> Double? {
            guard let r = row(match) else { return nil }
            return pick(numbers(r).filter(mass)).per100
        }
        let protein = nutrient { $0.contains("protein") }
        let carbs = nutrient { $0.contains("carbohydrate") && !$0.contains("of which") && !$0.contains("sugar") }
        let fat = nutrient { t in (t.hasPrefix("fat") || t.contains(" fat") || t.contains("fat,") || t.contains("fat total") || t.hasPrefix("total fat")) && !t.contains("saturat") && !t.contains("of which") && !t.contains("trans") && !t.contains("mono") && !t.contains("poly") }

        // sense check: anything over 100 g per 100 g is a misread; with all three, the energy must roughly add up
        for v in [protein, carbs, fat] { if let v, v > 100 { return nil } }
        if let p = protein, let c = carbs, let f = fat {
            let worked = 4 * p + 4 * c + 9 * f
            if abs(worked - k) > max(45, k * 0.25) { return nil }
        }
        if protein == nil && carbs == nil && fat == nil { return nil }   // only an energy figure: not enough to trust

        // serving size, if printed
        var serving: Double?
        for pat in [#"serving size[^\d]{0,12}(\d+(?:\.\d+)?)\s*(g|ml)"#, #"per\s+(\d+(?:\.\d+)?)\s*(g|ml)\s*(serv|portion)"#,
                    #"(\d+(?:\.\d+)?)\s*(g|ml)\s*(serving|portion)"#, #"portion[^\d]{0,6}(\d+(?:\.\d+)?)\s*(g|ml)"#] {
            if let r = all.range(of: pat, options: .regularExpression) {
                let s = String(all[r])
                if let m = s.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression), let v = Double(s[m]), v > 0, v < 2000 { serving = v; break }
            }
        }
        if serving == nil, let h = header {
            let ht = h.text.lowercased()
            for r in [#"per\s+(\d+(?:\.\d+)?)\s*(g|ml)"#, #"(\d+(?:\.\d+)?)\s*(g|ml)\s*(serv|portion)"#] {
                if let rr = ht.range(of: r, options: .regularExpression) {
                    let s = String(ht[rr])
                    if let m = s.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression), let v = Double(s[m]), v != 100 { serving = v; break }
                }
            }
        }
        return Parsed(kcal100: k, p100: protein, c100: carbs, f100: fat, servingSize: serving, kcalServing: kcalServe, unit: unit)
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
