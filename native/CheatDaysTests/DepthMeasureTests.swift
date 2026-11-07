import XCTest
@testable import CheatDays

/// Sizes from a depth map: a made-up one of a 10 × 10 × 5 cm box on a table 40 cm straight below the camera.
final class DepthMeasureTests: XCTestCase {
    let w = 160, h = 120
    let lens = DepthMeasure.Lens(fx: 200, fy: 200, cx: 80, cy: 60)

    /// The table at 40 cm, and the box's top at 35 cm wherever it's within 5 cm of the middle.
    func boxOnTable(tilt: Double = 0) -> [Float] {
        var d = [Float](repeating: 0, count: w * h)
        for v in 0..<h { for u in 0..<w {
            let x = (Double(u) - lens.cx) / lens.fx, y = (Double(v) - lens.cy) / lens.fy
            var z = 0.4 / (1 - tilt * y)   // the plane z = 0.4 + tilt·Y: seen at a slant, it gets further away down the photo
            if abs(x * 0.35) < 0.05, abs(y * 0.35) < 0.05 { z = 0.35 }
            d[v * w + u] = Float(z)
        } }
        return d
    }

    func testMeasuresTheBoxAndTable() throws {
        let r = try XCTUnwrap(DepthMeasure.measure(depth: boxOnTable(), width: w, height: h, lens: lens, portrait: false))
        XCTAssertEqual(r.distanceCm, 40, accuracy: 0.5)
        XCTAssertEqual(r.spanCm.w, 32, accuracy: 0.5)   // 160 px at 40 cm through a 200 px lens
        XCTAssertEqual(r.spanCm.h, 24, accuracy: 0.5)
        XCTAssertEqual(r.tallestCm, 5, accuracy: 0.3)
        XCTAssertEqual(r.volumeMl, 500, accuracy: 75)
        XCTAssertEqual(r.grid[1][1], 5); XCTAssertEqual(r.grid[2][2], 5)   // the box is in the middle
        XCTAssertEqual(r.grid[0][0], 0); XCTAssertEqual(r.grid[3][3], 0)
    }

    func testUprightPhotoTurnsTheSizes() throws {
        let r = try XCTUnwrap(DepthMeasure.measure(depth: boxOnTable(), width: w, height: h, lens: lens, portrait: true))
        XCTAssertEqual(r.spanCm.w, 24, accuracy: 0.5)   // as shown: narrower than it's tall
        XCTAssertEqual(r.spanCm.h, 32, accuracy: 0.5)
    }

    func testSlantedTableStillFound() throws {
        let r = try XCTUnwrap(DepthMeasure.measure(depth: boxOnTable(tilt: 0.3), width: w, height: h, lens: lens, portrait: false))
        XCTAssertEqual(r.tallestCm, 5, accuracy: 1.5)   // the box's top is level, the table isn't: one end stands taller
        XCTAssertGreaterThan(r.distanceCm, 30); XCTAssertLessThan(r.distanceCm, 45)
    }

    func testNoDepthNoMeasurement() {
        XCTAssertNil(DepthMeasure.measure(depth: [Float](repeating: 0, count: w * h), width: w, height: h, lens: lens, portrait: false))
        XCTAssertNil(DepthMeasure.measure(depth: [1, 2, 3], width: w, height: h, lens: lens, portrait: false))
    }

    func testTheAIIsToldWhichPhotoAndHowSure() throws {
        var r = try XCTUnwrap(DepthMeasure.measure(depth: boxOnTable(), width: w, height: h, lens: lens, portrait: false))
        let told = Assistant.measured([nil, r])
        XCTAssertTrue(told.contains("Photo 2, measured"))
        XCTAssertFalse(told.contains("Photo 1"))
        XCTAssertTrue(told.contains("about 40 cm from the table"))
        XCTAssertTrue(told.contains("32 × 24 cm"))
        XCTAssertFalse(told.contains("roughly"))
        r.rough = true
        XCTAssertTrue(Assistant.measured([r]).contains("roughly"))
        XCTAssertEqual(Assistant.measured([nil, nil]), "")
    }
}
