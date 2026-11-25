import SwiftUI

/// Matched routes' views (26 Nov, design/matched-routes-mockup.html).

/// "41 s", or "1:05" past a minute.
private func gapText(_ s: Double) -> String { abs(s) >= 60 ? Bests.time(abs(s)) : "\(Int(abs(s).rounded())) s" }

/// After a run, ride, walk or hike on a route done before: against last time, and the best on it.
struct RouteNewsCard: View {
    let group: RouteGroup
    let id: String
    @State private var named: Int = 0

    var body: some View {
        let _ = named   // (a name found or changed shows)
        let i: Int = group.index(of: id) ?? (group.runs.count - 1)
        let me: RouteRun = group.runs[i]
        let last: RouteRun? = i > 0 ? group.runs[i - 1] : nil
        let best: RouteRun? = group.runs.filter { (r: RouteRun) -> Bool in r.id != id }.min { $0.seconds < $1.seconds }
        let gap: Double = (last?.seconds ?? me.seconds) - me.seconds
        let headline: String = abs(gap) < 1 ? "Same time as last time" : "\(gapText(gap)) \(gap > 0 ? "faster" : "slower") than last time"
        let lastLine: String? = last.map { (r: RouteRun) -> String in "\(Bests.time(r.seconds)) on \(Bests.day(r.date))" }
        let bestLine: String? = best.map { (b: RouteRun) -> String in
            me.seconds < b.seconds ? "your best here, ahead of \(Bests.time(b.seconds)) (\(Bests.day(b.date)))" : "your best here is \(Bests.time(b.seconds)) (\(Bests.day(b.date)))"
        }
        VStack(alignment: .leading, spacing: 4) {
            Label("\(group.name.uppercased()) · \(RouteMatch.ordinal(i + 1).uppercased()) TIME", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.heavy)).foregroundStyle(Theme.accent).lineLimit(1)
            Text(headline).font(.title3.weight(.heavy)).foregroundStyle(gap >= 1 ? Color.green : Color.primary)
            Text([lastLine, bestLine].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .task { await RouteMatch.nameIfNeeded(group); named += 1 }
    }
}

/// On a workout's page: every time on its route, the best gold and this one in the accent, and the times listed.
struct RouteHistoryCard: View {
    let group: RouteGroup
    let id: String
    @State private var named: Int = 0
    @State private var renaming = false
    @State private var text = ""

    var body: some View {
        let _ = named   // (a name found or changed shows)
        let shown: [RouteRun] = Array(group.runs.suffix(8))
        let times: [Double] = shown.map(\.seconds)
        let lo: Double = (times.min() ?? 0) * 0.92, hi: Double = max(times.max() ?? 1, lo + 1)
        let best: RouteRun? = group.best
        let place: Int = group.place(of: id) ?? 1
        let me: RouteRun? = group.runs.first { $0.id == id }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(group.name.uppercased(), systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.heavy)).foregroundStyle(Theme.accent).lineLimit(1)
                Button { text = group.name; renaming = true } label: { Image(systemName: "pencil").font(.caption.weight(.bold)) }
                    .buttonStyle(.borderless).foregroundStyle(Theme.accent).accessibilityLabel("Rename this route")
            }
            Text("\(group.runs.count) times · \(String(format: "%.1f", group.km)) km").font(.footnote).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(shown) { (r: RouteRun) in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(r.id == best?.id ? Color.yellow : (r.id == id ? Theme.accent : Theme.accent.opacity(0.35)))
                            .frame(height: 20 + 70 * (r.seconds - lo) / (hi - lo))
                        Text(r.id == id ? "This" : Bests.day(r.date)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110, alignment: .bottom)
            .accessibilityHidden(true)
            if let best, let me {
                Text("Shorter is faster. Best \(Bests.time(best.seconds)) · this one \(Bests.time(me.seconds)), \(RouteMatch.ordinal(place)) of \(group.runs.count)")
                    .font(.subheadline)
            }
            ForEach(Array(group.runs.reversed())) { (r: RouteRun) in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.id == id ? "This one" : Bests.day(r.date) + (r.id == best?.id ? " · best" : "")).font(.subheadline.weight(.semibold))
                        if r.km > 0 && r.seconds > 0 {
                            Text(group.kind.speed ? String(format: "%.1f km/h", r.km / r.seconds * 3600) : RouteMath.pace(r.seconds / r.km) + " /km")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(Bests.time(r.seconds)).font(.subheadline.weight(.heavy)).monospacedDigit()
                        .foregroundStyle(r.id == best?.id ? Color.yellow : Color.primary)
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { await RouteMatch.nameIfNeeded(group); named += 1 }
        .alert("Rename this route", isPresented: $renaming) {
            TextField("Route name", text: $text)
            Button("Save") { RouteMatch.rename(group.id, to: text); named += 1 }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A route on Your bests' Routes tab.
struct RouteRow: View {
    let group: RouteGroup
    var body: some View {
        let best: RouteRun? = group.best
        HStack(spacing: 12) {
            if let first = group.runs.last, let r = RouteStore.load(first.id), r.count > 1 { RouteThumb(points: r, size: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(group.kind.title) · \(String(format: "%.1f", group.km)) km · \(group.runs.count) times").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if let best { Text(Bests.time(best.seconds)).font(.body.weight(.heavy)).monospacedDigit().foregroundStyle(.yellow) }
        }
        .accessibilityElement(children: .combine)
    }
}
