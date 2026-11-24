import Foundation
import HealthKit

/// What Workouts' Start can track with GPS (26 Nov, design/start-anything-mockup.html): a run, a ride, a walk or a
/// hike. Each is the same screen: the map, the clock (moving time: it pauses itself when they stop), distance, and
/// pace, or speed for a ride. Saved to Workouts and Apple Health with its route.
enum MoveKind: String, CaseIterable, Identifiable {
    case run, ride, walk, hike
    var id: String { rawValue }

    var title: String {
        switch self {
        case .run: "Run"
        case .ride: "Ride"
        case .walk: "Walk"
        case .hike: "Hike"
        }
    }
    /// The heading while it's going.
    var doing: String {
        switch self {
        case .run: "Running"
        case .ride: "Riding"
        case .walk: "Walking"
        case .hike: "Hiking"
        }
    }
    /// The workout's type in the app (Activities.all's names).
    var type: String {
        switch self {
        case .run: "Run"
        case .ride: "Cycle"
        case .walk: "Walk"
        case .hike: "Hike"
        }
    }
    var symbol: String {
        switch self {
        case .run: "figure.run"
        case .ride: "figure.outdoor.cycle"
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        }
    }
    /// Under its tile on the Start sheet.
    var shows: String {
        switch self {
        case .run, .walk: "map · pace"
        case .ride: "map · speed"
        case .hike: "map · height climbed"
        }
    }
    /// A ride shows km/h; the rest minutes a kilometre.
    var speed: Bool { self == .ride }
    var hk: HKWorkoutActivityType {
        switch self {
        case .run: .running
        case .ride: .cycling
        case .walk: .walking
        case .hike: .hiking
        }
    }
    /// The distance Health keeps for it: cycling has its own.
    var distance: HKQuantityType {
        self == .ride ? HKQuantityType(.distanceCycling) : HKQuantityType(.distanceWalkingRunning)
    }
    /// Under this speed (metres a second) for a few seconds, they've stopped: about 1.8 km/h on foot, 5.4 on a bike.
    var stopBelow: Double { self == .ride ? 1.5 : 0.5 }
    /// A word every so many kilometres.
    var sayEvery: Int { self == .ride ? 5 : 1 }

    /// kcal for the moving time. Mapped, from the speed (and for a hike, the climb); not mapped, the activity's usual
    /// rate for the time.
    func kcal(seconds: Double, meters: Double, climb: Double, kg: Double) -> Double {
        guard seconds > 0 else { return 0 }
        let hours: Double = seconds / 3600
        switch self {
        case .run:
            return RunStart.freeKcal(seconds: seconds, meters: meters, kg: kg)
        case .ride:
            let met: Double = meters >= 200 ? Self.rideMET(kmh: meters / 1000 / hours) : (Activities.all.first { $0.name == "Cycle" }?.met ?? 7.5)
            return (met * kg * hours).rounded()
        case .walk, .hike:
            let base: Double = self == .hike ? 6 : 3.5
            var met: Double = base
            if meters >= 200 {
                let kmh: Double = meters / 1000 / hours
                // walking pace: about 3.5 at 4 km/h, more as it quickens; a hike's rough ground on top
                met = (3.5 + max(0, kmh - 4) * 0.6) + (self == .hike ? 1.5 : 0)
            }
            // lifting yourself up: about 0.0094 kcal a kilo a metre climbed (a quarter of the work is useful)
            return (met * kg * hours + max(0, climb) * kg * 0.0094).rounded()
        }
    }

    /// Cycling's MET by speed (the Compendium's bands): leisurely to racing.
    static func rideMET(kmh: Double) -> Double {
        switch kmh {
        case ..<16: 4
        case ..<19: 6.8
        case ..<22.5: 8
        case ..<25.5: 10
        case ..<30: 12
        default: 15.8
        }
    }
}

/// The clock pausing itself at the lights: under the stop speed for a few seconds pauses, moving again carries on.
/// Not until they've first got going, and a lost fix (no speed) changes nothing.
struct AutoPause {
    let stopBelow: Double
    var holdToPause: TimeInterval = 5
    var holdToGo: TimeInterval = 2
    private(set) var paused = false
    private var moved = false
    private var since: Date?

    init(stopBelow: Double) { self.stopBelow = stopBelow }

    /// The latest speed (m/s, nil when there's none); returns whether the clock should be paused now.
    mutating func update(speed: Double?, at now: Date) -> Bool {
        guard let speed, speed >= 0 else { return paused }
        let going: Bool = speed >= (paused ? stopBelow * 1.5 : stopBelow)
        if going { moved = true }
        guard moved else { return false }
        // the change it'd be: it holds for long enough before it happens
        let change: Bool = paused ? going : !going
        if !change { since = nil; return paused }
        let start: Date = since ?? now
        since = start
        if now.timeIntervalSince(start) >= (paused ? holdToGo : holdToPause) { paused.toggle(); since = nil }
        return paused
    }
}

extension RouteMath {
    /// Metres climbed: rises added up once they're 3 m or more, so GPS height wobble isn't counted.
    static func climb(_ p: [RoutePoint]) -> Double {
        var total: Double = 0
        var low: Double?
        for pt in p {
            guard let a = pt.alt else { continue }
            guard let l = low else { low = a; continue }
            if a < l { low = a } else if a - l >= 3 { total += a - l; low = a }
        }
        return total
    }
}

/// Two workouts' times: how much they share, as a share of the shorter one.
enum Overlap {
    static func fraction(_ a: (start: Date, end: Date), _ b: (start: Date, end: Date)) -> Double {
        let shorter: Double = min(a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
        guard shorter > 0 else { return 0 }
        let shared: Double = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
        return max(0, shared) / shorter
    }

    /// The same workout twice: the same kind, and more than half of it at the same time.
    static func same(_ a: (type: String, start: Date, end: Date), _ b: (type: String, start: Date, end: Date)) -> Bool {
        a.type == b.type && fraction((a.start, a.end), (b.start, b.end)) > 0.5
    }

    /// A workout's start and end, from what it saved; nil for older ones that didn't.
    static func window(_ w: JSON) -> (start: Date, end: Date)? {
        guard let s = ISO.date(str(w["start"])), let e = ISO.date(str(w["end"])), e > s else { return nil }
        return (s, e)
    }
}

/// Heart rate zones from a maximum (220 minus age unless they've set their own), five of them.
enum HeartZones {
    static let names: [String] = ["Easy", "Steady", "Hard", "Very hard", "Max"]

    static func max(age: Double) -> Int { Int((220 - age).rounded()) }

    /// 1 to 5: under 60% of max is easy, then a zone each 10%.
    static func zone(bpm: Double, max: Int) -> Int {
        guard max > 0 else { return 1 }
        let f: Double = bpm / Double(max)
        switch f {
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.8: return 3
        case ..<0.9: return 4
        default: return 5
        }
    }

    /// Seconds in each zone: each reading counts until the next (no more than 30 s, so a gap isn't filled in).
    static func seconds(_ s: [HRSample], max: Int) -> [Double] {
        var out: [Double] = Array(repeating: 0, count: 5)
        for i in s.indices {
            let next: Double = i + 1 < s.count ? s[i + 1].t : s[i].t + 5
            out[zone(bpm: s[i].bpm, max: max) - 1] += Swift.min(30, Swift.max(0, next - s[i].t))
        }
        return out
    }

    /// The line on an easy run's screen.
    static func runLine(bpm: Double, max: Int) -> String {
        let z: Int = zone(bpm: bpm, max: max)
        return z >= 3 ? "\(names[z - 1]). Easy runs sit lower: slow down a little" : "\(names[z - 1]). Right for an easy run"
    }
}

/// Steps the walking burn shouldn't count again: those taken during a run, walk or hike that's logged with its own kcal.
extension Steps {
    /// (the same 0.4 kcal a step for every 1,000 kg as kcal(steps:kg:))
    nonisolated static func kcal(steps: Int, tracked: Int, kg: Double) -> Double {
        (Double(max(0, steps - tracked)) * kg * 0.0004).rounded()
    }
}

/// Logging what Start tracked or timed, and one entry when a watch recorded the same workout (26 Nov,
/// design/heart-rate-mockup.html): the route from here, the heart rate and calories from the watch.
extension Store {
    /// A run, ride, walk or hike tracked here: its start and end (for heart rate and the watch), its distance, each
    /// kilometre, the climb, and the route and strap readings in files on the phone only. Returns the workout's id.
    @discardableResult
    func logMove(_ kind: MoveKind, start: Date, end: Date, seconds: Double, route: [RoutePoint], kcal: Double, heart: [HRSample]) -> String {
        var w: JSON = ["type": kind.type, "name": kind.title, "minutes": max(1, Int((seconds / 60).rounded())), "effort": "moderate",
                       "kcal": kcal, "lifts": [Any](), "at": ISO.now(), "start": ISO.at(start), "end": ISO.at(end), "tracked": true]
        let meters: Double = RouteMath.meters(route)
        if route.count > 1 && meters >= 50 {
            w["km"] = (meters / 10).rounded() / 100
            w["splits"] = RouteMath.splits(route).map { (s: (km: Double, seconds: Double)) -> JSON in ["km": (s.km * 100).rounded() / 100, "s": s.seconds.rounded()] }
            let up: Double = RouteMath.climb(route)
            if up >= 1 { w["climb"] = up.rounded() }
        }
        return logTracked(w, route: route, heart: heart)
    }

    /// A class, swim or session timed here with Just time it.
    @discardableResult
    func logTimed(type: String, name: String, start: Date, end: Date, seconds: Double, effort: String, kcal: Double, heart: [HRSample]) -> String {
        let w: JSON = ["type": type, "name": name, "minutes": max(1, Int((seconds / 60).rounded())), "effort": effort, "kcal": kcal,
                       "lifts": [Any](), "at": ISO.now(), "start": ISO.at(start), "end": ISO.at(end), "tracked": true]
        return logTracked(w, route: [], heart: heart)
    }

    /// In it goes, with its files. A watch's copy from Health that came in first is taken in, not kept as a second.
    private func logTracked(_ workout: JSON, route: [RoutePoint], heart: [HRSample]) -> String {
        var w: JSON = workout
        let id: String = uid()
        w["id"] = id
        if let s = HeartData.summary(heart) { w["hrAvg"] = s.avg; w["hrMax"] = s.max }
        if let mine = Overlap.window(w) {
            for h in todayWorkouts where str(h["from"]) == "health" && str(h["type"]) == str(w["type"]) {
                if let theirs = Overlap.window(h) {
                    guard Overlap.same((str(w["type"]), mine.start, mine.end), (str(h["type"]), theirs.start, theirs.end)) else { continue }
                } else if !(str(w["type"]) == "Run" && str(h["type"]) == "Run") {
                    continue   // (an older copy without its times: only a run, as before)
                }
                Self.takeWatch(h, into: &w)
                deleteWorkout(str(h["id"]))
            }
        }
        if route.count > 1 && RouteMath.meters(route) >= 50 { RouteStore.save(route, id: id) }
        HeartStore.save(heart, id: id)
        perform(["type": "logWorkout", "workout": w])
        return id
    }

    /// The watch's numbers onto the workout tracked here: its calories (ours kept to say what they replaced), and
    /// its heart rate when there's none from a strap.
    static func takeWatch(_ watch: JSON, into w: inout JSON) {
        if str(watch["kcalFrom"]) == "watch", let k = num(watch["kcal"]), k > 0 {
            w["kcalGuess"] = w["kcal"] ?? 0; w["kcal"] = k; w["kcalFrom"] = "watch"
        }
        if w["hrAvg"] == nil, let a = watch["hrAvg"] { w["hrAvg"] = a; w["hrMax"] = watch["hrMax"] ?? NSNull() }
        w["watch"] = true
    }

    /// One tracked here, given what a watch saved for the same time: logged again with the watch's numbers (a
    /// workout can't be changed in place), its files moved over to the new id.
    func adoptWatch(_ own: JSON, date: String, kcal: Double?, hr: (avg: Int, max: Int)?) {
        var w: JSON = own
        let old: String = str(own["id"]), id: String = uid()
        w["id"] = id; w["watch"] = true
        if let kcal, kcal > 0 { w["kcalGuess"] = own["kcal"] ?? 0; w["kcal"] = kcal; w["kcalFrom"] = "watch" }
        if let hr, own["hrAvg"] == nil { w["hrAvg"] = hr.avg; w["hrMax"] = hr.max }
        if let r = RouteStore.load(old) { RouteStore.save(r, id: id) }
        if let h = HeartStore.load(old) { HeartStore.save(h, id: id) }
        deleteWorkout(old)
        var op: JSON = ["type": "logWorkout", "workout": w]
        if date < today { op["date"] = date }
        perform(op)
    }
}

/// Watch workouts matched to the ones tracked here (26 Nov): for today's and yesterday's, a Health workout of the same
/// kind over the same time (more than half of it) gives its calories and heart rate, and isn't brought in as a
/// second. Without one, active energy a watch saved in that time is used for the calories.
extension HealthSync {
    static func matchWatch() async {
        let store = Store.shared
        guard available, heartAsked else { return }
        for date in [DayKey.shift(store.today, days: -1), store.today] {
            for w in store.workouts(on: date) where w["tracked"] as? Bool == true && w["watch"] == nil && w["kcalFrom"] == nil {
                guard let win = Overlap.window(w), Date().timeIntervalSince(win.end) > 60 else { continue }
                let theirs: [HKWorkout] = await workouts(from: win.start.addingTimeInterval(-3600), to: win.end.addingTimeInterval(3600))
                let match: HKWorkout? = theirs.first { h in
                    h.sourceRevision.source != HKSource.default()
                        && Overlap.same((str(w["type"]), win.start, win.end), (planType(h.workoutActivityType) ?? "", h.startDate, h.endDate))
                }
                let hr: [HRSample] = await heartRate(from: win.start, to: win.end)
                let summary: (avg: Int, max: Int)? = HeartData.summary(hr)
                if let match {
                    var seen: [String] = UserDefaults.standard.stringArray(forKey: "health.ticked") ?? []
                    seen.append(match.uuid.uuidString)
                    UserDefaults.standard.set(seen, forKey: "health.ticked")
                    let k: Double? = match.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
                    store.adoptWatch(w, date: date, kcal: k.map { $0.rounded() }, hr: summary)
                } else if let k = await watchKcal(from: win.start, to: win.end) {
                    store.adoptWatch(w, date: date, kcal: k, hr: summary)
                }
            }
        }
    }

    /// Health workouts that started in a time.
    static func workouts(from start: Date, to end: Date) async -> [HKWorkout] {
        await withCheckedContinuation { (cont: CheckedContinuation<[HKWorkout], Never>) in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            health.execute(q)
        }
    }
}
