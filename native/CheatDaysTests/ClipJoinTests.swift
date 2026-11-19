import XCTest
import UIKit
@testable import CheatDays

/// The multi-clip editor's split: the two halves meet where it was cut, and the sound kept stays where it was in time.
final class ClipJoinTests: XCTestCase {
    private func clip(_ start: Double, _ end: Double) -> Clip {
        Clip(source: URL(fileURLWithPath: "/tmp/x.mov"), length: 20, start: start, end: end)
    }

    func testSplitMeetsWhereItWasCut() throws {
        let (a, b) = try XCTUnwrap(ClipJoin.split(clip(2, 12), at: 4))
        XCTAssertEqual(a.start, 2); XCTAssertEqual(a.end, 6)
        XCTAssertEqual(b.start, 6); XCTAssertEqual(b.end, 12)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.duration + b.duration, 10, accuracy: 0.0001)
    }

    func testSplitTooNearAnEndDoesNothing() {
        XCTAssertNil(ClipJoin.split(clip(2, 12), at: 0.1))
        XCTAssertNil(ClipJoin.split(clip(2, 12), at: 9.9))
    }

    func testSoundKeptStaysInPlace() throws {
        var c = clip(0, 10); c.soundStart = 3; c.soundEnd = 5
        // cut after the sound: the first half has it all, the second none
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 7))
        XCTAssertEqual(a.heardStart, 3); XCTAssertEqual(a.heardEnd, 5)
        XCTAssertLessThanOrEqual(b.heardEnd - b.heardStart, 0)
        // cut through it: each half keeps its own part
        let (x, y) = try XCTUnwrap(ClipJoin.split(c, at: 4))
        XCTAssertEqual(x.heardStart, 3); XCTAssertEqual(x.heardEnd, 4)
        XCTAssertEqual(y.heardStart, 4); XCTAssertEqual(y.heardEnd, 5)
    }

    func testFadesStayAtTheOuterEnds() throws {
        var c = clip(0, 10); c.fadeIn = 1; c.fadeOut = 2
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 5))
        XCTAssertEqual(a.fadeIn, 1); XCTAssertEqual(a.fadeOut, 0)
        XCTAssertEqual(b.fadeIn, 0); XCTAssertEqual(b.fadeOut, 2)
    }

    /// Volume keyframes eased between, fades on top, and a split keeping each half its own keyframes.
    func testLevelFollowsKeyframesAndFades() throws {
        var c = clip(0, 10)
        c.keys = [VolumeKey(at: 2, volume: 1), VolumeKey(at: 4, volume: 0.2)]
        XCTAssertEqual(c.level(at: 1), 1, accuracy: 0.001)       // before the first: its level
        XCTAssertEqual(c.level(at: 3), 0.6, accuracy: 0.001)     // halfway between
        XCTAssertEqual(c.level(at: 8), 0.2, accuracy: 0.001)     // after the last: its level
        c.fadeOut = 2
        XCTAssertEqual(c.level(at: 9), 0.1, accuracy: 0.001)     // half way through the fade out
        XCTAssertEqual(c.level(at: 10), 0, accuracy: 0.001)
        XCTAssertTrue(c.turns.contains(8))                        // where the fade out starts
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 3))
        XCTAssertEqual(a.keys.map { $0.at }, [2]); XCTAssertEqual(b.keys.map { $0.at }, [4])
    }

    /// At another speed a clip lasts longer or shorter in the video; a split keeps its speed in both halves.
    func testSpeedSetsHowLongItLasts() throws {
        var c = clip(2, 12); c.speed = 0.5
        XCTAssertEqual(c.span, 20, accuracy: 0.001)
        c.speed = 4
        XCTAssertEqual(c.span, 2.5, accuracy: 0.001)
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 4))
        XCTAssertEqual(a.speed, 4); XCTAssertEqual(b.speed, 4)
        XCTAssertEqual(a.span + b.span, 2.5, accuracy: 0.001)
    }

    /// A draft saved before speed existed still opens, at normal speed.
    func testOldDraftClipDecodes() throws {
        let old = #"{"id":"6B1F2C1E-0000-4000-8000-000000000001","source":"file:///x.mov","length":20,"start":1,"end":9,"still":false,"soundOn":true,"volume":0.5,"fadeIn":0,"fadeOut":0,"keys":[]}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(old.utf8))
        XCTAssertEqual(c.speed, 1); XCTAssertEqual(c.volume, 0.5); XCTAssertEqual(c.end, 9)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    /// A transition plays the two clips over each other: the video is shorter by its length, never more than half a clip.
    func testTransitionsOverlapTheClips() {
        var a = clip(0, 4), b = clip(0, 6)
        let c = clip(0, 2)
        XCTAssertEqual(ClipJoin.total([a, b, c]), 12, accuracy: 0.001)
        a.transition = ClipTransition(kind: "Crossfade", length: 0.5)
        b.transition = ClipTransition(kind: "Slide", length: 3)   // longer than half of the 2 s after it: 1 s
        XCTAssertEqual(ClipJoin.overlap([a, b, c], after: 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(ClipJoin.overlap([a, b, c], after: 1), 1, accuracy: 0.001)
        XCTAssertEqual(ClipJoin.overlap([a, b, c], after: 2), 0)   // the last has nothing to turn into
        XCTAssertEqual(ClipJoin.starts([a, b, c]), [0, 3.5, 8.5])
        XCTAssertEqual(ClipJoin.total([a, b, c]), 10.5, accuracy: 0.001)
    }

    /// Split: the first half cuts straight into the second; the second keeps the way into the next, and the look.
    func testSplitKeepsTheTransitionOnTheSecondHalf() throws {
        var c = clip(0, 10); c.transition = ClipTransition(kind: "Zoom"); c.look = "Warm;b=20.0"
        let (a, b) = try XCTUnwrap(ClipJoin.split(c, at: 4))
        XCTAssertNil(a.transition); XCTAssertEqual(b.transition?.kind, "Zoom")
        XCTAssertEqual(a.look, "Warm;b=20.0"); XCTAssertEqual(b.look, "Warm;b=20.0")
    }

    /// Transitions, looks and a reversed clip's way back go into a draft and come out the same.
    func testNewPartsRoundTrip() throws {
        var c = clip(1, 5)
        c.transition = ClipTransition(kind: "Whip", length: 0.3); c.look = "Mono"
        c.forward = Forward(source: URL(fileURLWithPath: "/tmp/f.mov"), length: 12, end: 9, soundOn: true)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    /// Which way up a clip's frames go: an iPhone held upright, upside down, either way on its side.
    func testOrientationFromTheCameraTransform() {
        XCTAssertEqual(EditCompositor.orientation(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)), .right)
        XCTAssertEqual(EditCompositor.orientation(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)), .left)
        XCTAssertEqual(EditCompositor.orientation(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)), .down)
        XCTAssertEqual(EditCompositor.orientation(.identity), .up)
    }
}
