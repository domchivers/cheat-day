import XCTest
@testable import CheatDays

/// 22 Nov audit: imports that failed said nothing, the finished video was always shown 9:16, and a reopened draft
/// lost track of the files its caption words were said in.
final class EditSafetyTests: XCTestCase {
    func testWhichPicksFailedIsSaid() {
        let said: String = ImportFailure.message(failed: [2, 4], of: 5)
        XCTAssertTrue(said.hasPrefix("2 of 5 couldn't be added (3rd, 5th)"), said)
        XCTAssertEqual([1, 2, 11, 12, 13, 22].map { (n: Int) -> String in ImportFailure.ordinal(n) },
                       ["1st", "2nd", "11th", "12th", "13th", "22nd"])
    }

    func testAVideosShapeIsTheRightWayUp() {
        let turned = CGAffineTransform(rotationAngle: CGFloat.pi / 2)
        XCTAssertEqual(Double(VideoShape.upright(CGSize(width: 1920, height: 1080), turn: turned)), 0.5625, accuracy: 0.001)
        XCTAssertEqual(Double(VideoShape.upright(CGSize(width: 1080, height: 1080), turn: .identity)), 1, accuracy: 0.001)
    }

    func testADraftsWordsFollowItsFilesNames() {
        let clip = Clip(source: URL(fileURLWithPath: "/tmp/abc.mov"), length: 5, start: 0, end: 5)
        var word = EditText.Word(text: "hello", at: 1)
        word.clip = clip.id
        word.file = "IMG_1.mov"
        word.src = 1
        let caption = EditText(kind: "caption", text: "hello", from: 1, to: 2, words: [word])

        let renamed: [EditText] = ClipCuts.renamed([caption], names: ["IMG_1.mov": "abc.mov"])
        XCTAssertEqual(renamed.first?.words?.first?.file, "abc.mov", "as it's saved")

        let linked: [EditText] = ClipCuts.linked([caption], clips: [clip])
        XCTAssertEqual(linked.first?.words?.first?.file, "abc.mov", "a draft saved before the fix")
    }
}
