import XCTest
@testable import CheatDays

/// Pack photos: brand spellings match, small bags are counted, and the note says where numbers came from.
final class LabelTests: XCTestCase {
    func testBrandSpellingsMatch() {
        XCTAssertEqual(LabelReader.words("M&S"), ["marks", "spencer"])
        XCTAssertEqual(LabelReader.words("Marks and Spencer"), ["marks", "spencer"])
        XCTAssertEqual(LabelReader.words("Sainsbury’s"), ["sainsbury"])
        XCTAssertEqual(LabelReader.words("The Co-operative"), ["coop"])
        XCTAssertEqual(LabelReader.words("Arnott's Tim Tam Original"), ["arnott", "tim", "tam"])
    }

    func testSmallBagsAreCounted() {
        var crisps: JSON = ["name": "Cucumber crisps", "unit": "g", "packSize": 70, "kcalPer100": 548]
        LabelReader.packAsCount(&crisps)
        XCTAssertEqual(str(crisps["unitLabel"]), "bag")
        XCTAssertEqual(num(crisps["kcalPerServing"]), 384)
        var big: JSON = ["name": "Rice", "unit": "g", "packSize": 1000, "kcalPer100": 350]
        LabelReader.packAsCount(&big)
        XCTAssertNil(big["unitLabel"])
    }

    func testNoteSaysWhereNumbersCameFrom() {
        let buns: JSON = ["name": "Hot cross buns", "unit": "g", "unitLabel": "bun", "servingSize": 70, "kcalPerServing": 196, "kcalPer100": 280]
        XCTAssertEqual(LabelReader.note(buns, source: "pack", webTried: ""), "196 kcal per bun, read off the pack.")
        XCTAssertTrue(LabelReader.note(buns, source: "estimate", webTried: "notfound").contains("couldn't be found online"))
    }
}
