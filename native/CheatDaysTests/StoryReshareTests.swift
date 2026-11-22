import XCTest
@testable import CheatDays

/// 22 Nov: "gif from person who tagged you is frozen". Their GIF, and what they put over it, stay live in a reshare.
final class StoryReshareTests: XCTestCase {
    @MainActor func testWhatMovesStaysLiveInTheirOrder() {
        let text: JSON = ["type": "text", "text": "under"]
        let gif: JSON = ["type": "gif", "url": "g"]
        let over: JSON = ["type": "text", "text": "over"]
        let song: JSON = ["type": "song"]
        let parts = StoryReshare.split([text, gif, over, song])
        XCTAssertEqual(parts.under.map { str($0["text"]) }, ["under"])
        XCTAssertEqual(parts.over.map { str($0["type"]) }, ["gif", "text"])

        let still = StoryReshare.split([text, song])
        XCTAssertEqual(still.under.count, 1)
        XCTAssertTrue(still.over.isEmpty, "nothing moves: all in the picture")
    }

    @MainActor func testAResharedResharesGIFStillMoves() {
        let inner: [JSON] = [["type": "gif", "url": "g"], ["type": "photo", "url": "inner.jpg"], ["type": "text", "text": "their words"]]
        let card: JSON = ["type": "photo", "url": "card.jpg", "on": inner]
        let layer: JSON = ["type": "layer", "on": inner]
        XCTAssertTrue(StoryItem.moves(card))
        XCTAssertTrue(StoryItem.moves(layer))
        XCTAssertEqual(StoryReshare.split([card]).over.count, 1)

        let story: JSON = ["kind": "photo", "media": "m.jpg", "overlays": [card]]
        XCTAssertEqual(Stories.pictures(story), ["m.jpg", "card.jpg", "inner.jpg"])
        XCTAssertTrue(Stories.everyThing([card]).contains { str($0["text"]) == "their words" }, "their words still looked at")
    }
}
