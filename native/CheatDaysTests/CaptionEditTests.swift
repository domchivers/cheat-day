import XCTest
@testable import CheatDays

/// Captions edited as CapCut's are (21 Nov, design/captions-editing-mockup.html): made again with more or less in
/// each from the words' own times, split at a word, joined, each with its own look.
final class CaptionEditTests: XCTestCase {
    /// Words said one every 0.4 s from `at`, as captions of three.
    private func said(_ text: String, at: Double = 0) -> [EditText] {
        let words = text.split(separator: " ").enumerated().map { EditText.Word(text: String($0.element), at: at + Double($0.offset) * 0.4) }
        return stride(from: 0, to: words.count, by: 3).map { i in
            let w = Array(words[i..<min(i + 3, words.count)])
            return EditText(kind: "caption", text: w.map(\.text).joined(separator: " "), style: "Pop", x: 0.5, y: 0.76,
                            from: w[0].at, to: w.last!.at + 0.4, words: w)
        }
    }

    private func allWords(_ caps: [EditText]) -> [String] { caps.sorted { $0.from < $1.from }.flatMap { ($0.words ?? []).map(\.text) } }

    func testRegroupKeepsEveryWordInOrderAtItsTime() {
        let caps = said("We ran our first firing in Jingdezhen. It started calm enough. We picked our pieces")
        let words = allWords(caps)
        for by in EditText.captionGroups.map(\.id) {
            for lines in [1, 2] {
                let out = EditOverlays.regroup(caps, by: by, lines: lines)
                XCTAssertEqual(allWords(out), words, "\(by), \(lines) line(s): every word once, in order")
                for c in out {
                    XCTAssertEqual(c.text, (c.words ?? []).map(\.text).joined(separator: " "))
                    XCTAssertEqual(c.from, c.words?.first?.at ?? -1, accuracy: 0.0001, "starts when its first word's said")
                    XCTAssertGreaterThan(c.to, c.from)
                }
                for (a, b) in zip(out, out.dropFirst()) { XCTAssertLessThanOrEqual(a.to, b.from + 0.0001, "\(by): none over the next") }
            }
        }
        XCTAssertEqual(EditOverlays.regroup(caps, by: "word", lines: 1).count, words.count)
        let sentences = EditOverlays.regroup(caps, by: "sentence", lines: 2)
        XCTAssertEqual(sentences.first?.text, "We ran our first firing in Jingdezhen.")
        XCTAssertEqual(sentences.dropFirst().first?.text, "It started calm enough.")
        for c in EditOverlays.regroup(caps, by: "line", lines: 1) { XCTAssertLessThanOrEqual(c.text.count, 30, c.text) }
    }

    func testANewCaptionLooksLikeTheOneItsFirstWordWasIn() {
        var caps = said("one two three four five six")
        caps[1].style = "Box"; caps[1].highlight = "green"; caps[1].y = 0.2
        let out = EditOverlays.regroup(caps, by: "word", lines: 1)
        XCTAssertEqual(out[3].text, "four"); XCTAssertEqual(out[3].style, "Box"); XCTAssertEqual(out[3].highlight, "green")
        XCTAssertEqual(out[0].style, "Pop"); XCTAssertNil(out[0].highlight)
    }

    func testSplitAndJoin() throws {
        let c = said("It started calm enough")[0]   // "It started calm"
        let (a, b) = try XCTUnwrap(EditOverlays.split(c, at: 1))
        XCTAssertEqual(a.text, "It"); XCTAssertEqual(b.text, "started calm")
        XCTAssertEqual(a.to, b.from, accuracy: 0.0001); XCTAssertEqual(b.from, 0.4, accuracy: 0.0001)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNil(EditOverlays.split(c, at: 0)); XCTAssertNil(EditOverlays.split(c, at: 3))
        let j = EditOverlays.join(a, b)
        XCTAssertEqual(j.text, c.text); XCTAssertEqual(j.words, c.words); XCTAssertEqual(j.from, c.from); XCTAssertEqual(j.to, c.to)
    }

    func testOldCaptionsStillOpen() throws {
        // saved before captions had a highlight of their own
        let json = #"{"id":"7D1F4C2E-1B9A-4C55-9C51-2F7C1F1E8A11","kind":"caption","text":"hi","detail":"","style":"Pop","colour":"white","x":0.5,"y":0.76,"size":1,"from":0,"to":1,"words":[{"text":"hi","at":0}],"number":0}"#
        let c = try JSONDecoder().decode(EditText.self, from: Data(json.utf8))
        XCTAssertNil(c.highlight); XCTAssertEqual(c.text, "hi")
    }

    /// One line means one line: a line's worth is short enough to fit, and each caption is marked to stay on one
    /// (21 Nov: "says 1 line but is more").
    func testOneLineStaysOneLine() {
        let caps = said("We ran our first firing in Jingdezhen. It started calm enough. We picked our pieces")
        for c in EditOverlays.regroup(caps, by: "line", lines: 1) { XCTAssertLessThanOrEqual(c.text.count, 22, c.text); XCTAssertEqual(c.detail, "1") }
        for c in EditOverlays.regroup(caps, by: "line", lines: 2) { XCTAssertEqual(c.detail, "") }
        XCTAssertTrue(EditText.highlights.contains("none"))
    }
}
