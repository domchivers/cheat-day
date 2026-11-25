import SwiftUI
import MapKit

/// A run's route as a shape, no map under it (25 Nov, design/run-route-mockup.html): the thumbnail on Workouts' rows
/// and the done screen. Fitted to its box, north up, the right way round for its latitude.
struct RouteShape: Shape {
    let points: [RoutePoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let lats: [Double] = points.map(\.lat), lons: [Double] = points.map(\.lon)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return path }
        let squash: Double = cos(((minLat + maxLat) / 2) * .pi / 180)
        let w: Double = max(1e-9, (maxLon - minLon) * squash), h: Double = max(1e-9, maxLat - minLat)
        let inset: CGRect = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
        let scale: Double = min(Double(inset.width) / w, Double(inset.height) / h)
        let ox: Double = Double(inset.midX) - w * scale / 2, oy: Double = Double(inset.midY) - h * scale / 2
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: ox + (p.lon - minLon) * squash * scale, y: oy + (maxLat - p.lat) * scale)
            if i == 0 || p.gap { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

/// The little map on a run's row: its route's shape on a dark tile.
struct RouteThumb: View {
    let points: [RoutePoint]
    var size: CGFloat = 46
    var body: some View {
        RouteShape(points: points)
            .stroke(Color.green, style: StrokeStyle(lineWidth: max(2, size / 22), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .background(Color(red: 0.11, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The map's look (26 Nov, design/map-style-mockup.html, A): Apple's map toned down, no shops or places, so the
/// route is what you see.
extension MapStyle {
    static var quiet: MapStyle { .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false) }
}

extension RouteMath {
    /// The route in short pieces (100 m, or a 150th of it on a long ride), each with how fast it was against the rest
    /// of this route: 0 the slowest, 1 the fastest (the 10th and 90th of its pieces, so one sprint or stop doesn't
    /// set the scale). A pause starts a new piece, not joined to the last.
    static func paced(_ p: [RoutePoint]) -> [(points: [CLLocationCoordinate2D], fast: Double)] {
        guard p.count > 1 else { return [] }
        let step: Double = max(100, meters(p) / 150)
        var pieces: [(pts: [CLLocationCoordinate2D], d: Double, t: Double)] = []
        var cur: [CLLocationCoordinate2D] = [p[0].coordinate]
        var d: Double = 0, t: Double = 0
        for i in 1..<p.count {
            let a: RoutePoint = p[i - 1], b: RoutePoint = p[i]
            if b.gap {
                if cur.count > 1 { pieces.append((cur, d, t)) }
                cur = [b.coordinate]; d = 0; t = 0
                continue
            }
            d += b.location.distance(from: a.location); t += max(0, b.t - a.t); cur.append(b.coordinate)
            if d >= step { pieces.append((cur, d, t)); cur = [b.coordinate]; d = 0; t = 0 }
        }
        if cur.count > 1 { pieces.append((cur, d, t)) }
        let speeds: [Double] = pieces.map { (x: (pts: [CLLocationCoordinate2D], d: Double, t: Double)) -> Double in x.t > 0 ? x.d / x.t : 0 }
        let sorted: [Double] = speeds.filter { $0 > 0 }.sorted()
        guard sorted.count > 1 else { return pieces.map { (x: (pts: [CLLocationCoordinate2D], d: Double, t: Double)) -> (points: [CLLocationCoordinate2D], fast: Double) in (x.pts, 0.5) } }
        let lo: Double = sorted[Int(Double(sorted.count - 1) * 0.1)], hi: Double = sorted[Int(Double(sorted.count - 1) * 0.9)]
        var out: [(points: [CLLocationCoordinate2D], fast: Double)] = []
        for (i, x) in pieces.enumerated() {
            let f: Double = hi - lo < 0.05 ? 0.5 : min(1, max(0, (speeds[i] - lo) / (hi - lo)))
            out.append((x.pts, speeds[i] > 0 ? f : 0))
        }
        return out
    }

    /// Faster green, through yellow, to orange for slower.
    static func paceColour(_ fast: Double) -> Color {
        let slow: (Double, Double, Double) = (0.94, 0.54, 0.24), mid: (Double, Double, Double) = (0.96, 0.84, 0.28), quick: (Double, Double, Double) = (0.29, 0.82, 0.54)
        let (a, b, f): ((Double, Double, Double), (Double, Double, Double), Double) = fast < 0.5 ? (slow, mid, fast * 2) : (mid, quick, (fast - 0.5) * 2)
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
}

/// Under a map's route: what its colours mean.
struct PaceKey: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("faster")
            Capsule().fill(LinearGradient(colors: [RouteMath.paceColour(1), RouteMath.paceColour(0.5), RouteMath.paceColour(0)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 70, height: 5)
            Text("slower")
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityHidden(true)
    }
}

/// The route on a map (26 Nov, design/map-style-mockup.html, A): a quiet map, the line coloured by pace with a soft
/// glow under it, a mark at each kilometre, start and finish. Fitted to the route; it can be moved and zoomed, and a
/// tap on the corner button fits it again.
struct RunMap: View {
    let points: [RoutePoint]
    var interactive = true
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let pieces: [(points: [CLLocationCoordinate2D], fast: Double)] = RouteMath.paced(points)
        let marks: [CLLocationCoordinate2D] = RouteMath.kmMarks(points)
        Map(position: $camera, interactionModes: interactive ? .all : []) {
            // the glow, all of it under the line
            ForEach(pieces.indices, id: \.self) { i in
                MapPolyline(coordinates: pieces[i].points)
                    .stroke(RouteMath.paceColour(pieces[i].fast).opacity(0.35), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
            }
            ForEach(pieces.indices, id: \.self) { i in
                MapPolyline(coordinates: pieces[i].points)
                    .stroke(RouteMath.paceColour(pieces[i].fast), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(marks.indices, id: \.self) { i in
                Annotation("", coordinate: marks[i], anchor: .center) {
                    Text("\(i + 1)").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
                        .frame(width: 18, height: 18).background(.white, in: Circle())
                }
            }
            if let first = points.first {
                Annotation("Start", coordinate: first.coordinate, anchor: .center) {
                    Circle().fill(.white).frame(width: 14, height: 14).overlay(Circle().stroke(.black, lineWidth: 3))
                }
            }
            if let last = points.last, points.count > 1 {
                Annotation("Finish", coordinate: last.coordinate, anchor: .center) {
                    Circle().fill(.black).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
        }
        .mapStyle(.quiet)
        .overlay(alignment: .bottomLeading) { if pieces.count > 2 { PaceKey().padding(8) } }
        .overlay(alignment: .topTrailing) {
            if interactive {
                Button { withAnimation { camera = .automatic } } label: {
                    Image(systemName: "scope").font(.subheadline.weight(.bold)).padding(9).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain).padding(10).accessibilityLabel("Fit the route")
            }
        }
    }
}

/// For the UI test: a mapped run's page, from a made-up loop round a park, run and walk turns like week 2's.
struct RunMapHarness: View {
    static let id = "uitest-run"
    static var sample: [RoutePoint] {
        // an oval about 1.3 km round, three times, 31 minutes
        (0..<372).map { (i: Int) -> RoutePoint in
            let a: Double = Double(i) / 124 * 2 * .pi
            let t: Double = Double(i) * 5
            let run: Bool = t >= 300 && t < 1560 && (t - 300).truncatingRemainder(dividingBy: 210) < 90
            return RoutePoint(lat: -37.8455 + 0.0022 * sin(a), lon: 144.9715 + 0.0014 * cos(a), t: t, run: run)
        }
    }
    init() { RouteStore.save(Self.sample, id: Self.id) }
    var body: some View {
        NavigationStack {
            WorkoutDetail(workout: ["id": Self.id, "type": "Run", "name": "Start running · week 2, run 1", "minutes": 31, "kcal": 201,
                                    "lifts": [Any](), "km": (RouteMath.meters(Self.sample) / 10).rounded() / 100], date: "2026-11-25")
        }
    }
}

/// A mapped run's page: the map, the numbers, and each kilometre (the fastest one marked).
struct RunRouteCard: View {
    let workout: JSON
    let points: [RoutePoint]

    var body: some View {
        let meters: Double = (num(workout["km"]).map { $0 * 1000 }) ?? RouteMath.meters(points)
        let seconds: Double = points.last?.t ?? (num(workout["minutes"]) ?? 0) * 60
        // a ride (26 Nov): speed in place of pace, and no kilometre-by-kilometre pace bars
        let ride: Bool = str(workout["type"]) == "Cycle"
        let splits: [(km: Double, seconds: Double)] = ride ? [] : RouteMath.splits(points)
        let speed: String = seconds > 0 ? String(format: "%.1f km/h", meters / seconds * 3.6) : "–"
        VStack(alignment: .leading, spacing: 12) {
            RunMap(points: points).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile(RouteMath.km(meters) + " km", "distance")
                tile(RunStart.mmss(Int(seconds.rounded())), "moving time")
                if ride { tile(speed, "average speed") }
                else { tile(RouteMath.pace(meters > 0 ? seconds / meters * 1000 : nil) + " /km", "average pace") }
                tile(Fmt.int(num(workout["kcal"]) ?? 0), "kcal")
                if let up = num(workout["climb"]), up >= 1 { tile(Fmt.int(up) + " m", "climbed") }
            }
            if !splits.isEmpty { splitRows(splits) }
            Label("Saved on your phone and in Apple Health. Only you can see it.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.heavy)).monospacedDigit()
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A bar a kilometre, longer the faster; the fastest whole one in the bright green.
    private func splitRows(_ splits: [(km: Double, seconds: Double)]) -> some View {
        let paces: [Double] = splits.map { $0.seconds / max(0.05, $0.km) }
        let slow: Double = paces.max() ?? 1, quick: Double = paces.min() ?? 1
        let best: Int? = splits.indices.filter { splits[$0].km >= 0.99 }.min { paces[$0] < paces[$1] }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Each kilometre").font(.headline)
            ForEach(splits.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Text(splits[i].km >= 0.99 ? "\(i + 1)" : String(format: "%.1f", Double(i) + splits[i].km))
                        .font(.subheadline.weight(.bold)).monospacedDigit().frame(width: 30, alignment: .leading)
                    GeometryReader { g in
                        // the slowest at 45% of the width, the quickest at the whole of it
                        let f: Double = slow > quick ? 0.45 + 0.55 * (slow - paces[i]) / (slow - quick) : 1
                        Capsule().fill(i == best ? Color.green : Color.green.opacity(0.5))
                            .frame(width: g.size.width * CGFloat(f), height: 8).frame(maxHeight: .infinity)
                    }
                    .frame(height: 18)
                    Text(RouteMath.pace(paces[i])).font(.subheadline.weight(i == best ? .heavy : .semibold)).monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Kilometre \(i + 1), \(RouteMath.pace(paces[i])) a kilometre")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
