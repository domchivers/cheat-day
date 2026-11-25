import Foundation
import CoreLocation

/// Matched routes (26 Nov, design/matched-routes-mockup.html): a run, ride, walk or hike mapped with Start that's
/// the same way as one before. Shown from the second time. Found on the phone, from the routes saved there.
/// The same route: starts and finishes within 200 m of it (either way round: the owner, 26 Nov), within a tenth of its
/// distance, and four fifths of each within 50 m of the other.
enum RouteMatch {
    static let ends: Double = 200
    static let near: Double = 50
    static let share: Double = 0.8

    /// Flat metres (east, north) from a point: plenty for routes a few km across.
    private static func flat(_ p: RoutePoint, lat0: Double) -> (x: Double, y: Double) {
        (p.lon * 111_195 * cos(lat0 * .pi / 180), p.lat * 111_195)
    }

    /// A point about every `every` metres along the route, as flat metres.
    static func samples(_ p: [RoutePoint], every: Double, lat0: Double) -> [(x: Double, y: Double)] {
        guard let first = p.first else { return [] }
        var out: [(x: Double, y: Double)] = [flat(first, lat0: lat0)]
        var since: Double = 0
        for i in 1..<max(1, p.count) {
            let a = flat(p[i - 1], lat0: lat0), b = flat(p[i], lat0: lat0)
            since += p[i].gap ? 0 : hypot(b.x - a.x, b.y - a.y)
            if since >= every || i == p.count - 1 { out.append(b); since = 0 }
        }
        return out
    }

    /// The share of `xs` within `within` metres of one of `ys`.
    static func covered(_ xs: [(x: Double, y: Double)], by ys: [(x: Double, y: Double)], within: Double) -> Double {
        guard !xs.isEmpty, !ys.isEmpty else { return 0 }
        let w2: Double = within * within
        var hit: Int = 0
        for a in xs where ys.contains(where: { (b: (x: Double, y: Double)) -> Bool in (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) <= w2 }) { hit += 1 }
        return Double(hit) / Double(xs.count)
    }

    static func same(_ a: [RoutePoint], _ b: [RoutePoint]) -> Bool {
        let ma: Double = RouteMath.meters(a), mb: Double = RouteMath.meters(b)
        guard ma >= 300, mb >= 300, abs(ma - mb) <= 0.1 * max(ma, mb) else { return false }
        guard let a0 = a.first?.location, let a1 = a.last?.location, let b0 = b.first?.location, let b1 = b.last?.location else { return false }
        let forward: Bool = a0.distance(from: b0) <= ends && a1.distance(from: b1) <= ends
        let back: Bool = a0.distance(from: b1) <= ends && a1.distance(from: b0) <= ends
        guard forward || back else { return false }
        // about every 50 m, fewer on a long ride (a thousand at most); the nearness widens with the spacing
        let every: Double = max(near, max(ma, mb) / 1000)
        let lat0: Double = a[0].lat
        let sa = samples(a, every: every, lat0: lat0), sb = samples(b, every: every, lat0: lat0)
        let within: Double = max(near, every)
        return covered(sa, by: sb, within: within) >= share && covered(sb, by: sa, within: within) >= share
    }

    /// "2nd", "3rd", "11th"
    static func ordinal(_ n: Int) -> String {
        let tens: Int = n % 100
        let suffix: String = (11...13).contains(tens) ? "th" : (n % 10 == 1 ? "st" : n % 10 == 2 ? "nd" : n % 10 == 3 ? "rd" : "th")
        return "\(n)\(suffix)"
    }

    /// Which route each workout is on ("" for none, or no map), its moving seconds and km, kept on the phone so each
    /// route is read once; and the routes' names.
    fileprivate static var groupOf: [String: String] = UserDefaults.standard.dictionary(forKey: "routes.group") as? [String: String] ?? [:]
    fileprivate static var secondsOf: [String: Double] = UserDefaults.standard.dictionary(forKey: "routes.seconds") as? [String: Double] ?? [:]
    fileprivate static var names: [String: String] = UserDefaults.standard.dictionary(forKey: "routes.names") as? [String: String] ?? [:]
    fileprivate static func keep() {
        UserDefaults.standard.set(groupOf, forKey: "routes.group")
        UserDefaults.standard.set(secondsOf, forKey: "routes.seconds")
    }

    static func name(_ group: String) -> String? { names[group] }
    static func rename(_ group: String, to name: String) {
        let n: String = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !n.isEmpty else { return }
        names[group] = n
        UserDefaults.standard.set(names, forKey: "routes.names")
    }

    /// A route's name from Apple Maps: the park or place where it starts, else its suburb. Once per route.
    static func nameIfNeeded(_ g: RouteGroup) async {
        guard names[g.id] == nil, let first = g.runs.first, let p = RouteStore.load(first.id)?.first else { return }
        let placemarks: [CLPlacemark] = (try? await CLGeocoder().reverseGeocodeLocation(p.location)) ?? []
        guard let pm = placemarks.first, let n = pm.areasOfInterest?.first ?? pm.subLocality ?? pm.locality else { return }
        await MainActor.run { if names[g.id] == nil { rename(g.id, to: n) } }
    }
}

/// One time on a route.
struct RouteRun: Identifiable {
    let workout: JSON
    let date: String
    let seconds: Double
    var id: String { str(workout["id"]) }
    var km: Double { num(workout["km"]) ?? 0 }
}

/// A route done twice or more: its times, oldest first.
struct RouteGroup: Identifiable {
    let id: String
    let kind: MoveKind
    let runs: [RouteRun]

    var name: String { RouteMatch.name(id) ?? "\(kind.title) route" }
    var km: Double { runs.last?.km ?? 0 }
    var best: RouteRun? { runs.min { $0.seconds < $1.seconds } }
    func index(of id: String) -> Int? { runs.firstIndex { $0.id == id } }
    /// "2nd of 4" by time
    func place(of id: String) -> Int? {
        guard let r = runs.first(where: { $0.id == id }) else { return nil }
        return runs.filter { $0.seconds < r.seconds }.count + 1
    }
}

extension Store {
    /// Every run, ride, walk and hike with a map, oldest first, each with its route; matched to the ones before it.
    func routeGroups() -> [RouteGroup] {
        let now: String = today
        var all: [(date: String, workout: JSON)] = allPastWorkouts.map { (p: (date: String, index: Int, workout: JSON)) -> (date: String, workout: JSON) in (p.date, p.workout) }
        all += todayWorkouts.map { (w: JSON) -> (date: String, workout: JSON) in (now, w) }
        all.sort { (a: (date: String, workout: JSON), b: (date: String, workout: JSON)) -> Bool in a.date < b.date || (a.date == b.date && str(a.workout["at"]) < str(b.workout["at"])) }
        var members: [String: [RouteRun]] = [:]
        var kinds: [String: MoveKind] = [:]
        var order: [String] = []
        var changed: Bool = false
        for m in all {
            guard let kind = Bests.kind(m.workout) else { continue }
            let id: String = str(m.workout["id"])
            guard !id.isEmpty else { continue }
            var group: String? = RouteMatch.groupOf[id]
            if group == nil {
                // new to this: its route, matched against each route of its kind so far (either way round)
                if let r = RouteStore.load(id), r.count > 1 {
                    RouteMatch.secondsOf[id] = r.last?.t ?? 0
                    group = order.first { (g: String) -> Bool in
                        guard kinds[g] == kind, let rep = members[g]?.first, let rr = RouteStore.load(rep.id) else { return false }
                        return RouteMatch.same(r, rr)
                    } ?? id
                } else { group = "" }
                RouteMatch.groupOf[id] = group
                changed = true
            }
            guard let g = group, !g.isEmpty else { continue }
            if members[g] == nil { order.append(g); kinds[g] = kind }
            members[g, default: []].append(RouteRun(workout: m.workout, date: m.date, seconds: RouteMatch.secondsOf[id] ?? 0))
        }
        if changed { RouteMatch.keep() }
        return order.compactMap { (g: String) -> RouteGroup? in
            guard let runs = members[g], runs.count >= 2, let k = kinds[g] else { return nil }
            return RouteGroup(id: g, kind: k, runs: runs)
        }
    }

    /// The route a workout's on, when it's been done twice or more.
    func routeGroup(for id: String) -> RouteGroup? { routeGroups().first { $0.runs.contains { $0.id == id } } }
}
