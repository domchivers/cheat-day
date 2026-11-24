import XCTest
@testable import CheatDays

/// Mapped runs (25 Nov, design/run-route-mockup.html): distance, each kilometre, pauses, and routes kept on the phone.
final class RunRouteTests: XCTestCase {
    /// Straight north, 500 m (0.0045° of latitude) every 150 s: 5:00 a kilometre.
    private func line(_ n: Int, gapAt: Int? = nil, runFrom: Int = 0) -> [RoutePoint] {
        (0..<n).map { i in RoutePoint(lat: -37.8 + Double(i) * 0.0045, lon: 144.96, t: Double(i) * 150, run: i >= runFrom, gap: i == gapAt) }
    }

    func testDistanceAndEachKilometre() {
        let p: [RoutePoint] = line(5)                       // 2 km
        XCTAssertEqual(RouteMath.meters(p), 2000, accuracy: 10)
        let s = RouteMath.splits(p)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].seconds, 300, accuracy: 3)
        XCTAssertEqual(s[1].km, 1)
        XCTAssertEqual(RouteMath.pace(300), "5:00")
        XCTAssertEqual(RouteMath.pace(nil), "–:––")
        XCTAssertEqual(RouteMath.km(3921), "3.92")
        XCTAssertEqual(RouteMath.kmMarks(p).count, 2)
    }

    func testAPartKilometreAtTheEnd() {
        let p: [RoutePoint] = line(6)                       // 2.5 km
        let s = RouteMath.splits(p)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[2].km, 0.5, accuracy: 0.01)
        XCTAssertEqual(s[2].seconds, 150, accuracy: 3)
    }

    /// After a pause the line starts again: what's between isn't counted, or drawn.
    func testAPauseIsntDistance() {
        let p: [RoutePoint] = line(5, gapAt: 3)
        XCTAssertEqual(RouteMath.meters(p), 1500, accuracy: 10)
        XCTAssertEqual(RouteMath.stretches(p).count, 2)
    }

    /// Walking and running are their own lines, joined where one becomes the other.
    func testRunsAndWalksAreSeparateLines() {
        let lines = RouteMath.stretches(line(5, runFrom: 2))
        XCTAssertEqual(lines.map { $0.run }, [false, true])
        XCTAssertEqual(lines[0].points.count, 2)
        XCTAssertEqual(lines[1].points.count, 4, "starts at the walk's last point, so there's no break")
    }

    func testARouteIsKeptOnThePhone() {
        let id: String = "test-" + UUID().uuidString
        XCTAssertFalse(RouteStore.has(id))
        RouteStore.save(line(3), id: id)
        XCTAssertEqual(RouteStore.load(id), line(3))
        RouteStore.delete(id)
        XCTAssertNil(RouteStore.load(id))
    }
}
