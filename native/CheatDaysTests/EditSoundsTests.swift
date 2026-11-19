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
}
