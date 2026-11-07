import Foundation

/// Real sizes from a photo's depth map (LiDAR on Pro iPhones, the dual camera on most others), for the AI to size food
/// by instead of guessing the scale: how far the table was, how much of it the photo covers, and how high the food
/// stands across the shot. A photo can't tell a 20 cm bowl from a 30 cm one; this can. No AVFoundation here, so it's tested.
enum DepthMeasure {
    /// The camera's focal lengths and centre in depth-map pixels.
    struct Lens { let fx, fy, cx, cy: Double }

    struct Result: Equatable {
        /// Straight down to the table from the camera, cm.
        let distanceCm: Double
        /// How much of the table the photo covers at its centre, cm (as the photo is shown: portrait is taller).
        let spanCm: (w: Double, h: Double)
        /// The tallest food or dish above the table (the 95th percentile, so a stray reading doesn't count), cm.
        let tallestCm: Double
        /// Everything standing on the table (food and its plates, bowls and boxes), ml.
        let volumeMl: Double
        /// The highest point in each of 4 × 4 areas of the photo, cm, top row first, as the photo is shown.
        let grid: [[Int]]
        /// The camera only knew depth roughly (the dual camera's often does), so the sizes are a guide, not a measurement.
        var rough = false

        static func == (a: Result, b: Result) -> Bool {
            a.distanceCm == b.distanceCm && a.spanCm == b.spanCm && a.tallestCm == b.tallestCm && a.volumeMl == b.volumeMl && a.grid == b.grid && a.rough == b.rough
        }
    }

    private struct P { let x, y, z: Double; let u, v: Int }

    /// Depth in metres, row by row, at the depth map's own size and the sensor's orientation; `portrait` when the photo
    /// was taken upright (the sensor's rows are then the photo's columns, turned clockwise). Nil when there's too little
    /// depth to trust, or no table to stand on.
    static func measure(depth: [Float], width: Int, height: Int, lens: Lens, portrait: Bool) -> Result? {
        guard width > 8, height > 8, depth.count == width * height else { return nil }
        let step = max(1, min(width, height) / 48)
        var pts: [P] = []
        for v in stride(from: 0, to: height, by: step) {
            for u in stride(from: 0, to: width, by: step) {
                let z = Double(depth[v * width + u])
                guard z.isFinite, z > 0.1, z < 2 else { continue }
                pts.append(P(x: (Double(u) - lens.cx) * z / lens.fx, y: (Double(v) - lens.cy) * z / lens.fy, z: z, u: u, v: v))
            }
        }
        let samples = (width / step + 1) * (height / step + 1)
        guard pts.count >= samples / 3, let plane = table(pts) else { return nil }
        let (n, d) = plane   // n · p + d = 0, n pointing at the camera (d > 0: the camera is above it)

        // straight down to the table, and where the corner rays of the shot meet it
        func hit(_ u: Double, _ v: Double) -> (Double, Double, Double)? {
            let r = ((u - lens.cx) / lens.fx, (v - lens.cy) / lens.fy, 1.0)
            let dn = n.0 * r.0 + n.1 * r.1 + n.2 * r.2
            guard abs(dn) > 1e-6 else { return nil }
            let t = -d / dn
            return t > 0 ? (r.0 * t, r.1 * t, r.2 * t) : nil
        }
        func gap(_ a: (Double, Double, Double)?, _ b: (Double, Double, Double)?) -> Double? {
            guard let a, let b else { return nil }
            return ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
        }
        let w = Double(width), h = Double(height), midU = w / 2, midV = h / 2
        guard let across = gap(hit(0, midV), hit(w, midV)), let down = gap(hit(midU, 0), hit(midU, h)) else { return nil }

        // each sample's height above the table, and the patch of table it stands for
        var heights: [Double] = [], volume = 0.0
        var grid = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        for p in pts {
            let above = n.0 * p.x + n.1 * p.y + n.2 * p.z + d
            guard above > 0.008, above < 0.25 else { continue }   // under 8 mm is the table; over 25 cm isn't on it
            heights.append(above)
            let len = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
            let facing = max(0.3, abs(n.0 * p.x + n.1 * p.y + n.2 * p.z) / len)   // a slanted view sees more table per pixel
            volume += above * (Double(step) * p.z / lens.fx) * (Double(step) * p.z / lens.fy) / facing
            // as the photo is shown: upright, the sensor's rows run down the photo's right-hand side
            let (col, row) = portrait ? (Int(Double(height - 1 - p.v) / h * 4), Int(Double(p.u) / w * 4))
                                      : (Int(Double(p.u) / w * 4), Int(Double(p.v) / h * 4))
            grid[min(3, row)][min(3, col)] = max(grid[min(3, row)][min(3, col)], above)
        }
        let tallest = heights.isEmpty ? 0 : heights.sorted()[Int(Double(heights.count - 1) * 0.95)]
        func cm(_ m: Double) -> Double { (m * 1000).rounded() / 10 }
        return Result(distanceCm: cm(d), spanCm: portrait ? (cm(down), cm(across)) : (cm(across), cm(down)), tallestCm: cm(tallest),
                      volumeMl: (volume * 1_000_000).rounded(), grid: grid.map { $0.map { Int((min($0, tallest) * 100).rounded()) } })
    }

    /// The biggest flat surface in view (the table), found by trying planes through 3 points (the same tries each time,
    /// so a photo always measures the same). Nil when no plane holds a fifth of the points.
    private static func table(_ pts: [P]) -> ((Double, Double, Double), Double)? {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ k: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(k)) }
        var best: (n: (Double, Double, Double), d: Double, count: Int)?
        for _ in 0..<300 {
            let a = pts[next(pts.count)], b = pts[next(pts.count)], c = pts[next(pts.count)]
            let ab = (b.x - a.x, b.y - a.y, b.z - a.z), ac = (c.x - a.x, c.y - a.y, c.z - a.z)
            var n = (ab.1 * ac.2 - ab.2 * ac.1, ab.2 * ac.0 - ab.0 * ac.2, ab.0 * ac.1 - ab.1 * ac.0)
            let len = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
            guard len > 1e-9 else { continue }
            n = (n.0 / len, n.1 / len, n.2 / len)
            var d = -(n.0 * a.x + n.1 * a.y + n.2 * a.z)
            if d < 0 { n = (-n.0, -n.1, -n.2); d = -d }   // the camera (the origin) on its positive side
            let count = pts.reduce(0) { $0 + (abs(n.0 * $1.x + n.1 * $1.y + n.2 * $1.z + d) < 0.008 ? 1 : 0) }
            if count > (best?.count ?? 0) { best = (n, d, count) }
        }
        guard let best, best.count >= pts.count / 5 else { return nil }
        return (best.n, best.d)
    }

    /// What the AI is told about one photo's sizes.
    static func describe(_ r: Result, photo: Int) -> String {
        func n(_ v: Double) -> String { String(Int(v.rounded())) }
        return "Photo \(photo), measured with the phone's depth camera\(r.rough ? " (roughly: check it against the plate or box before relying on it)" : ""): about \(n(r.distanceCm)) cm from the table; at its centre the photo covers about \(n(r.spanCm.w)) × \(n(r.spanCm.h)) cm of the table (width × height as shown). The food and its dishes stand up to \(n(r.tallestCm)) cm above the table, about \(n(r.volumeMl)) ml in all including plates, bowls and boxes. Highest point in each quarter of the photo, cm, top row first: \(r.grid.map { $0.map(String.init).joined(separator: " ") }.joined(separator: " / "))."
    }

    /// The badge on a measured photo ("tray 38 × 26 cm" needs the AI; this is what the app knows itself).
    static func badge(_ r: Result) -> String { "measured, \(Int(r.spanCm.w.rounded())) × \(Int(r.spanCm.h.rounded())) cm in view" }
}
