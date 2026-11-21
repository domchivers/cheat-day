import SwiftUI

/// A cheat day slot's numbers, ready to log (21 Nov, design/cheat-day-planner-mockup.html, as the owner's PUBCHA chat
/// gave them): each part's kcal, protein, carbs and fat, how much of each you'll have (a dish from a menu whole, half or
/// a third; anything else all, three quarters, half or a quarter: "if I have less rice?"), and the total following.
/// Log it logs exactly that; Keep in plan puts it in the plan.
struct SlotMacros: View {
    let slot: JSON
    var canLog: Bool
    var log: (JSON) -> Void
    var keep: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount: [Int: Double] = [:]   // a part's share: of the whole dish for a menu dish, else of what's planned

    private var parts: [JSON] { list(slot["parts"]) }
    private static let dishShares: [(Double, String)] = [(1, "Whole"), (0.5, "½"), (1.0 / 3, "⅓")]
    private static let partShares: [(Double, String)] = [(1, "All"), (0.75, "¾"), (0.5, "½"), (0.25, "¼")]

    /// A part as you'll have it: a menu dish from its whole (its planned share undone), anything else from what's planned.
    private func scaled(_ i: Int) -> (kcal: Double, p: Double, c: Double, f: Double) {
        let pt = parts[i], share = num(pt["share"]), planned = share ?? 1
        let by = share != nil ? (amount[i] ?? planned) / max(planned, 0.01) : (amount[i] ?? 1)
        return ((num(pt["kcal"]) ?? 0) * by, (num(pt["protein"]) ?? 0) * by, (num(pt["carbs"]) ?? 0) * by, (num(pt["fat"]) ?? 0) * by)
    }
    private var total: (kcal: Double, p: Double, c: Double, f: Double) {
        var k = 0.0, p = 0.0, c = 0.0, f = 0.0
        for i in parts.indices { let s = scaled(i); k += s.kcal; p += s.p; c += s.c; f += s.f }
        return (k, p, c, f)
    }
    private var guessed: Bool { slot["kcalLo"] != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    table
                    ForEach(parts.indices, id: \.self) { i in amountRow(i) }
                    if guessed {
                        Text("Estimates, give or take about 20%: nothing published for these.").font(.caption).foregroundStyle(Theme.warn)
                    }
                    let tips = slot["tips"] as? [String] ?? []
                    if !tips.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ORDERING TIPS").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                            ForEach(tips.indices, id: \.self) { i in Text("• " + tips[i]).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(str(slot["title"]))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private var table: some View {
        let t = total
        return VStack(spacing: 0) {
            row("", "kcal", "P", "C", "F", head: true)
            ForEach(parts.indices, id: \.self) { i in
                let s = scaled(i)
                row(name(i), Fmt.int(s.kcal), Fmt.int(s.p), Fmt.int(s.c), Fmt.int(s.f))
            }
            row(guessed ? "Total, estimated" : "Total", (guessed ? "~" : "") + Fmt.int(t.kcal), Fmt.int(t.p), Fmt.int(t.c), Fmt.int(t.f), bold: true)
        }
        .padding(12).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func name(_ i: Int) -> String {
        let pt = parts[i], n = str(pt["name"])
        if num(pt["share"]) != nil { let s = amount[i] ?? num(pt["share"]) ?? 1; return s < 0.99 ? Takeaway.frac(s) + " " + n : n }
        let a = amount[i] ?? 1, g = num(pt["grams"]) ?? 0
        return g > 0 ? "\(n), \(Fmt.int(g * a)) g" : (a < 0.99 ? Takeaway.frac(a) + " " + n : n)
    }

    private func row(_ a: String, _ k: String, _ p: String, _ c: String, _ f: String, head: Bool = false, bold: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(a).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            Text(k).frame(width: 52, alignment: .trailing)
            Text(p).frame(width: 34, alignment: .trailing)
            Text(c).frame(width: 34, alignment: .trailing)
            Text(f).frame(width: 34, alignment: .trailing)
        }
        .font(head ? .caption.weight(.bold) : bold ? .subheadline.weight(.heavy) : .subheadline)
        .foregroundStyle(head ? Color.secondary : Color.primary).monospacedDigit()
        .padding(.vertical, 5)
        .overlay(alignment: .top) { if !head { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) } }
    }

    /// How much of one part: a menu dish whole, half or a third; anything else all, ¾, ½ or ¼ of what's planned.
    private func amountRow(_ i: Int) -> some View {
        let pt = parts[i], dish = num(pt["share"]) != nil
        let options = dish ? Self.dishShares : Self.partShares, now = amount[i] ?? (dish ? num(pt["share"]) ?? 1 : 1)
        return VStack(alignment: .leading, spacing: 5) {
            Text(str(pt["name"]).uppercased()).font(.caption2.weight(.heavy)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 3) {
                ForEach(options.indices, id: \.self) { k in
                    let o = options[k], on = abs(now - o.0) < 0.01
                    Button { UISelectionFeedbackGenerator().selectionChanged(); amount[i] = o.0 } label: {
                        Text(o.1).font(.caption.weight(.bold)).frame(maxWidth: .infinity).frame(height: 32)
                            .foregroundStyle(on ? Color.black : Color.white)
                            .background(on ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// The slot as you'll have it: its parts and numbers as set here.
    private var adjusted: JSON {
        var s = slot
        let t = total
        s["parts"] = parts.indices.map { i -> JSON in
            var pt = parts[i]
            let v = scaled(i)
            pt["kcal"] = v.kcal.rounded(); pt["protein"] = v.p; pt["carbs"] = v.c; pt["fat"] = v.f
            if num(pt["share"]) != nil { pt["share"] = amount[i] ?? num(pt["share"]) ?? 1 } else if let g = num(pt["grams"]) { pt["grams"] = (g * (amount[i] ?? 1)).rounded() }
            return pt
        }
        if guessed {
            s["kcalLo"] = (t.kcal * 0.8 / 50).rounded(.down) * 50; s["kcalHi"] = (t.kcal * 1.2 / 50).rounded(.up) * 50
            s["pLo"] = (t.p * 0.8 / 5).rounded(.down) * 5; s["pHi"] = (t.p * 1.2 / 5).rounded(.up) * 5
        }
        s["kcal"] = t.kcal.rounded(); s["protein"] = t.p.rounded(); s["carbs"] = t.c.rounded(); s["fat"] = t.f.rounded()
        // a menu order's lines say how much of each dish
        if s["place"] != nil {
            s["detail"] = list(s["parts"]).map { p -> String in let sh = num(p["share"]) ?? 1; return (sh < 0.99 ? "\(Takeaway.frac(sh)) " : "") + str(p["name"]) }.joined(separator: "\n")
        }
        return s
    }

    private var buttons: some View {
        let t = total, changed = amount.contains { (e: (key: Int, value: Double)) -> Bool in abs(e.value - (num(parts[e.key]["share"]) ?? 1)) > 0.01 }
        return VStack(spacing: 8) {
            if canLog {
                Button { log(adjusted); dismiss() } label: {
                    Text("Log it · \(guessed ? "~" : "")\(Fmt.int(t.kcal)) kcal · \(Int(t.p.rounded())) g").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 16)).foregroundStyle(Theme.onAccent)
            }
            if changed {
                Button("Keep in the plan") { keep(adjusted); dismiss() }.font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10).background(Theme.bg)
    }
}
