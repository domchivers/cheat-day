import XCTest
import AVFoundation
@testable import CheatDays

/// Start's rides, walks, hikes and timed workouts, and heart rate (26 Nov, design/start-anything-mockup.html and
/// design/heart-rate-mockup.html).
final class MovingTests: XCTestCase {
    /// A ride's kcal goes by its speed: 20 km in an hour at 80 kg is the 19–22.5 band (8 MET), 640.
    func testARidesKcalGoesBySpeed() {
        XCTAssertEqual(MoveKind.rideMET(kmh: 12), 4)
        XCTAssertEqual(MoveKind.rideMET(kmh: 20.9), 8)
        XCTAssertEqual(MoveKind.rideMET(kmh: 27), 12)
        XCTAssertEqual(MoveKind.ride.kcal(seconds: 3600, meters: 20000, climb: 0, kg: 80), 640, accuracy: 1)
        // not mapped: cycling's usual rate for the time
        XCTAssertEqual(MoveKind.ride.kcal(seconds: 3600, meters: 0, climb: 0, kg: 80), 600, accuracy: 1)
    }

    /// A hike's climb adds to it; a walk's speed does too.
    func testAHikesClimbCounts() {
        let flat: Double = MoveKind.hike.kcal(seconds: 3600, meters: 4000, climb: 0, kg: 80)
        let hilly: Double = MoveKind.hike.kcal(seconds: 3600, meters: 4000, climb: 300, kg: 80)
        XCTAssertEqual(hilly - flat, 226, accuracy: 2)
        XCTAssertGreaterThan(MoveKind.walk.kcal(seconds: 3600, meters: 6000, climb: 0, kg: 80),
                             MoveKind.walk.kcal(seconds: 3600, meters: 4000, climb: 0, kg: 80))
    }

    /// Height climbed: rises of 3 m or more, not GPS's wobble.
    func testClimbIgnoresWobble() {
        func pts(_ alts: [Double]) -> [RoutePoint] {
            alts.enumerated().map { RoutePoint(lat: 0, lon: 0, t: Double($0.offset), run: true, alt: $0.element) }
        }
        XCTAssertEqual(RouteMath.climb(pts([10, 11, 10, 12, 11, 10])), 0)
        XCTAssertEqual(RouteMath.climb(pts([10, 14, 12, 20, 15, 25])), 4 + 8 + 10)
        XCTAssertEqual(RouteMath.climb([RoutePoint(lat: 0, lon: 0, t: 0, run: true)]), 0, "no heights, no climb")
    }

    /// Stopped for five seconds pauses; going again for two carries on. Not before they've first moved.
    func testAutoPauseAtTheLights() {
        var a = AutoPause(stopBelow: 1.5)
        let t0 = Date()
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        XCTAssertFalse(a.update(speed: 0, at: at(0)))
        XCTAssertFalse(a.update(speed: 0, at: at(10)), "standing at the start isn't a pause")
        XCTAssertFalse(a.update(speed: 6, at: at(11)))
        XCTAssertFalse(a.update(speed: 0.5, at: at(20)))
        XCTAssertFalse(a.update(speed: 0.5, at: at(23)), "three seconds isn't long enough")
        XCTAssertTrue(a.update(speed: 0.5, at: at(25.5)))
        XCTAssertTrue(a.update(speed: nil, at: at(40)), "no fix changes nothing")
        XCTAssertTrue(a.update(speed: 5, at: at(41)))
        XCTAssertFalse(a.update(speed: 5, at: at(43.5)))
    }

    /// The same workout twice: same kind, over half the shorter one shared.
    func testOverlap() {
        let t0 = Date()
        let run: (type: String, start: Date, end: Date) = ("Run", t0, t0.addingTimeInterval(1800))
        let watch: (type: String, start: Date, end: Date) = ("Run", t0.addingTimeInterval(60), t0.addingTimeInterval(1900))
        XCTAssertTrue(Overlap.same(run, watch))
        XCTAssertFalse(Overlap.same(run, ("Cycle", watch.start, watch.end)), "a different kind")
        XCTAssertFalse(Overlap.same(run, ("Run", t0.addingTimeInterval(1200), t0.addingTimeInterval(3000))), "only a third shared")
        XCTAssertEqual(Overlap.fraction((t0, t0.addingTimeInterval(100)), (t0.addingTimeInterval(200), t0.addingTimeInterval(300))), 0)
    }

    /// A watch's copy that came in first gives its calories and heart rate to the one tracked here.
    @MainActor func testTheWatchsNumbersAreTakenIn() {
        var mine: JSON = ["type": "Run", "kcal": 380.0]
        Store.takeWatch(["type": "Run", "kcal": 402.0, "kcalFrom": "watch", "hrAvg": 148, "hrMax": 171], into: &mine)
        XCTAssertEqual(num(mine["kcal"]), 402)
        XCTAssertEqual(num(mine["kcalGuess"]), 380)
        XCTAssertEqual(str(mine["kcalFrom"]), "watch")
        XCTAssertEqual(num(mine["hrAvg"]), 148)
        XCTAssertEqual(mine["watch"] as? Bool, true)
        // a copy whose calories were only guessed from its minutes: ours stay
        var other: JSON = ["type": "Run", "kcal": 380.0, "hrAvg": 150]
        Store.takeWatch(["type": "Run", "kcal": 300.0, "hrAvg": 140], into: &other)
        XCTAssertEqual(num(other["kcal"]), 380)
        XCTAssertEqual(num(other["hrAvg"]), 150, "the strap's heart rate stays")
    }

    /// Zones from 220 minus age, and time in each.
    func testHeartZones() {
        XCTAssertEqual(HeartZones.max(age: 33), 187)
        XCTAssertEqual(HeartZones.zone(bpm: 100, max: 187), 1)
        XCTAssertEqual(HeartZones.zone(bpm: 120, max: 187), 2)
        XCTAssertEqual(HeartZones.zone(bpm: 140, max: 187), 3)
        XCTAssertEqual(HeartZones.zone(bpm: 160, max: 187), 4)
        XCTAssertEqual(HeartZones.zone(bpm: 175, max: 187), 5)
        let s: [HRSample] = [HRSample(t: 0, bpm: 100), HRSample(t: 10, bpm: 160), HRSample(t: 20, bpm: 160), HRSample(t: 200, bpm: 100)]
        let z: [Double] = HeartZones.seconds(s, max: 187)
        XCTAssertEqual(z[0], 10 + 5)
        XCTAssertEqual(z[3], 10 + 30, "a long gap counts 30 s, not 180")
        XCTAssertTrue(HeartZones.runLine(bpm: 160, max: 187).contains("slow down"))
        XCTAssertEqual(HeartData.summary(s)?.avg, 130)
        XCTAssertEqual(HeartData.summary(s)?.max, 160)
    }

    /// A strap's reading: one byte, or two when the flags say so.
    func testAStrapsReading() {
        XCTAssertEqual(HeartData.bpm(from: Data([0x00, 152])), 152)
        XCTAssertEqual(HeartData.bpm(from: Data([0x16, 72, 0x10, 0x03])), 72, "RR intervals after it don't matter")
        XCTAssertEqual(HeartData.bpm(from: Data([0x01, 0x2C, 0x01])), 300)
        XCTAssertNil(HeartData.bpm(from: Data([0x01, 0x2C])))
        XCTAssertNil(HeartData.bpm(from: Data()))
    }

    /// After a cue the voice's ducking session is put back to ambient, so their music isn't left lower (26 Nov);
    /// someone else's playback session (a song in the feed) is left alone.
    func testTheVoiceLeavesTheirMusicAlone() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
        VoiceSession.release(s)
        XCTAssertEqual(s.category, .ambient)
        try s.setCategory(.playback, mode: .default)
        VoiceSession.release(s)
        XCTAssertEqual(s.category, .playback, "not the voice's: left as it is")
        try s.setCategory(.ambient)
    }

    /// Steps taken during a tracked walk aren't counted again as walking.
    func testTrackedStepsArentWalkedTwice() {
        XCTAssertEqual(Steps.kcal(steps: 10000, tracked: 0, kg: 80), 320)
        XCTAssertEqual(Steps.kcal(steps: 10000, tracked: 6000, kg: 80), 128)
        XCTAssertEqual(Steps.kcal(steps: 3000, tracked: 6000, kg: 80), 0, "never below nothing")
    }
}
