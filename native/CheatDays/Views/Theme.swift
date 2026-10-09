import SwiftUI
import UIKit

/// The look from the prototype: near-black, one soft blue, rounded type.
enum Theme {
    static let accent = Color(red: 0.49, green: 0.77, blue: 1.0)
    static let bg = Color(red: 0.027, green: 0.035, blue: 0.047)
    static let hero = Color(red: 0.06, green: 0.10, blue: 0.15)
    static let heroLabel = Color(red: 0.56, green: 0.73, blue: 0.87)
    static let track = Color(red: 0.11, green: 0.17, blue: 0.23)
    static let warn = Color(red: 0.95, green: 0.71, blue: 0.36)
    /// Each meal's colour in the calorie bar.
    static func meal(_ meal: String) -> Color {
        switch meal {
        case "Breakfast": return Color(red: 0.98, green: 0.78, blue: 0.40)
        case "Lunch": return Color(red: 0.36, green: 0.82, blue: 0.62)
        case "Dinner": return accent
        default: return Color(red: 0.93, green: 0.55, blue: 0.70)
        }
    }
    static let uiBackground = UIColor(red: 0.027, green: 0.035, blue: 0.047, alpha: 1)

    static func tone(_ name: String) -> (bg: Color, fg: Color) {
        switch toneKey(name) {
        case 0: return (Color(red: 0.16, green: 0.13, blue: 0.09), Color(red: 0.95, green: 0.78, blue: 0.47))
        case 1: return (Color(red: 0.08, green: 0.14, blue: 0.19), accent)
        case 2: return (Color(red: 0.14, green: 0.10, blue: 0.17), Color(red: 0.84, green: 0.64, blue: 0.94))
        default: return (Color(red: 0.11, green: 0.16, blue: 0.12), Color(red: 0.56, green: 0.86, blue: 0.67))
        }
    }
    private static func toneKey(_ name: String) -> Int { abs(name.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 4 }

    /// An SF Symbol that fits the food, roughly.
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        let table: [(String, [String])] = [
            ("cup.and.saucer.fill", ["coffee", "flat white", "latte", "tea", "cappuccino"]),
            ("wineglass.fill", ["wine", "prosecco", "champagne"]),
            ("mug.fill", ["beer", "cider", "lager", "ale"]),
            ("birthday.cake.fill", ["cake", "brownie", "muffin", "cookie", "biscuit", "tim tam", "chocolate"]),
            ("carrot.fill", ["salad", "veg", "carrot", "broccoli", "spinach"]),
            ("fish.fill", ["salmon", "tuna", "fish", "prawn", "shrimp"]),
            ("frying.pan.fill", ["egg", "omelette", "bacon", "scrambled"]),
            ("leaf.fill", ["apple", "banana", "orange", "berries", "fruit", "grape"]),
            ("takeoutbag.and.cup.and.straw.fill", ["burger", "fries", "chips", "kebab", "takeaway", "pizza"]),
            ("fork.knife", ["pasta", "curry", "rice", "noodle", "chicken", "beef", "steak", "pad thai", "bowl", "wrap", "sandwich"])
        ]
        for (symbol, words) in table where words.contains(where: { n.contains($0) }) { return symbol }
        return "fork.knife"
    }
}

/// A round tinted icon for a food line.
struct FoodDot: View {
    let name: String
    var size: CGFloat = 34
    var body: some View {
        let t = Theme.tone(name)
        Image(systemName: Theme.symbol(for: name))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(t.fg)
            .frame(width: size, height: size)
            .background(t.bg, in: Circle())
    }
}

/// Small uppercase labels above big numbers.
struct Eyebrow: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(color)
    }
}
