import SwiftUI

/// Cooking in bulk: what the finished pot weighs (an estimate, or what you weighed), so a portion, the calories per
/// 100 g cooked, how much to eat for your aims, and logging by the grams on your plate all come from the cooked dish.
struct CookedWeightCard: View {
    /// The whole dish's numbers, not a portion's.
    let kcal: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let portions: Double
    let estimate: Double?
    @Binding var weighed: Double?
    let aimKcal: Double?
    let aimProtein: Double?
    let log: (_ grams: Double, _ kcal: Double, _ p: Double, _ c: Double, _ f: Double) -> Void
    @State private var plate: Double?
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var total: Double? { weighed ?? estimate }

    var body: some View {
        if let total, total > 0, kcal > 0 {
            let per100 = kcal / total * 100, p100 = protein / total * 100
            let portion = total / portions
            let g = plate ?? (portion / 5).rounded() * 5
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Cooked weight")
                HStack(alignment: .firstTextBaseline) {
                    Text(weighed == nil ? "≈ \(Fmt.int(total)) g" : "\(Fmt.int(total)) g").font(.title2.weight(.heavy)).monospacedDigit()
                    Text(weighed == nil ? "estimated" : "weighed").font(.caption.weight(.semibold)).foregroundStyle(weighed == nil ? Color.secondary : Theme.accent)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text(weighed == nil ? "Weighed the pot?" : "Weighed").font(.subheadline)
                    Spacer()
                    TextField("grams", text: $typed).keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($typing)
                        .font(.subheadline.weight(.bold).monospacedDigit()).frame(width: 80)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onChange(of: typed) { _, t in
                            let v = Double(t.filter(\.isNumber))
                            weighed = (v ?? 0) > 0 ? v : nil
                            plate = nil
                        }
                    Text("g").foregroundStyle(.secondary)
                }
                Text(weighed == nil ? "Weigh it once it's cooked, without the dish, and every number here becomes exact."
                                    : "Cooking changes the water, not the calories: a lighter pot means more calories per gram.")
                    .font(.caption).foregroundStyle(.secondary)
                if let w = weighed, let est = estimate, CookedWeight.looksOff(weighed: w, estimate: est) {
                    // way off what goes in: usually a side (rice) in the ingredients but not in the pot
                    Label("That's a long way from the ≈ \(Fmt.int(est)) g these ingredients make. Is everything listed in the pot? Remove rice or sides you serve separately.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
                Divider()
                row("A portion (1 of \(Fmt.int(portions)))", "\(weighed == nil ? "≈ " : "")\(Fmt.int(portion)) g · \(Fmt.int(kcal / portions)) kcal")
                row("Per 100 g cooked", "\(Fmt.int(per100)) kcal · \(Fmt.int(p100)) g protein")
                // never more than there is: past the whole pot, say so instead
                if let aimKcal, aimKcal > 0 { row("For your \(Fmt.int(aimKcal)) kcal aim", upTo(aimKcal / per100 * 100, total)) }
                if let aimProtein, aimProtein > 0, p100 > 0 { row("For \(Fmt.int(aimProtein)) g protein", upTo(aimProtein / p100 * 100, total)) }
                Divider()
                HStack {
                    Text("On your plate").font(.subheadline)
                    Spacer()
                    Stepper(value: Binding(get: { g }, set: { plate = max(10, $0) }), in: 10...3000, step: 10) {
                        Text("\(Fmt.int(g)) g").font(.headline.monospacedDigit())
                    }
                    .fixedSize()
                }
                Button {
                    let f = g / 100
                    log(g, per100 * f, p100 * f, carbs / total * 100 * f, fat / total * 100 * f)
                } label: {
                    Text("Add \(Fmt.int(g)) g · \(Fmt.int(per100 * g / 100)) kcal").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
            .padding(14)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onAppear { if let weighed { typed = Fmt.int(weighed) } }
        }
    }

    private func upTo(_ grams: Double, _ total: Double) -> String {
        grams >= total ? "the whole pot (\(Fmt.int(total)) g)" : "\(Fmt.int(grams)) g"
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack { Text(l).font(.subheadline); Spacer(); Text(v).font(.subheadline.weight(.semibold)).monospacedDigit() }
    }
}
