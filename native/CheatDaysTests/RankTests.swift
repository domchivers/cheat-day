import XCTest
@testable import CheatDays

/// Ranks sit on the website's levels: level n from (n - 1)² × 100 XP, three steps a tier, Legend from level 16.
final class RankTests: XCTestCase {
    func testLevelsMatchTheWebsite() {
        XCTAssertEqual(Rank.level(for: 0), 1)
        XCTAssertEqual(Rank.level(for: 99), 1)
        XCTAssertEqual(Rank.level(for: 100), 2)
        XCTAssertEqual(Rank.level(for: 3600), 7)
        XCTAssertEqual(Rank.xp(forLevel: 16), 22500)
    }

    func testRankNames() {
        XCTAssertEqual(Rank(level: 1).name, "Crumb I")
        XCTAssertEqual(Rank(level: 6).name, "Toast III")
        XCTAssertEqual(Rank(level: 7).name, "Dumpling I")
        XCTAssertEqual(Rank(level: 16).name, "Legend")
        XCTAssertEqual(Rank(level: 30).name, "Legend")
        XCTAssertEqual(Rank(level: 9).key, "dumpling")
    }
}
