import SwiftUI

/// The running card of a meal chat (design/meal-chat-mockup.html, approved 25 Nov), shown under the latest answer only.
/// Solid bar: what they've had. Faded: what's suggested next.
/// 1. Before eating: have next, in this order, and what they'd finish on. Nothing counts until they say they've had it.
/// 2. While eating: had so far (folded to one line), have next, finish on.
/// 3. Done (nothing more to suggest): you had, the totals, and one Add that puts the meal on as one entry; had more
///    later, the same entry is changed rather than another added.
struct MealRunCard: View {
    let result: JSON
    let turn: UUID
    let meal: String
    @State private var openHad = false
    private var live: AssistantLive { AssistantLive.shared }
    private var store: Store { Store.shared }

    var body: some View {
        let had: [JSON] = MealChat.tally(result), next: [JSON] = MealChat.next(result)
        let t: MealChat.Totals = MealChat.totals(had), n: MealChat.Totals = MealChat.totals(next)
        let base: JSON = dict(result["mealBase"])
        let left: Double = num(base["kcal"]) ?? 0, need: Double = num(base["p"]) ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                meter(had: t.kcal, next: n.kcal, of: left, unit: "kcal")
                if need > 0 { meter(had: t.p, next: n.p, of: need, unit: "g protein") }
            }
            .padding(.bottom, 4)
            if had.isEmpty {
                nextList(next)
                if !next.isEmpty { finish(t, n) }
                Text("Estimates from your receipt and photos, give or take 20%.").font(.caption2).foregroundStyle(.secondary)
            } else if !next.isEmpty {
                hadSoFar(had, t)
                nextList(next)
                finish(t, n)
            } else {
                header("You had", "kcal · P")
                rows(had)
                Text("\(Fmt.int(t.kcal)) kcal · P \(Int(t.p.rounded())) · C \(Int(t.c.rounded())) · F \(Int(t.f.rounded()))")
                    .modifier(SumLine())
                addRow(had)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func meter(had: Double, next: Double, of total: Double, unit: String) -> some View {
        let a: Double = total > 0 ? min(1, had / total) : 0
        let b: Double = total > 0 ? min(1 - a, max(0, next / total)) : 0
        let over: Bool = total > 0 && had > total
        return VStack(alignment: .leading, spacing: 5) {
            (Text(Fmt.int(had)).font(.title3.weight(.bold)) + Text(" of \(Fmt.int(total)) \(unit)").font(.caption).foregroundStyle(.secondary))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            GeometryReader { g in
                HStack(spacing: 0) {
                    Rectangle().fill(over ? Theme.warn : Theme.accent).frame(width: g.size.width * a)
                    Rectangle().fill(Theme.accent.opacity(0.3)).frame(width: g.size.width * b)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(Color.primary.opacity(0.1))
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.int(had)) of \(Fmt.int(total)) \(unit) had, \(Fmt.int(next)) more suggested")
    }

    private func header(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
        }
        .font(.caption2.weight(.heavy)).textCase(.uppercase).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func row(_ name: String, _ amount: String, kcal: Double, protein: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            (Text(name) + Text(amount.isEmpty ? "" : "  " + amount).font(.caption).foregroundStyle(.secondary))
                .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.int(kcal)).font(.subheadline).monospacedDigit().frame(width: 48, alignment: .trailing)
            Text("\(Int(protein.rounded()))").font(.subheadline).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func rows(_ had: [JSON]) -> some View {
        ForEach(had.indices, id: \.self) { i in
            let s = MealChat.split(str(had[i]["name"]))
            row(s.food, s.amount, kcal: num(had[i]["kcal"]) ?? 0, protein: num(had[i]["protein_g"]) ?? 0)
        }
    }

    @ViewBuilder private func nextList(_ next: [JSON]) -> some View {
        if !next.isEmpty {
            header("Have next, in this order", "kcal · P")
            ForEach(next.indices, id: \.self) { i in
                row(str(next[i]["name"]), str(next[i]["amount"]), kcal: num(next[i]["kcal"]) ?? 0, protein: num(next[i]["protein_g"]) ?? 0)
            }
        }
    }

    @ViewBuilder private func hadSoFar(_ had: [JSON], _ t: MealChat.Totals) -> some View {
        Button { withAnimation(.snappy) { openHad.toggle() } } label: {
            HStack(spacing: 4) {
                Text("Had so far · \(had.count) food\(had.count == 1 ? "" : "s")")
                Image(systemName: openHad ? "chevron.up" : "chevron.down")
                Spacer()
                Text("\(Fmt.int(t.kcal)) · \(Int(t.p.rounded()))").monospacedDigit()
            }
            .font(.caption2.weight(.heavy)).textCase(.uppercase).foregroundStyle(.secondary).padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(openHad ? "Folds the list" : "Shows each food")
        if openHad { rows(had) }
        else { Text(MealChat.line(had)).font(.caption).foregroundStyle(.secondary) }
    }

    private func finish(_ t: MealChat.Totals, _ n: MealChat.Totals) -> some View {
        Text("You'd finish on about \(Fmt.int(t.kcal + n.kcal)) kcal and \(Int((t.p + n.p).rounded())) g").modifier(SumLine())
    }

    /// One Add for the whole meal: Added once the day has this tally, Update when they've had more since.
    @ViewBuilder private func addRow(_ had: [JSON]) -> some View {
        let id: String? = MealChat.entryId(live.turns)
        let item: JSON? = id.flatMap { i in store.todayItems.first { str($0["id"]) == i } }
        let on: Bool = id.map { store.hasItem($0) } ?? false
        let same: Bool = MealChat.matches(item, parts: had)
        let what: String = meal.lowercased()
        Button { add(had, over: on ? id : nil) } label: {
            Label(same ? "Added" : on ? "Update \(what)" : "Add \(what) to today", systemImage: same ? "checkmark" : "plus.circle.fill")
                .font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 40)
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accent.opacity(same ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain).disabled(same || had.isEmpty)
        .padding(.top, 4)
        Text("Adds one entry. Had more later? The same entry updates.").font(.caption2).foregroundStyle(.secondary)
    }

    private func add(_ had: [JSON], over old: String?) {
        let named = str(dict(result["estimate"])["name"])
        let id = MealChat.put(had, name: named.isEmpty ? meal : named, meal: meal, over: old, store: store)
        if let i = live.turns.firstIndex(where: { $0.id == turn }) {
            var r = live.turns[i].result ?? [:]
            r["mealEntry"] = id
            withAnimation { live.turns[i].result = r }
        }
        live.keep(store)
    }
}

/// The card's green totals line.
private struct SumLine: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.footnote.weight(.bold)).monospacedDigit().foregroundStyle(Color.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 4)
    }
}
