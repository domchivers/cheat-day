import Foundation

/// Where you are, for portion sizes: a chicken thigh, a steak or a glass of wine isn't the same size in Melbourne,
/// London and New York. The built-in food list is sized for the UK; other places change the foods that differ most.
/// The AI is told the country too, so its estimates use local portions.
enum Region: String, CaseIterable, Identifiable {
    case uk, au, us
    var id: String { rawValue }

    var name: String { switch self { case .uk: return "the UK"; case .au: return "Australia"; case .us: return "the US" } }
    var code: String { switch self { case .uk: return "GB"; case .au: return "AU"; case .us: return "US" } }   // ISO, for web searches
    var label: String { switch self { case .uk: return "UK"; case .au: return "Australia"; case .us: return "US" } }

    /// Where the phone is: its time zone first (a Brit in Melbourne often keeps the UK region setting), then the
    /// region setting (Ireland counts as UK, New Zealand as Australia, Canada as US).
    static var detected: Region {
        let tz = TimeZone.current.identifier
        if tz.hasPrefix("Australia/") || tz.hasPrefix("Pacific/Auckland") { return .au }
        if tz == "Europe/London" || tz == "Europe/Dublin" { return .uk }
        if tz.hasPrefix("America/") && !["America/Sao_Paulo", "America/Mexico_City", "America/Bogota", "America/Lima", "America/Argentina/Buenos_Aires"].contains(tz) { return .us }
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

    /// A food-list item's numbers per 100 g (kcal, protein, carbs, fat) from this country's own table, where they
    /// differ (18 Nov). The list's raw chicken breast is 120 kcal; Australian chicken is 98 (AFCD), so the same 147 g
    /// was 176 kcal added from the list and 144 from the assistant, which goes by the AFCD.
    private static let numbers: [Region: [String: [Double]]] = [
        .au: [
            "Chicken breast, raw, skinless": [98, 22.5, 0, 0.8],     // AFCD: breast, lean flesh, raw
            "Chicken breast, cooked, skinless": [143, 29.8, 0, 2.5], // AFCD: breast, lean flesh, grilled, no added fat
            "Chicken thigh, raw, skinless": [104, 19.1, 0, 3],       // AFCD: thigh, lean flesh, raw
            "Chicken thigh, cooked, skinless": [175, 24.2, 0, 8.7],  // AFCD: thigh, lean flesh, baked, no added fat
        ]
    ]
    static func per100(_ name: String) -> [Double]? { numbers[current]?[name] }

    /// A food-list food saved earlier (in recents or history) with the portion size for here now, so one
    /// chicken thigh is an Australian thigh even if it was first added before. Scanned packs and your own foods are left alone.
    /// Its numbers are this country's too (per100), so a chicken breast saved at the list's 120 kcal comes back at 98.
    static func adjust(_ basis: JSON) -> JSON {
        guard str(basis["source"]) == "search" else { return basis }
        let name = str(basis["name"]), here = per100(name)
        guard portion(name) != nil || here != nil else { return basis }
        var b = basis
        if let h = here { b["kcalPer100"] = h[0]; b["p100"] = h[1]; b["c100"] = h[2]; b["f100"] = h[3] }
        guard let k100 = pos(b["kcalPer100"]) else { return b }
        let g = portion(name) ?? pos(b["servingSize"])
        if let g {
            b["servingSize"] = g
            b["kcalPerServing"] = (k100 * g / 10).rounded() / 10
        }
        if b["p100"] != nil { b.removeValue(forKey: "pServ"); b.removeValue(forKey: "cServ"); b.removeValue(forKey: "fServ") }   // per-100 macros scale with the new size
        return b
    }
}
