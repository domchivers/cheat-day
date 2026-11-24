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
    /// What it is in Health (26 Nov: a ride, walk, hike or a timed class too), outdoors with a route or not, and the
    /// distance Health keeps for it (cycling has its own; none for a class).
    var activity: HKWorkoutActivityType = .running
    var outdoor: Bool = true
    var distanceType: HKQuantityType? = HKQuantityType(.distanceWalkingRunning)

    init(activity: HKWorkoutActivityType = .running, outdoor: Bool = true, distanceType: HKQuantityType? = HKQuantityType(.distanceWalkingRunning)) {
        self.activity = activity; self.outdoor = outdoor; self.distanceType = distanceType
    }

    private func configuration() -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        config.locationType = outdoor ? .outdoor : .indoor
        return config
    }

    /// Ask to save workouts (Health's sheet shows only the first time), then start. True when it's a live workout
    /// session; false when it's the plain timer (it may still save to Health at the end).
    func start() async -> Bool {
        guard HealthSync.available, !RunTimerView.uiTest else { return false }
        let type: HKWorkoutType = HKObjectType.workoutType()
        let route: HKSeriesType = HKSeriesType.workoutRoute()
        // (26 Nov, the owner: the saved run carries its distance and active energy too)
        var share: Set<HKSampleType> = [type, HKQuantityType(.activeEnergyBurned)]
        if outdoor { share.insert(route) }
        if let d = distanceType { share.insert(d) }
        // heart rate read with it (26 Nov), for the workout page afterwards
        let read: Set<HKObjectType> = [type, route, HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
        do { try await HealthSync.health.requestAuthorization(toShare: share, read: read) } catch { return false }
        UserDefaults.standard.set(true, forKey: "health.heartAsked")
        guard HealthSync.health.authorizationStatus(for: type) == .sharingAuthorized else { return false }
        // the route goes with it, when they map their runs and Health may keep routes
        if outdoor && RunTracker.wanted && HealthSync.health.authorizationStatus(for: route) == .sharingAuthorized {
            routeBuilder = HKWorkoutRouteBuilder(healthStore: HealthSync.health, device: nil)
        }
        plainStart = Date()
        // (a swim without its pool length or open water can't be a live session; it's saved at the end)
        if #available(iOS 26.0, *), activity != .swimming { return startSession() }
        return false
    }

    @available(iOS 26.0, *)
    private func startSession() -> Bool {
        let config: HKWorkoutConfiguration = configuration()
        do {
            let s = try HKWorkoutSession(healthStore: HealthSync.health, configuration: config)
            let b: HKLiveWorkoutBuilder = s.associatedWorkoutBuilder()
            let source = HKLiveWorkoutDataSource(healthStore: HealthSync.health, workoutConfiguration: config)
            // distance and energy are added once at the end, from the route and the app's own kcal, so not twice
            if let d = distanceType { source.disableCollection(for: d) }
            source.disableCollection(for: HKQuantityType(.activeEnergyBurned))
            b.dataSource = source
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

    /// Done (or ended and kept): saved to Health as a workout, with its distance (when mapped), active energy (the
    /// kcal the app logs) and route. It's marked as already counted, so Health's copy doesn't come back in as a
    /// second run.
    func finish(meters: Double, kcal: Double) {
        let r: HKWorkoutRouteBuilder? = routeBuilder
        let now = Date()
        let samples: [HKSample] = RunSession.samples(meters: meters, kcal: kcal, distance: distanceType, start: plainStart ?? now, end: now)
        if #available(iOS 26.0, *), let s = session as? HKWorkoutSession, let b = builder as? HKLiveWorkoutBuilder {
            s.end()
            RunSession.close(b, samples: samples, end: now, route: r)
        } else if let start = plainStart {
            // the plain timer: the run saved as a workout of its own, from when it started to now
            let config: HKWorkoutConfiguration = configuration()
            let b = HKWorkoutBuilder(healthStore: HealthSync.health, configuration: config, device: .local())
            b.beginCollection(withStart: start) { _, _ in
                RunSession.close(b, samples: samples, end: now, route: r)
            }
        }
        session = nil; builder = nil; routeBuilder = nil; plainStart = nil
    }

    /// The run's distance and energy as Health samples, each only when Health may keep it and there's something to say.
    private static func samples(meters: Double, kcal: Double, distance d: HKQuantityType?, start: Date, end: Date) -> [HKSample] {
        guard end > start else { return [] }
        var out: [HKSample] = []
        let energy = HKQuantityType(.activeEnergyBurned)
        if let distance = d, meters >= 50, HealthSync.health.authorizationStatus(for: distance) == .sharingAuthorized {
            out.append(HKQuantitySample(type: distance, quantity: HKQuantity(unit: .meter(), doubleValue: meters), start: start, end: end))
        }
        if kcal > 0, HealthSync.health.authorizationStatus(for: energy) == .sharingAuthorized {
            out.append(HKQuantitySample(type: energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: start, end: end))
        }
        return out
    }

    /// Samples in, collection ended, workout saved (a live builder is an HKWorkoutBuilder too).
    nonisolated private static func close(_ b: HKWorkoutBuilder, samples: [HKSample], end: Date, route: HKWorkoutRouteBuilder?) {
        let wrapUp = {
            b.endCollection(withEnd: end) { _, _ in
                b.finishWorkout { workout, _ in
                    guard let workout else { return }
                    RunSession.saved(workout, route: route)
                }
            }
        }
        if samples.isEmpty { wrapUp() } else { b.add(samples) { _, _ in wrapUp() } }
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
