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

/// The route on a map: green where they ran, the app's blue where they walked, a mark at each kilometre, start and
/// finish. Fitted to the route; it can be moved and zoomed, and a tap on the corner button fits it again.
struct RunMap: View {
    let points: [RoutePoint]
    var interactive = true
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let lines: [(run: Bool, points: [CLLocationCoordinate2D])] = RouteMath.stretches(points)
        let marks: [CLLocationCoordinate2D] = RouteMath.kmMarks(points)
        Map(position: $camera, interactionModes: interactive ? .all : []) {
            ForEach(lines.indices, id: \.self) { i in
                MapPolyline(coordinates: lines[i].points)
                    .stroke(lines[i].run ? Color.green : Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
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
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .environment(\.colorScheme, .dark)
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
        let splits: [(km: Double, seconds: Double)] = RouteMath.splits(points)
        VStack(alignment: .leading, spacing: 12) {
            RunMap(points: points).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile(RouteMath.km(meters) + " km", "distance")
                tile(RunStart.mmss(Int(seconds.rounded())), "time")
                tile(RouteMath.pace(meters > 0 ? seconds / meters * 1000 : nil) + " /km", "average pace")
                tile(Fmt.int(num(workout["kcal"]) ?? 0), "kcal")
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
