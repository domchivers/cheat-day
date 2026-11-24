import HealthKit

/// Start running's run as a real workout (25 Nov): an Apple Health workout session, as Apple's Workout app runs, so the
/// app keeps going with the phone locked in a pocket (the timer and its voice carry on), and the finished run is saved
/// to Apple Health. iPhone workout sessions need iOS 26 (1.4.54 didn't compile on 17); before that, and without Health
/// or the OK to save, the timer works as before with notifications when locked. The route still goes to Health with
/// the run saved on its own (HKWorkoutRouteBuilder is older).
@MainActor
final class RunSession {
    /// HKWorkoutSession and HKLiveWorkoutBuilder, kept untyped: both are iOS 26 on iPhone, the app is iOS 17.
    private var session: AnyObject?
    private var builder: AnyObject?
    /// Without a session (before iOS 26): when it started, to save the run to Health as a plain workout at the end.
    private var plainStart: Date?
    /// The run's route for Apple Health, filled by RunTracker as it goes.
    private(set) var routeBuilder: HKWorkoutRouteBuilder?
    /// Running as a workout: the app stays awake, so the lock-screen notifications aren't needed.
    var live: Bool { session != nil }

    /// Ask to save workouts (Health's sheet shows only the first time), then start. True when it's a live workout
    /// session; false when it's the plain timer (it may still save to Health at the end).
    func start() async -> Bool {
        guard HealthSync.available, !ProcessInfo.processInfo.arguments.contains("-uitest-runtimer") else { return false }
        let type: HKWorkoutType = HKObjectType.workoutType()
        let route: HKSeriesType = HKSeriesType.workoutRoute()
        do { try await HealthSync.health.requestAuthorization(toShare: [type, route], read: [type, route]) } catch { return false }
        guard HealthSync.health.authorizationStatus(for: type) == .sharingAuthorized else { return false }
        // the route goes with it, when they map their runs and Health may keep routes
        if RunTracker.wanted && HealthSync.health.authorizationStatus(for: route) == .sharingAuthorized {
            routeBuilder = HKWorkoutRouteBuilder(healthStore: HealthSync.health, device: nil)
        }
        plainStart = Date()
        if #available(iOS 26.0, *) { return startSession() }
        return false
    }

    @available(iOS 26.0, *)
    private func startSession() -> Bool {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        do {
            let s = try HKWorkoutSession(healthStore: HealthSync.health, configuration: config)
            let b: HKLiveWorkoutBuilder = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: HealthSync.health, workoutConfiguration: config)
            let now = Date()
            s.startActivity(with: now)
            b.beginCollection(withStart: now) { _, _ in }
            session = s; builder = b
            return true
        } catch {
            return false
        }
    }

    func pause() {
        if #available(iOS 26.0, *) { (session as? HKWorkoutSession)?.pause() }
    }
    func resume() {
        if #available(iOS 26.0, *) { (session as? HKWorkoutSession)?.resume() }
    }

    /// Done (or ended and kept): saved to Health as a workout, with its route. It's marked as already counted, so
    /// Health's copy doesn't come back in as a second run.
    func finish() {
        let r: HKWorkoutRouteBuilder? = routeBuilder
        let now = Date()
        if #available(iOS 26.0, *), let s = session as? HKWorkoutSession, let b = builder as? HKLiveWorkoutBuilder {
            s.end()
            b.endCollection(withEnd: now) { _, _ in
                b.finishWorkout { workout, _ in
                    guard let workout else { return }
                    RunSession.saved(workout, route: r)
                }
            }
        } else if let start = plainStart {
            // the plain timer: the run saved as a workout of its own, from when it started to now
            let config = HKWorkoutConfiguration()
            config.activityType = .running
            config.locationType = .outdoor
            let b = HKWorkoutBuilder(healthStore: HealthSync.health, configuration: config, device: .local())
            b.beginCollection(withStart: start) { _, _ in
                b.endCollection(withEnd: now) { _, _ in
                    b.finishWorkout { workout, _ in
                        guard let workout else { return }
                        RunSession.saved(workout, route: r)
                    }
                }
            }
        }
        session = nil; builder = nil; routeBuilder = nil; plainStart = nil
    }

    /// Thrown away: nothing saved.
    func discard() {
        if #available(iOS 26.0, *) {
            (session as? HKWorkoutSession)?.end()
            (builder as? HKLiveWorkoutBuilder)?.discardWorkout()
        }
        routeBuilder?.discard()
        session = nil; builder = nil; routeBuilder = nil; plainStart = nil
    }

    /// A run saved to Health: its route added, and its id kept as counted.
    nonisolated private static func saved(_ workout: HKWorkout, route: HKWorkoutRouteBuilder?) {
        route?.finishRoute(with: workout, metadata: nil) { _, _ in }
        let id: String = workout.uuid.uuidString
        DispatchQueue.main.async {
            var seen: [String] = UserDefaults.standard.stringArray(forKey: "health.ticked") ?? []
            seen.append(id)
            UserDefaults.standard.set(seen, forKey: "health.ticked")
        }
    }
}
