import XCTest
@testable import CheatDays

/// Stage C: every sound effect is made and is short; a voiceover take keeps where it is and how much of it plays.
final class EditSoundsTests: XCTestCase {
    func testEveryEffectIsMadeAndShort() throws {
        for name in SoundEffects.names {
            let length = SoundEffects.length(name)
            XCTAssertGreaterThan(length, 0.01, name)
            XCTAssertLessThan(length, 2, name)
            let url = try XCTUnwrap(SoundEffects.url(name), name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
        }
    }

    func testTakeRoundTrips() throws {
        let take = EditSound(kind: "voice", name: "Voice 1", file: URL(fileURLWithPath: "/tmp/v.caf"), from: 2.5, start: 0.4, length: 3, volume: 0.8, full: 4)
        XCTAssertEqual(take.to, 5.5, accuracy: 0.001)
        let back = try JSONDecoder().decode(EditSound.self, from: JSONEncoder().encode(take))
        XCTAssertEqual(back, take)
    }

    /// A sound saved before fades, keyframes and separated sound (21 Nov) still reads, with none of them.
    func testOlderSoundStillReads() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"song","name":"Song","from":0,"start":1,"length":10,"volume":0.7,"full":30}"#
        let s = try JSONDecoder().decode(EditSound.self, from: Data(old.utf8))
        XCTAssertNil(s.fadeIn); XCTAssertNil(s.keys); XCTAssertNil(s.clip)
        XCTAssertEqual(s.speed, 1)
        XCTAssertEqual(s.level(at: 5), 0.7, accuracy: 0.001)
        XCTAssertEqual(s.turns, [0, 10])
    }

    /// Fades in and out over the video's seconds; keyframes in its own, eased between.
    func testLevelWithFadesAndKeys() {
        var s = EditSound(kind: "song", name: "Song", from: 2, start: 10, length: 8, volume: 1, full: 60)
        s.fadeIn = 1; s.fadeOut = 2
        XCTAssertEqual(s.level(at: 2), 0, accuracy: 0.001)
        XCTAssertEqual(s.level(at: 2.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(s.level(at: 5), 1, accuracy: 0.001)
        XCTAssertEqual(s.level(at: 9), 0.5, accuracy: 0.001)
        XCTAssertEqual(s.level(at: 10), 0, accuracy: 0.001)
        s.fadeIn = nil; s.fadeOut = nil
        s.keys = [VolumeKey(at: 12, volume: 1), VolumeKey(at: 14, volume: 0)]   // the video's 4 s and 6 s
        XCTAssertEqual(s.level(at: 3), 1, accuracy: 0.001)
        XCTAssertEqual(s.level(at: 5), 0.5, accuracy: 0.001)
        XCTAssertEqual(s.level(at: 8), 0, accuracy: 0.001)
        XCTAssertEqual(s.turns, [2, 4, 6, 10])
    }

    /// A clip's separated sound keeps the clip's speed: twice as fast, a second of the video is two of its sound.
    func testSeparatedSoundKeepsItsSpeed() {
        var s = EditSound(kind: "clip", name: "Clip 1 sound", from: 1, start: 4, length: 3, volume: 1, full: 20)
        s.rate = 2
        XCTAssertEqual(s.fileTime(2), 6, accuracy: 0.001)
        XCTAssertEqual(s.videoTime(8), 3, accuracy: 0.001)
        s.keys = [VolumeKey(at: 6, volume: 0.4)]
        XCTAssertEqual(s.turns, [1, 2, 4])
    }
}
