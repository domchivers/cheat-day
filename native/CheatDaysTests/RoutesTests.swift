import XCTest
@testable import CheatDays

/// Matched routes (26 Nov, design/matched-routes-mockup.html).
final class RoutesTests: XCTestCase {
    /// A loop of this radius (m) around a point, a point every 5°, starting due east; moved north by `shift` metres.
    private func loop(radius: Double, shift: Double = 0, east: Double = 0) -> [RoutePoint] {
        let m: Double = 1 / 111_195.0, lat0: Double = -37.85, lon0: Double = 144.97
        let k: Double = cos(lat0 * .pi / 180)
        return (0...72).map { (i: Int) -> RoutePoint in
            let a: Double = Double(i) * 5 * .pi / 180
            return RoutePoint(lat: lat0 + (radius * sin(a) + shift) * m, lon: lon0 + (radius * cos(a) + east) * m / k, t: Double(i) * 20, run: true)
        }
    }

    func testTheSameLoopMatches() {
        let a: [RoutePoint] = loop(radius: 400)
        XCTAssertTrue(RouteMatch.same(a, loop(radius: 400, shift: 20)), "GPS a little off is the same route")
        XCTAssertTrue(RouteMatch.same(a, Array(a.reversed())), "the other way round counts too")
    }

    func testADifferentRouteDoesnt() {
        let a: [RoutePoint] = loop(radius: 400)
        XCTAssertFalse(RouteMatch.same(a, loop(radius: 400, east: 350)), "starts too far away")
        XCTAssertFalse(RouteMatch.same(a, loop(radius: 600)), "a longer loop")
        // the same start and length, but a different way round the block: a squashed loop
        let other: [RoutePoint] = a.map { RoutePoint(lat: -37.85 + ($0.lat + 37.85) * 0.2, lon: $0.lon, t: $0.t, run: true) }
        XCTAssertFalse(RouteMatch.same(a, other))
    }

    func testOrdinals() {
        XCTAssertEqual(RouteMatch.ordinal(2), "2nd")
        XCTAssertEqual(RouteMatch.ordinal(3), "3rd")
        XCTAssertEqual(RouteMatch.ordinal(4), "4th")
        XCTAssertEqual(RouteMatch.ordinal(11), "11th")
        XCTAssertEqual(RouteMatch.ordinal(21), "21st")
    }
}
