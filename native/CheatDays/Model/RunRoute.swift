import Foundation
import CoreLocation
import HealthKit

/// A run's route (25 Nov, design/run-route-mockup.html): where, how far into the run (pauses left out), and whether it
/// was a running stretch or a walk. Kept on the phone only, a file per workout, and in Apple Health with the workout;
/// never in the account (the workout there has only its distance and splits).
struct RoutePoint: Codable, Equatable {
    let lat: Double
    let lon: Double
    let t: Double
    let run: Bool
    /// The first point after a pause: no line, and no distance, from the one before.
    var gap: Bool = false

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
}

/// Routes on the phone: Application Support/routes/<workout id>.json.
enum RouteStore {
    static var folder: URL {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir: URL = base.appendingPathComponent("routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func file(_ id: String) -> URL {
        folder.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }
    static func save(_ points: [RoutePoint], id: String) {
        guard points.count > 1, let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: file(id), options: [.atomic, .completeFileProtection])
    }
    static func load(_ id: String) -> [RoutePoint]? {
        guard !id.isEmpty, let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode([RoutePoint].self, from: data)
    }
    static func has(_ id: String) -> Bool { !id.isEmpty && FileManager.default.fileExists(atPath: file(id).path) }
    static func delete(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }
}

enum RouteMath {
    /// Metres along the route, not across pauses.
    static func meters(_ p: [RoutePoint]) -> Double {
        guard p.count > 1 else { return 0 }
        var total: Double = 0
        for i in 1..<p.count where !p[i].gap { total += p[i].location.distance(from: p[i - 1].location) }
        return total
    }

    /// Each kilometre's time; the last, part of one, if it's 50 m or more (its length in km with it).
    static func splits(_ p: [RoutePoint]) -> [(km: Double, seconds: Double)] {
        guard p.count > 1 else { return [] }
        var out: [(km: Double, seconds: Double)] = []
        var total: Double = 0, next: Double = 1000, lastT: Double = p[0].t
        for i in 1..<p.count {
            let a: RoutePoint = p[i - 1], b: RoutePoint = p[i]
            guard !b.gap else { continue }
            let d: Double = b.location.distance(from: a.location)
            guard d > 0 else { continue }
            while total + d >= next {
                let f: Double = (next - total) / d
                let t: Double = a.t + (b.t - a.t) * f
                out.append((km: 1, seconds: t - lastT))
                lastT = t; next += 1000
            }
            total += d
        }
        let rest: Double = total - (next - 1000)
        if rest >= 50, let last = p.last { out.append((km: rest / 1000, seconds: last.t - lastT)) }
        return out
    }

    /// Seconds a kilometre as "7:56"; "–:––" when there's nothing to go on.
    static func pace(_ secondsPerKm: Double?) -> String {
        guard let s = secondsPerKm, s.isFinite, s > 0, s < 3600 else { return "–:––" }
        let r: Int = Int(s.rounded())
        return String(format: "%d:%02d", r / 60, r % 60)
    }

    /// "3.92"
    static func km(_ meters: Double) -> String { String(format: "%.2f", meters / 1000) }

    /// Runs and walks as separate lines (a pause starts a new one).
    static func stretches(_ p: [RoutePoint]) -> [(run: Bool, points: [CLLocationCoordinate2D])] {
        var out: [(run: Bool, points: [CLLocationCoordinate2D])] = []
        for (i, pt) in p.enumerated() {
            if i == 0 || pt.gap || pt.run != p[i - 1].run || out.isEmpty {
                // join to the last point so the line doesn't break where running turns to walking
                var start: [CLLocationCoordinate2D] = []
                if i > 0 && !pt.gap { start.append(p[i - 1].coordinate) }
                out.append((run: pt.run, points: start + [pt.coordinate]))
            } else {
                out[out.count - 1].points.append(pt.coordinate)
            }
        }
        return out
    }

    /// Where each whole kilometre falls, for the markers on the map.
    static func kmMarks(_ p: [RoutePoint]) -> [CLLocationCoordinate2D] {
        guard p.count > 1 else { return [] }
        var out: [CLLocationCoordinate2D] = []
        var total: Double = 0, next: Double = 1000
        for i in 1..<p.count where !p[i].gap {
            let d: Double = p[i].location.distance(from: p[i - 1].location)
            while d > 0 && total + d >= next {
                let f: Double = (next - total) / d
                out.append(CLLocationCoordinate2D(latitude: p[i - 1].lat + (p[i].lat - p[i - 1].lat) * f,
                                                  longitude: p[i - 1].lon + (p[i].lon - p[i - 1].lon) * f))
                next += 1000
            }
            total += d
        }
        return out
    }
}

/// Health hands a route over in batches, on its own queue: they're gathered here, and all of them given back once.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [CLLocation] = []
    private var finished = false
    func add(_ ls: [CLLocation], done: Bool) -> [CLLocation]? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        all += ls
        if done { finished = true; return all }
        return nil
    }
}

/// Routes a watch saved to Apple Health with its workouts, read in as points (no runs or walks told apart there).
extension HealthSync {
    static func route(for w: HKWorkout) async -> [RoutePoint] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { (cont: CheckedContinuation<[HKWorkoutRoute], Never>) in
            let q = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: w),
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkoutRoute]) ?? [])
            }
            health.execute(q)
        }
        guard let route = routes.first else { return [] }
        let locations: [CLLocation] = await withCheckedContinuation { (cont: CheckedContinuation<[CLLocation], Never>) in
            let got = Collected()
            let q = HKWorkoutRouteQuery(route: route) { _, ls, done, error in
                let all: [CLLocation]? = got.add(ls ?? [], done: done || error != nil)
                if let all { cont.resume(returning: all) }
            }
            health.execute(q)
        }
        let start: Date = w.startDate
        return locations.sorted { $0.timestamp < $1.timestamp }
            .map { RoutePoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, t: $0.timestamp.timeIntervalSince(start), run: true) }
    }
}
