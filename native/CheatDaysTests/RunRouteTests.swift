import XCTest
@testable import CheatDays

/// Mapped runs (25 Nov, design/run-route-mockup.html): distance, each kilometre, pauses, and routes kept on the phone.
final class RunRouteTests: XCTestCase {
    /// Straight north, a step of 0.0046° of latitude (about 511 m) every 150 s. (1.4.54: 0.0045° came to 499.5 m, so
    /// four steps fell 2 m short of 2 km and the second kilometre never quite finished; the numbers are now measured
    /// from the step itself.)
    private func line(_ n: Int, gapAt: Int? = nil, runFrom: Int = 0) -> [RoutePoint] {
        (0..<n).map { i in RoutePoint(lat: -37.8 + Double(i) * 0.0046, lon: 144.96, t: Double(i) * 150, run: i >= runFrom, gap: i == gapAt) }
    }
    private var step: Double { RouteMath.meters(line(2)) }

    func testDistanceAndEachKilometre() {
        XCTAssertGreaterThan(step, 505)
        let p: [RoutePoint] = line(5)                       // just over 2 km
        XCTAssertEqual(RouteMath.meters(p), step * 4, accuracy: 1)
        let s = RouteMath.splits(p)
        XCTAssertEqual(s.count, 2, "the 40-odd metres left over are under 50, so not a split")
        XCTAssertEqual(s[0].seconds, 150 * 1000 / step, accuracy: 1)
        XCTAssertEqual(s[1].km, 1)
        XCTAssertEqual(RouteMath.pace(300), "5:00")
        XCTAssertEqual(RouteMath.pace(nil), "–:––")
        XCTAssertEqual(RouteMath.km(3921), "3.92")
        XCTAssertEqual(RouteMath.kmMarks(p).count, 2)
    }

    func testAPartKilometreAtTheEnd() {
        let p: [RoutePoint] = line(6)                       // about 2.55 km
        let s = RouteMath.splits(p)
        let rest: Double = step * 5 - 2000
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[2].km, rest / 1000, accuracy: 0.001)
        XCTAssertEqual(s[2].seconds, rest / step * 150, accuracy: 1)
    }

    /// 26 Nov, the owner: a run ending within 10 m of a whole kilometre gets that kilometre whole, split and mark.
    func testAlmostAWholeKilometreCountsAsOne() {
        // north 0.0089° (about 989 m) then a little more, to about 995 m: 5 m short of 1 km
        let short: Double = 0.0089 + 0.006 / 111.0
        let p: [RoutePoint] = [RoutePoint(lat: -37.8, lon: 144.96, t: 0, run: true),
                               RoutePoint(lat: -37.8 + short, lon: 144.96, t: 300, run: true)]
        let m: Double = RouteMath.meters(p)
        XCTAssertLessThan(m, 1000)
        XCTAssertGreaterThan(m, 1000 - RouteMath.wholeWithin)
        let s = RouteMath.splits(p)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].km, 1, "whole, not 0.99")
        XCTAssertEqual(s[0].seconds, 300, accuracy: 0.5)
        XCTAssertEqual(RouteMath.kmMarks(p).count, 1, "its mark at the finish")
        // 30 m short isn't whole
        let far: [RoutePoint] = [p[0], RoutePoint(lat: -37.8 + 0.0087, lon: 144.96, t: 300, run: true)]
        XCTAssertLessThan(RouteMath.splits(far)[0].km, 1)
        XCTAssertTrue(RouteMath.kmMarks(far).isEmpty)
    }

    /// After a pause the line starts again: what's between isn't counted, or drawn.
    func testAPauseIsntDistance() {
        let p: [RoutePoint] = line(5, gapAt: 3)
        XCTAssertEqual(RouteMath.meters(p), step * 3, accuracy: 1)
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
