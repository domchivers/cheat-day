import CoreLocation
import HealthKit

/// Follows a timed run with GPS (25 Nov, design/run-route-mockup.html): only once they've said yes to mapping their
/// runs, only while the app times one, precise for that run only (the app is otherwise approximate). Keeps the route,
/// the distance and the pace; the points also go to Apple Health's route for the workout. Locked, it carries on:
/// the run is a workout session, and the blue location pill shows it's in use.
@MainActor final class RunTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authWait: CheckedContinuation<Void, Never>?
    private(set) var points: [RoutePoint] = []
    private(set) var meters: Double = 0
    private(set) var fix: CLLocation?
    /// Points are only kept while recording (started, not paused).
    private(set) var recording = false
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedFor: TimeInterval = 0
    private var gapNext = false
    /// Whether the part they're in is a running one, for the line's colour.
    var running = false
    /// Apple Health's route for the workout, when the run's a workout session.
    var healthRoute: HKWorkoutRouteBuilder?

    /// Asked once, before the first timed run: map runs or not.
    static var asked: Bool {
        get { UserDefaults.standard.bool(forKey: "run.mapAsked") }
        set { UserDefaults.standard.set(newValue, forKey: "run.mapAsked") }
    }
    static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: "run.map") }
        set { UserDefaults.standard.set(newValue, forKey: "run.map") }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// GPS on, ahead of Start so it has a fix: asks for location (when in use) and, for this run, precise.
    /// False if they've said no.
    func warm() async -> Bool {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in authWait = c; manager.requestWhenInUseAuthorization() }
        }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return false }
        if manager.accuracyAuthorization == .reducedAccuracy {
            _ = try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "RunRoute")
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        return true
    }

    /// A good fix: close enough, and recent.
    var ready: Bool {
        guard let f = fix else { return false }
        return f.horizontalAccuracy > 0 && f.horizontalAccuracy <= 25 && -f.timestamp.timeIntervalSinceNow < 10
    }
    /// Precise wasn't allowed: only rough positions come, so there's no route to draw.
    var rough: Bool { manager.accuracyAuthorization == .reducedAccuracy }

    func start() { startedAt = Date(); pausedFor = 0; pausedAt = nil; recording = true; gapNext = false }
    func pause() { pausedAt = Date(); recording = false }
    func resume() {
        if let p = pausedAt { pausedFor += Date().timeIntervalSince(p) }
        pausedAt = nil; recording = true; gapNext = true
    }
    func stop() {
        recording = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private var clock: Double {
        guard let s = startedAt else { return 0 }
        return max(0, (pausedAt ?? Date()).timeIntervalSince(s) - pausedFor)
    }

    /// Seconds a kilometre over about the last half minute; nil when there's not enough to go on.
    var pace: Double? {
        guard let last = points.last else { return nil }
        guard let from = points.last(where: { last.t - $0.t >= 30 }) ?? points.first, last.t - from.t >= 10 else { return nil }
        let slice: [RoutePoint] = Array(points.drop { $0.t < from.t })
        let m: Double = RouteMath.meters(slice)
        guard m >= 20 else { return nil }
        return (last.t - from.t) / m * 1000
    }

    private func took(_ l: CLLocation) {
        guard l.horizontalAccuracy > 0, l.horizontalAccuracy <= 30, -l.timestamp.timeIntervalSinceNow < 15 else { return }
        fix = l
        guard recording, !rough else { return }
        let p = RoutePoint(lat: l.coordinate.latitude, lon: l.coordinate.longitude, t: clock, run: running, gap: gapNext)
        if let prev = points.last, !gapNext {
            let d: Double = l.distance(from: prev.location), dt: Double = max(0.5, p.t - prev.t)
            if d < 2 { return }              // standing still: GPS wander
            if d / dt > 12 { return }        // faster than a sprinter: a bad fix
            meters += d
        }
        gapNext = false
        points.append(p)
        healthRoute?.insertRouteData([l]) { _, _ in }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s: CLAuthorizationStatus = m.authorizationStatus
        Task { @MainActor in if s != .notDetermined, let c = self.authWait { self.authWait = nil; c.resume() } }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations ls: [CLLocation]) {
        Task { @MainActor in for l in ls { self.took(l) } }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
