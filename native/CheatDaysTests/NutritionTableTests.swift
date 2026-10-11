import XCTest
@testable import CheatDays

/// Reading a nutrition table by rules: the per-100 column on UK and Australian layouts, kJ when there's no kcal,
/// the serving size, and giving up (so the AI reads it) when the numbers don't add up.
final class NutritionTableTests: XCTestCase {
    private func piece(_ t: String, _ x: Double, _ y: Double) -> NutritionTable.Piece {
        NutritionTable.Piece(text: t, box: CGRect(x: x - 0.08, y: y - 0.015, width: 0.16, height: 0.03))
    }

    func testUKTable() {
        let pieces = [
            piece("Typical values", 0.2, 0.9), piece("Per 100g", 0.55, 0.9), piece("Per 30g serving", 0.8, 0.9),
            piece("Energy", 0.2, 0.8), piece("1985kJ", 0.55, 0.8), piece("596kJ", 0.8, 0.8),
            piece("474kcal", 0.55, 0.75), piece("142kcal", 0.8, 0.75),
            piece("Fat", 0.2, 0.7), piece("23.6g", 0.55, 0.7), piece("7.1g", 0.8, 0.7),
            piece("of which saturates", 0.2, 0.65), piece("11.2g", 0.55, 0.65), piece("3.4g", 0.8, 0.65),
            piece("Carbohydrate", 0.2, 0.6), piece("60.1g", 0.55, 0.6), piece("18.0g", 0.8, 0.6),
            piece("of which sugars", 0.2, 0.55), piece("29.0g", 0.55, 0.55), piece("8.7g", 0.8, 0.55),
            piece("Protein", 0.2, 0.5), piece("6.2g", 0.55, 0.5), piece("1.9g", 0.8, 0.5)
        ]
        let p = NutritionTable.parse(pieces)
        XCTAssertEqual(p?.kcal100, 474)
        XCTAssertEqual(p?.kcalServing, 142)
        XCTAssertEqual(p?.f100, 23.6)
        XCTAssertEqual(p?.c100, 60.1)
        XCTAssertEqual(p?.p100, 6.2)
        XCTAssertEqual(p?.servingSize, 30)
        XCTAssertEqual(p?.unit, "g")
    }

    func testAustralianPanelWithKilojoulesOnly() {
        let pieces = [
            piece("Servings per package: 8", 0.3, 0.95), piece("Serving size: 30g", 0.3, 0.92),
            piece("Avg Quantity per Serving", 0.55, 0.85), piece("Avg Quantity per 100g", 0.8, 0.85),
            piece("Energy", 0.2, 0.8), piece("460kJ", 0.55, 0.8), piece("1530kJ", 0.8, 0.8),
            piece("Protein, total", 0.2, 0.75), piece("2.4g", 0.55, 0.75), piece("8.0g", 0.8, 0.75),
            piece("Fat, total", 0.2, 0.7), piece("1.2g", 0.55, 0.7), piece("4.0g", 0.8, 0.7),
            piece("Carbohydrate", 0.2, 0.6), piece("21.0g", 0.55, 0.6), piece("70.0g", 0.8, 0.6)
        ]
        let p = NutritionTable.parse(pieces)
        XCTAssertEqual(p?.kcal100 ?? 0, 365.7, accuracy: 0.1)   // 1530 kJ ÷ 4.184
        XCTAssertEqual(p?.p100, 8.0)
        XCTAssertEqual(p?.f100, 4.0)
        XCTAssertEqual(p?.c100, 70.0)
        XCTAssertEqual(p?.servingSize, 30)
    }

    func testNumbersThatDontAddUpGoToTheAI() {
        let pieces = [
            piece("Per 100g", 0.55, 0.9),
            piece("Energy 250kcal", 0.3, 0.8),
            piece("Fat", 0.2, 0.7), piece("60g", 0.55, 0.7),          // a misread: 540 kcal of fat alone
            piece("Carbohydrate", 0.2, 0.6), piece("30g", 0.55, 0.6),
            piece("Protein", 0.2, 0.5), piece("5g", 0.55, 0.5)
        ]
        XCTAssertNil(NutritionTable.parse(pieces))
    }

    func testAPhotoWithNoTableGoesToTheAI() {
        XCTAssertNil(NutritionTable.parse([piece("Hot Cross Buns", 0.5, 0.8), piece("6 pack", 0.5, 0.7)]))
    }
}
