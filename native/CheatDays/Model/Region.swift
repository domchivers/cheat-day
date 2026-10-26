import Foundation

/// Where you are, for portion sizes: a chicken thigh, a steak or a glass of wine isn't the same size in Melbourne,
/// London and New York. The built-in food list is sized for the UK; other places change the foods that differ most.
/// The AI is told the country too, so its estimates use local portions.
enum Region: String, CaseIterable, Identifiable {
    case uk, au, us
    var id: String { rawValue }

    var name: String { switch self { case .uk: return "the UK"; case .au: return "Australia"; case .us: return "the US" } }
    var label: String { switch self { case .uk: return "UK"; case .au: return "Australia"; case .us: return "US" } }

    /// From the phone's region (Ireland counts as UK, New Zealand as Australia, Canada as US).
    static var detected: Region {
        switch Locale.current.region?.identifier {
        case "AU", "NZ": return .au
        case "US", "CA": return .us
        default: return .uk
        }
    }

    /// The Settings choice; empty means follow the phone.
    static var choice: String {
        get { UserDefaults.standard.string(forKey: "region") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "region") }
    }

    static var current: Region { Region(rawValue: choice) ?? detected }

    /// Usual portion (grams or ml) where it differs from the UK list, by the food list's name.
    private static let portions: [Region: [String: Double]] = [
        .au: [
            "Chicken thigh, cooked, skinless": 110, "Chicken thigh, cooked, with skin": 120,
            "Chicken thigh, raw, skinless": 140, "Chicken thigh, raw, with skin": 160,
            "Chicken breast, cooked, skinless": 170, "Chicken breast, raw, skinless": 230,
            "Beef steak, grilled": 250, "Beef steak, raw": 300,
            "Pork chop, grilled": 180, "Pork chop, raw": 220,
            "Salmon fillet, raw": 180, "Salmon fillet, cooked": 180,
            "Sausage, pork, grilled": 70, "Sausage, pork, raw": 85,
            "Bread, white": 40, "Bread, wholemeal": 40,
            "Red wine": 150, "White wine": 150, "Rose wine": 150
        ],
        .us: [
            "Chicken thigh, cooked, skinless": 100, "Chicken thigh, raw, skinless": 130,
            "Chicken breast, cooked, skinless": 200, "Chicken breast, raw, skinless": 280,
            "Beef steak, grilled": 280, "Beef steak, raw": 340,
            "Pork chop, grilled": 170, "Pork chop, raw": 210,
            "Salmon fillet, raw": 170, "Salmon fillet, cooked": 170,
            "Bread, white": 30, "Bread, wholemeal": 32,
            "Red wine": 150, "White wine": 150, "Rose wine": 150,
            "Milk, whole": 240, "Milk, semi-skimmed": 240, "Milk, skimmed": 240
        ]
    ]

    /// The usual portion for a food-list item here, or nil to keep the list's own.
    static func portion(_ name: String) -> Double? { portions[current]?[name] }

    /// A food-list food saved earlier (in recents or history) with the portion size for here now, so one
    /// chicken thigh is an Australian thigh even if it was first added before. Scanned packs and your own foods are left alone.
    static func adjust(_ basis: JSON) -> JSON {
        guard str(basis["source"]) == "search", let g = portion(str(basis["name"])), let k100 = pos(basis["kcalPer100"]) else { return basis }
        var b = basis
        b["servingSize"] = g
        b["kcalPerServing"] = (k100 * g / 10).rounded() / 10
        if b["p100"] != nil { b.removeValue(forKey: "pServ"); b.removeValue(forKey: "cServ"); b.removeValue(forKey: "fServ") }   // per-100 macros scale with the new size
        return b
    }
}
