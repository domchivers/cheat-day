import Foundation

/// Logging by typing the numbers, no AI and no waiting: "chicken sandwich - 600 kcal - 60p 30f 10c",
/// "protein shake 250 cal 40p", "wrap 450kcal p35 f12 c40". One food a line (or split with ";").
/// Calories are worked out from the macros when they're left off.
enum QuickLog {
    struct Line: Equatable {
        var name: String
        var kcal: Double
        var p: Double?
        var c: Double?
        var f: Double?
    }

    private static let n = #"(\d+(?:[.,]\d+)?)"#
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }
    // number then word ("60p", "60 g protein") or word then number ("p60", "protein: 60")
    private static let kcalRx = rx(n + #"\s*(kcal|kcals|cal|cals|calories|kilocalories|kj|kilojoules)\b"#)
    private static let kcalRx2 = rx(#"\b(kcal|cal|cals|calories|kj|kilojoules)\s*:?\s*"# + n)
    private static func macro(_ words: String) -> [NSRegularExpression] {
        [rx(n + #"\s*g?\s*(?:"# + words + #")\b"#), rx(#"\b(?:"# + words + #")\s*:?\s*"# + n + #"\s*g?\b"#)]
    }
    private static let pRx = macro("p|pro|protein|proteins")
    private static let cRx = macro("c|carb|carbs|carbohydrates?")
    private static let fRx = macro("f|fat|fats")

    static func parse(_ text: String) -> [Line] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n;")).compactMap { parseLine($0) }
    }

    static func parseLine(_ raw: String) -> Line? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        func take(_ rs: [NSRegularExpression], kj: Bool = false) -> Double? {
            for r in rs {
                let ns = s as NSString
                guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
                var numIndex = 1
                for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
                    if Double(ns.substring(with: m.range(at: i)).replacingOccurrences(of: ",", with: ".")) != nil { numIndex = i; break }
                }
                guard let v = Double(ns.substring(with: m.range(at: numIndex)).replacingOccurrences(of: ",", with: ".")) else { continue }
                let unit = ns.substring(with: m.range).lowercased()
                s = ns.replacingCharacters(in: m.range, with: " ")
                return kj && (unit.contains("kj") || unit.contains("kilojoule")) ? v / 4.184 : v
            }
            return nil
        }
        var kcal = take([kcalRx, kcalRx2], kj: true)
        let p = take(pRx), c = take(cRx), f = take(fRx)
        if kcal == nil, p != nil || c != nil || f != nil { kcal = 4 * (p ?? 0) + 4 * (c ?? 0) + 9 * (f ?? 0) }
        guard let k = kcal, k > 0, k < 10000 else { return nil }
        // what's left is the name, without the dashes and commas between the numbers
        var name = s.replacingOccurrences(of: #"[\-–—:|,/]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Quick add" }
        name = name.prefix(1).uppercased() + name.dropFirst()
        return Line(name: name, kcal: k.rounded(), p: p, c: c, f: f)
    }

    private static let askWords: Set<String> = ["what", "whats", "what's", "how", "can", "could", "should", "is", "are", "was", "why", "when", "which",
        "give", "make", "plan", "suggest", "recipe", "find", "tell", "do", "does", "i", "im", "i'm", "my", "help", "compare", "would", "will"]

    /// A message that's just foods with their numbers, to log straight away. Nil for anything that reads like a question
    /// or a request ("is 600 kcal a lot for lunch?"), which goes to the AI.
    static func instant(_ text: String) -> [Line]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("?") else { return nil }
        let first = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init) ?? ""
        guard !askWords.contains(first) else { return nil }
        let lines = t.components(separatedBy: CharacterSet(charactersIn: "\n;")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let parsed = lines.compactMap(parseLine)
        guard !parsed.isEmpty, parsed.count == lines.count,
              parsed.allSatisfy({ $0.name.split(separator: " ").count <= 8 }) else { return nil }
        return parsed
    }

    static func summary(_ l: Line) -> String {
        let m = [l.p.map { "\(Fmt.int($0))p" }, l.c.map { "\(Fmt.int($0))c" }, l.f.map { "\(Fmt.int($0))f" }].compactMap { $0 }
        return "\(l.name) · \(Fmt.int(l.kcal)) kcal" + (m.isEmpty ? "" : " · " + m.joined(separator: " "))
    }

    /// The food as it's saved, so it shows up in your foods (at this amount) next time.
    static func basis(_ l: Line) -> JSON {
        var b: JSON = ["name": l.name, "source": "manual", "unit": "g", "unitLabel": "portion", "kcalPerServing": l.kcal]
        if l.p != nil || l.c != nil || l.f != nil { b["pServ"] = l.p ?? 0; b["cServ"] = l.c ?? 0; b["fServ"] = l.f ?? 0 }
        return b
    }
}
