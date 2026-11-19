import Foundation
import MetricKit
import SwiftUI

/// How smooth the app really is, from the phone itself (19 Nov). The Mac's simulator can't measure stutter (its
/// scroll test only gives durations), so Apple's own reports are kept: once a day iOS hands over the last day's
/// numbers (how much scrolling hitched, how long the app hung, how fast it opened) and, soon after, any hang or crash
/// with where it happened. Kept on the phone only, the newest 60, to look at or share from Settings (Your data,
/// Performance reports). Nothing is sent anywhere.
final class Performance: NSObject, MXMetricManagerSubscriber {
    static let shared = Performance()

    private static let folder: URL = {
        let f = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("performance", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    func start() { MXMetricManager.shared.add(self) }

    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    // A day's numbers.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            var s: JSON = ["kind": "day", "from": Self.iso(p.timeStampBegin), "to": Self.iso(p.timeStampEnd), "version": p.latestApplicationVersion]
            if let a = p.animationMetrics {
                // milliseconds of hitches a second of scrolling: under 5 is good, from 10 people notice (Apple, WWDC20)
                s["scrollHitchMsPerS"] = a.scrollHitchTimeRatio.value   // given in ms per s
            }
            if let r = p.applicationResponsivenessMetrics { s["hangs"] = Self.buckets(r.histogrammedApplicationHangTime) }
            if let l = p.applicationLaunchMetrics { s["launch"] = Self.buckets(l.histogrammedTimeToFirstDraw) }
            if let e = p.applicationExitMetrics {
                s["crashes"] = e.foregroundExitData.cumulativeAbnormalExitCount + e.foregroundExitData.cumulativeBadAccessExitCount
                s["killedForMemory"] = e.foregroundExitData.cumulativeMemoryResourceLimitExitCount
            }
            keep(s, raw: p.jsonRepresentation())
        }
    }

    // A hang or crash, with where in the app it happened.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            let s: JSON = ["kind": "problems", "from": Self.iso(p.timeStampBegin), "to": Self.iso(p.timeStampEnd),
                           "hangs": (p.hangDiagnostics ?? []).map { $0.hangDuration.converted(to: .seconds).value },
                           "crashes": (p.crashDiagnostics ?? []).count, "cpu": (p.cpuExceptionDiagnostics ?? []).count]
            keep(s, raw: p.jsonRepresentation())
        }
    }

    /// A histogram as "under 250 ms: 12" lines (MetricKit's buckets, in the units it gives).
    private static func buckets<U>(_ h: MXHistogram<U>) -> [String] {
        var out: [String] = []
        let e = h.bucketEnumerator
        while let b = e.nextObject() as? MXHistogramBucket<U> {
            out.append("\(Int(b.bucketStart.value))–\(Int(b.bucketEnd.value)) \(b.bucketEnd.unit.symbol): \(b.bucketCount)")
        }
        return out
    }

    private func keep(_ summary: JSON, raw: Data) {
        let name = "\(str(summary["kind"]))-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
        var s = summary; s["raw"] = (try? JSONSerialization.jsonObject(with: raw)) ?? [:] as JSON
        guard let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? d.write(to: Self.folder.appendingPathComponent(name + ".json"), options: .atomic)
        // the newest 60
        let all = Self.files()
        for old in all.dropFirst(60) { try? FileManager.default.removeItem(at: old) }
    }

    /// The reports kept, newest first.
    static func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { $0.pathExtension == "json" }.sorted { a, b in
            let x = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let y = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return x > y
        }
    }
    static func summary(_ url: URL) -> JSON {
        guard let d = try? Data(contentsOf: url), let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { return [:] }
        return j
    }
}

/// Settings, Your data, Performance reports: each day's numbers and any hang or crash, newest first, to share.
struct PerformanceView: View {
    private let files = Performance.files()
    var body: some View {
        List {
            if files.isEmpty {
                Text("Nothing yet. iOS hands these over about once a day, from the second day after the app is installed.").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { f in
                let s = Performance.summary(f)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(s)).font(.subheadline.weight(.semibold))
                    Text(Self.line(s)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !files.isEmpty {
                Section { ShareLink(items: files) { Label("Share all reports", systemImage: "square.and.arrow.up") } }
                    footer: { Text("Kept on this phone only. Share them to see how smooth scrolling was, and any hang or crash.") }
            }
            // how big each posted video came out: the longest that fits in 50 MB, read off real videos
            let sizes = UserDefaults.standard.stringArray(forKey: "video.sizes") ?? []
            if !sizes.isEmpty {
                Section("Videos made for posting") { ForEach(sizes.indices, id: \.self) { Text(sizes[$0]).font(.subheadline).monospacedDigit() } }
            }
        }
        .navigationTitle("Performance reports").navigationBarTitleDisplayMode(.inline)
    }

    private static func title(_ s: JSON) -> String {
        let day = ISO.date(str(s["to"]))?.formatted(date: .abbreviated, time: .omitted) ?? ""
        return (str(s["kind"]) == "problems" ? "Hangs and crashes · " : "Day · ") + day + (str(s["version"]).isEmpty ? "" : " · \(str(s["version"]))")
    }
    private static func line(_ s: JSON) -> String {
        if str(s["kind"]) == "problems" {
            let hangs = (s["hangs"] as? [Double] ?? []).map { String(format: "%.1f s", $0) }
            return "Hangs: \(hangs.isEmpty ? "none" : hangs.joined(separator: ", ")) · crashes: \(Int(num(s["crashes"]) ?? 0))"
        }
        var bits: [String] = []
        if let h = num(s["scrollHitchMsPerS"]) { bits.append(String(format: "Scroll hitches %.1f ms/s", h)) }
        if let c = num(s["crashes"]) { bits.append("crashes \(Int(c))") }
        return bits.isEmpty ? "No scrolling measured" : bits.joined(separator: " · ")
    }
}
