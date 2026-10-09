import Foundation

/// The synced record is the web app's own JSON, kept as plain dictionaries so every field the
/// native app doesn't know about yet travels through untouched.
typealias JSON = [String: Any]

func num(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber: let d = n.doubleValue; return d.isFinite ? d : nil
    case let d as Double: return d.isFinite ? d : nil
    case let i as Int: return Double(i)
    case let s as String: return Double(s)
    default: return nil
    }
}
/// A positive number, or nil (the web app's `num()`).
func pos(_ v: Any?) -> Double? { if let d = num(v), d > 0 { return d }; return nil }
func str(_ v: Any?) -> String { (v as? String) ?? "" }
func dict(_ v: Any?) -> JSON { (v as? JSON) ?? [:] }
func list(_ v: Any?) -> [JSON] { (v as? [Any])?.compactMap { $0 as? JSON } ?? [] }

func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

/// Same shape as the web app's ids: time in base 36 plus four random characters.
func uid() -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    let tail = String((0..<4).map { _ in chars[Int.random(in: 0..<chars.count)] })
    return String(nowMs(), radix: 36) + tail
}

enum ISO {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func now() -> String { withFraction.string(from: Date()) }
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}

/// "2026-10-09" in the phone's own time zone, like the web app's localDate().
enum DayKey {
    static func string(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }
    static func date(_ key: String) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return Date() }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) ?? Date()
    }
    static func shift(_ key: String, days: Int) -> String {
        string(Calendar.current.date(byAdding: .day, value: days, to: date(key)) ?? Date())
    }
    /// 0 = Sunday, like JavaScript's getDay().
    static func weekday(_ key: String) -> Int { Calendar.current.component(.weekday, from: date(key)) - 1 }
}

enum Fmt {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()
    static func int(_ v: Double) -> String { grouped.string(from: NSNumber(value: v.rounded())) ?? String(Int(v.rounded())) }
    /// Whole numbers from 10 up, one decimal below (the web app's fmt1).
    static func one(_ v: Double) -> String {
        if abs(v) >= 10 { return String(Int(v.rounded())) }
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
    /// "12.5% of the day" as the web app writes it.
    static func share(_ kcal: Double, of budget: Double) -> String {
        guard budget > 0 else { return "" }
        let pct = (kcal / budget * 1000).rounded() / 10
        let text = pct == pct.rounded() ? String(Int(pct)) : String(format: "%.1f", pct)
        return "\(text)% of the day"
    }
}
