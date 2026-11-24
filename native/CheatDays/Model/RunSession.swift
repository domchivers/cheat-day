import HealthKit

/// Start running's run as a real workout (25 Nov): an Apple Health workout session, as Apple's Workout app runs, so the
/// app keeps going with the phone locked in a pocket (the timer and its voice carry on), and the finished run is saved
/// to Apple Health. Without Health, or if it's not allowed, the timer works as before, with notifications when locked.
@MainActor
final class RunSession {
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// Running as a workout: the app stays awake, so the lock-screen notifications aren't needed.
    var live: Bool { session != nil }

    /// Ask to save workouts (Health's sheet shows only the first time), then start. False if it couldn't.
    func start() async -> Bool {
        guard HealthSync.available, !ProcessInfo.processInfo.arguments.contains("-uitest-runtimer") else { return false }
        let type: HKWorkoutType = HKObjectType.workoutType()
        do { try await HealthSync.health.requestAuthorization(toShare: [type], read: [type]) } catch { return false }
        guard HealthSync.health.authorizationStatus(for: type) == .sharingAuthorized else { return false }
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

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    /// Done (or ended and kept): saved to Health as a workout. It's marked as already counted, so Health's copy
    /// doesn't come back in as a second run.
    func finish() {
        guard let s = session, let b = builder else { return }
        let now = Date()
        s.end()
        b.endCollection(withEnd: now) { _, _ in
            b.finishWorkout { workout, _ in
                guard let id = workout?.uuid.uuidString else { return }
                DispatchQueue.main.async {
                    var seen: [String] = UserDefaults.standard.stringArray(forKey: "health.ticked") ?? []
                    seen.append(id)
                    UserDefaults.standard.set(seen, forKey: "health.ticked")
                }
            }
        }
        session = nil; builder = nil
    }

    /// Thrown away: nothing saved.
    func discard() {
        session?.end()
        builder?.discardWorkout()
        session = nil; builder = nil
    }
}
