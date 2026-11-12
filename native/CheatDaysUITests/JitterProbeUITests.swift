import XCTest

/// Measures, off the screen itself, where a much-enlarged tile's edge lands as it's slid a twentieth of a point at a
/// time, for four ways of building it (see JitterProbe). Prints a table; it's a measurement, so nothing fails.
final class JitterProbeUITests: XCTestCase {
    func testWhereTheEdgeLands() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-jitter"]
        app.launch()
        XCTAssertTrue(app.buttons["probe-next"].waitForExistence(timeout: 10))
        var lines = ["PROBE k scale wanted A B C D   (points; each column is where the edge is, less where it's wanted)"]
        for k in 0..<50 {
            XCTAssertTrue(app.staticTexts["k=\(k)"].waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.25)
            guard let cg = XCUIScreen.main.screenshot().image.cgImage else { continue }
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let scale = Double(w) / Double(app.frame.width)
            let wanted = 150.02 + Double(k % 25) * 0.05
            var out = "PROBE \(k) \(k < 25 ? 30 : 4) \(String(format: "%.2f", wanted))"
            for band in 0..<4 {
                let row = Int((100.0 + Double(band) * 130.0 + 60.0) * scale)
                var white = 0.0
                for x in 0..<w { white += Double(px[(row * w + x) * 4]) / 255.0 }
                let edge = (Double(w) - white) / scale
                out += String(format: " %+.3f", edge - wanted)
            }
            lines.append(out)
            app.buttons["probe-next"].tap()
        }
        let table = lines.joined(separator: "\n")
        print(table)
        let a = XCTAttachment(string: table); a.name = "jitter-probe"; a.lifetime = .keepAlways; add(a)
    }
}
