import Charts
import SwiftUI

/// The weekly check-in: the weight trend from the weigh-ins that count and what it makes of it, last week's food,
/// what you really burn, and, only when it's off the goal for long enough, a new budget to use or keep.
struct CheckInView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    var body: some View {
        let c = store.checkIn
        List {
            Section { trend(c) }
            Section {
                fact("Ate on average", c.avg.map { "\(Fmt.int($0)) kcal" } ?? "nothing logged")
                fact("Days logged", "\(c.wellLogged) of 7")
                fact("You burn about", c.burn.map { "\(Fmt.int($0)) kcal" } ?? "not enough yet")
                fact("Workouts", "\(c.workouts)")
                fact("Budget", c.step.map { "\($0 > 0 ? "+" : "−")\(Fmt.int(abs($0))) a day" } ?? "No change")
            } header: { Text("Last week · \(range(c))") } footer: {
                if c.burn == nil, !c.needs.isEmpty { Text("Working out what you burn needs \(c.needs.joined(separator: " and ")).") }
            }
            if let focus = store.habitFocus {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        FluentIcon(emoji: "🥗", size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(focus).font(.headline)
                            Text("One thing from your food habits. Next week there's another.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: { Text("This week, try") }
            }
            if let step = c.step {
                Section { suggestion(c, step) } footer: { Text("Never more than 150 a day at once. Nothing changes unless you choose it.") }
            } else {
                Section {
                    Button { store.finishCheckIn(c, use: false); dismiss() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity) }
                } footer: {
                    Text(c.want == nil ? "Set a goal under Plan and budget, and the check-in works out the calories that get you there."
                                       : "Worked out \(Date().formatted(date: .abbreviated, time: .shortened)). Grey dots are weigh-ins shown but not counted.")
                }
            }
        }
        .navigationTitle("Weekly check-in")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    // MARK: the weight trend

    @ViewBuilder private func trend(_ c: CheckIn) -> some View {
        if let r = c.rate {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Weight trend · \(r.method)", color: Theme.heroLabel)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(r.perWeek > 0.005 ? "+" : r.perWeek < -0.005 ? "−" : "")\(String(format: "%.2f", abs(r.perWeek)))")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                    Text("kg a week").foregroundStyle(.secondary)
                }
                if let want = c.want, let tol = c.tol { Text(goal(want, tol)).font(.subheadline).foregroundStyle(.secondary) }
                chart(r).frame(height: 110).padding(.vertical, 4)
                if !c.verdict.isEmpty {
                    Text(c.verdict).font(.footnote).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(tone(c).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Weight trend").font(.headline)
                Text(store.weighDay.map { "Needs 3 \(Calendar.current.weekdaySymbols[$0]) weigh-ins over 2 weeks or more." }
                     ?? "Needs 3 weigh-ins over 2 weeks or more.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    /// The readings that count, the line through them, and the ones left out in grey; a likely water swing as a ring.
    private func chart(_ r: Adaptive.Rate) -> some View {
        let fit = Adaptive.line(r.used), first = r.used.first.map { DayKey.date($0.day) } ?? Date()
        let kgs = (r.used + r.left).map(\.kg), lo = (kgs.min() ?? 0) - 0.3, hi = (kgs.max() ?? 1) + 0.3
        return Chart {
            if let fit, let last = r.used.last {
                ForEach([first, DayKey.date(last.day)], id: \.self) { d in
                    LineMark(x: .value("Day", d), y: .value("kg", fit.intercept + fit.slope * d.timeIntervalSince(first) / 86400))
                        .foregroundStyle(Theme.accent.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                }
            }
            ForEach(r.left, id: \.day) { p in
                PointMark(x: .value("Day", DayKey.date(p.day)), y: .value("kg", p.kg)).foregroundStyle(.gray.opacity(0.5)).symbolSize(40)
            }
            ForEach(r.used, id: \.day) { p in
                let swing = r.swing != nil && p.day == r.used.last?.day
                PointMark(x: .value("Day", DayKey.date(p.day)), y: .value("kg", p.kg))
                    .foregroundStyle(swing ? Theme.warn : Theme.accent).symbolSize(swing ? 90 : 50)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
        .accessibilityLabel("Weight trend chart")
    }

    private func tone(_ c: CheckIn) -> Color {
        if c.step != nil { return Theme.accent }
        return c.verdict.hasPrefix("On track") ? Theme.walk : Theme.warn
    }

    // MARK: a new budget

    /// The change as the week will look: days with the same before and after grouped ("Mon to Fri"), the treat day kept.
    @ViewBuilder private func suggestion(_ c: CheckIn, _ step: Double) -> some View {
        let treat = store.cheatWeekday, now = dayBudgets
        let base = Int(pos(store.doc["budget"]) ?? 1600)
        let out = Adaptive.spread(step, budget: base, days: now, treat: treat)
        let order = [1, 2, 3, 4, 5, 6, 0]
        let pairs = order.map { d in (d, now[d] ?? base, out.days[d] ?? out.budget) }
        let groups = pairs.reduce(into: [[(Int, Int, Int)]]()) { g, p in
            if let last = g.last?.last, last.1 == p.1, last.2 == p.2, last.0 != treat, p.0 != treat { g[g.count - 1].append(p) } else { g.append([p]) }
        }
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: "Suggested budget", color: Theme.heroLabel)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(step > 0 ? "+" : "−")\(Fmt.int(abs(step)))").font(.system(size: 40, weight: .heavy, design: .rounded))
                Text("kcal a day").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        ForEach(groups.indices, id: \.self) { i in
            let g = groups[i], name = { (d: Int) in Calendar.current.shortWeekdaySymbols[d] }
            let label = g.count == 1 ? Calendar.current.weekdaySymbols[g[0].0] : "\(name(g[0].0)) to \(name(g[g.count - 1].0))"
            HStack {
                Text(label + (g[0].0 == treat ? " (treat day)" : "")).foregroundStyle(.secondary)
                Spacer()
                Text(g[0].1 == g[0].2 ? "\(Fmt.int(Double(g[0].1))), unchanged" : "\(Fmt.int(Double(g[0].1))) → \(Fmt.int(Double(g[0].2)))")
                    .fontWeight(.semibold).monospacedDigit().foregroundStyle(g[0].1 == g[0].2 ? .secondary : .primary)
            }
        }
        ButtonPair(first: "Use it", second: "Keep my budget",
                   onFirst: { store.finishCheckIn(c, use: true); dismiss() }, onSecond: { store.finishCheckIn(c, use: false); dismiss() })
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
    }

    // MARK: bits

    private var dayBudgets: [Int: Int] {
        var out: [Int: Int] = [:]
        for (k, v) in dict(store.doc["dayBudgets"]) { if let i = Int(k), let n = num(v) { out[i] = Int(n) } }
        return out
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).fontWeight(.semibold) }
    }
    private func goal(_ w: Double, _ tol: Double) -> String {
        let f = { (v: Double) in String(format: "%.2f", v) }
        if w == 0 { return "Your goal: hold steady (OK within \(f(tol)) either way)" }
        return "Your goal: \(w < 0 ? "lose" : "gain") \(f(abs(w))) (OK from \(f(max(0, abs(w) - tol))) to \(f(abs(w) + tol)))"
    }
    private func range(_ c: CheckIn) -> String {
        let f = { (d: String) in DayKey.date(d).formatted(.dateTime.day().month(.abbreviated)) }
        return "\(f(c.mon)) to \(f(c.sun))"
    }
}
