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
    /// The dish's name, for what calories per 100 g make sense (a curry or stew is usually 80 to 200).
    var dish: String = ""
    @Binding var weighed: Double?
    let aimKcal: Double?
    let aimProtein: Double?
    let log: (_ grams: Double, _ kcal: Double, _ p: Double, _ c: Double, _ f: Double) -> Void
    @State private var plate: Double?
    @State private var typed = ""
    @FocusState private var typing: Bool
    @AppStorage("pot.grams") private var potGrams = 0.0   // your empty pot, saved once, taken off a full-pot weighing
    @AppStorage("pot.inPot") private var inPot = false
    @State private var settingPot = false
    @State private var potText = ""

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
                        .onChange(of: typed) { _, _ in applyTyped() }
                    Text("g").foregroundStyle(.secondary)
                }
                // weigh it in the pot: the pot's own weight comes off
                if potGrams > 0 {
                    Toggle("Weighed in the pot (takes off \(Fmt.int(potGrams)) g)", isOn: $inPot).font(.caption).tint(Theme.accent)
                        .onChange(of: inPot) { _, _ in applyTyped() }
                } else {
                    Button("Weighing it in the pot? Save the empty pot's weight") { potText = ""; settingPot = true }
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                }
                Text(weighed == nil ? "Weigh it once it's cooked, without the dish, and every number here becomes exact."
                                    : "Cooking changes the water, not the calories: a lighter pot means more calories per gram.")
                    .font(.caption).foregroundStyle(.secondary)
                let off = (weighed.flatMap { w in estimate.map { CookedWeight.looksOff(weighed: w, estimate: $0) } } ?? false)
                let range = Self.dishRange(dish)
                let oddPer100 = weighed != nil && (per100 < range.lo * 0.8 || per100 > range.hi * 1.2)
                if oddPer100 {
                    Label("\(Fmt.int(per100)) kcal per 100 g is \(per100 > range.hi ? "high" : "low") for \(range.label) (usually \(Fmt.int(range.lo))–\(Fmt.int(range.hi))). Check the pot's weight\(potGrams > 0 && !inPot ? ": was it weighed in the pot?" : ".")", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
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
                // when the weight looks wrong, a portion (the pot ÷ portions) is still right: it doesn't need grams
                if off || oddPer100 {
                    Button {
                        log(0, kcal / portions, protein / portions, carbs / portions, fat / portions)
                    } label: {
                        Text("Add 1 portion instead · \(Fmt.int(kcal / portions)) kcal").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onAppear { if let weighed { typed = Fmt.int(weighed + (inPot ? potGrams : 0)) } }
            .alert("Your empty pot", isPresented: $settingPot) {
                TextField("grams", text: $potText).keyboardType(.numberPad)
                Button("Save") { if let v = Double(potText.filter(\.isNumber)), v > 0 { potGrams = v; inPot = true; applyTyped() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Weigh the pot empty, once. Then weigh it full after cooking and its weight comes off.") }
        }
    }

    /// What you typed, less the pot when it was weighed in it.
    private func applyTyped() {
        let v = (Double(typed.filter(\.isNumber)) ?? 0) - (inPot ? potGrams : 0)
        weighed = v > 0 ? v : nil
        plate = nil
    }

    /// What calories per 100 g make sense for the dish, by its name.
    static func dishRange(_ dish: String) -> (label: String, lo: Double, hi: Double) {
        let n = dish.lowercased()
        if ["curry", "stew", "casserole", "chilli", "chili", "soup", "braise", "ragu", "bolognese", "goulash", "dahl", "dal", "tagine"].contains(where: { n.contains($0) }) {
            return ("a curry or stew", 80, 200)
        }
        return ("a cooked dish", 50, 450)
    }

    private func upTo(_ grams: Double, _ total: Double) -> String {
        grams >= total ? "the whole pot (\(Fmt.int(total)) g)" : "\(Fmt.int(grams)) g"
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack { Text(l).font(.subheadline); Spacer(); Text(v).font(.subheadline.weight(.semibold)).monospacedDigit() }
    }
}
