import SwiftUI

/// On Today, when Apple Health brings in a weigh-in-day reading: was it the usual way? Yes counts it; something
/// different keeps it on the chart but out of the trend. Left alone, it counts as usual and the card goes the next day.
struct WeighInConfirmCard: View {
    let day: String, kg: Double, at: Date?
    @State private var different = false
    @State private var why: Set<String> = []
    private var store: Store { Store.shared }
    static let reasons = ["Ate or drank first", "No toilet", "Different time", "Big night before"]

    /// Different opens it on the reasons, for the screenshot harness.
    init(day: String, kg: Double, at: Date?, different: Bool = false, why: Set<String> = []) {
        self.day = day; self.kg = kg; self.at = at
        _different = State(initialValue: different); _why = State(initialValue: why)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "New weigh-in · \(Store.whenTaken(day: day, at: at))", color: .secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.kg(kg)).font(.system(size: 40, weight: .heavy, design: .rounded))
                Text("kg").foregroundStyle(.secondary)
            }
            if different {
                Text("What was different?").font(.subheadline.weight(.semibold))
                ForEach([Array(Self.reasons.prefix(2)), Array(Self.reasons.suffix(2))], id: \.self) { pair in
                    HStack(spacing: 8) {
                        ForEach(pair, id: \.self) { r in
                            Chip(text: r, on: why.contains(r)) { if why.contains(r) { why.remove(r) } else { why.insert(r) } }
                        }
                    }
                }
                ButtonPair(first: "Save", second: "Back",
                           onFirst: { withAnimation { store.markWeighIn(day, usual: false, why: Self.reasons.filter(why.contains)) } },
                           onSecond: { withAnimation { different = false } })
                Text("It stays on your chart but is left out of your trend.").font(.caption).foregroundStyle(.secondary)
            } else {
                (Text("Usual weigh-in? ") + Text("Fasted, after the toilet.").foregroundColor(.secondary)).font(.subheadline)
                ButtonPair(first: "Yes, usual", second: "Something was different",
                           onFirst: { withAnimation { store.markWeighIn(day, usual: true) } },
                           onSecond: { withAnimation { different = true } })
                Text("Left alone, it counts as usual. Only asked on your weigh-in day.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("weighInConfirm")
    }
}
