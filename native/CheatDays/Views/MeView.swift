import Charts
import SwiftUI

private struct WeightPoint: Identifiable { let id: String; let date: Date; let kg: Double; let trend: Double? }

/// Me: your weight against your goal, what it takes to get there, a nudge when the plan needs adjusting,
/// the weight chart, then the rest of the app in a short list.
struct MeView: View {
    @State private var weighing = false
    @State private var ranks = false
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            List {
                Section { goalCard }
                Section { howCard }
                if let c = adjustment { Section { adjustCard(c) }.listRowBackground(Color(red: 0.13, green: 0.11, blue: 0.07)) }
                Section {
                    NavigationLink { BodyView() } label: { chartCard }
                }
                Section {
                    NavigationLink { BudgetView() } label: { Label("Plan and budget", systemImage: "target") }
                    NavigationLink { BodyView() } label: { Label("Body and weigh-ins", systemImage: "scalemass.fill") }
                    NavigationLink { HistoryView() } label: { Label("History", systemImage: "calendar") }
                    NavigationLink { MealsView() } label: { Label("Your meals", systemImage: "fork.knife") }
                    NavigationLink { GoalsView() } label: { Label("Goals and badges", systemImage: "trophy.fill") }
                    if store.isHelper {
                        NavigationLink { FamilyView() } label: { Label("Family budgets", systemImage: "person.2.badge.gearshape.fill") }
                    }
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape.fill") }
                }
            }
            .navigationTitle("Me")
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .refreshable { await store.sync(); await store.pullBody() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { ranks = true } label: {
                        HStack(spacing: 5) {
                            RankBadge(rank: store.rank, size: 24)
                            Text(store.rank.name).font(.caption.weight(.bold)).foregroundStyle(store.rank.color)
                        }
                    }
                    .accessibilityLabel("Your rank: \(store.rank.name)")
                }
            }
            .sheet(isPresented: $weighing) { WeighInSheet().presentationDetents([.medium]) }
            .sheet(isPresented: $ranks) { RanksView() }
        }
    }

    // MARK: the numbers

    /// Weigh-ins with the smoothed trend through them (odd readings don't throw it off), last 120 days.
    private var weights: [WeightPoint] {
        let since = DayKey.shift(store.today, days: -120)
        let rows = store.bodyRows.compactMap { r -> (String, Double)? in
            guard let kg = pos(r["weight"]), str(r["day"]) >= since, str(r["day"]) <= store.today else { return nil }
            return (str(r["day"]), kg)
        }
        let t = rows.count >= 4 ? Trend.fit(days: rows.map(\.0), values: rows.map(\.1)).fit : rows.map(\.1)
        return rows.indices.map { WeightPoint(id: rows[$0].0, date: DayKey.date(rows[$0].0), kg: rows[$0].1, trend: rows.count >= 4 ? t[$0] : nil) }
    }

    private var plan: JSON { dict(store.doc["plan"]) }
    private var goal: Double? { pos(store.doc["goalWeight"]) }
    /// kg a week the plan aims for (negative when losing).
    private var planRate: Double? { num(plan["rate"]).flatMap { $0 == 0 ? nil : $0 } }
    /// kg a week the trend is actually moving.
    private var pace: Double? { store.weightTrend().map { $0.perDay * 7 } }

    private enum Status { case early, there, ahead, onTrack, behind, wrongWay }

    private func status(now: Double, goal: Double) -> Status {
        let left = goal - now
        if abs(left) < 0.3 { return .there }
        guard let pace else { return .early }
        if pace == 0 || (pace < 0) != (left < 0) { return abs(pace) < 0.05 ? .behind : .wrongWay }
        guard let want = planRate, (want < 0) == (left < 0) else { return .onTrack }
        let ratio = abs(pace) / abs(want)
        return ratio >= 1.2 ? .ahead : ratio >= 0.8 ? .onTrack : .behind
    }

    // MARK: 1 the goal

    private var goalCard: some View {
        let pts = weights
        let now = pts.last.map { $0.trend ?? $0.kg } ?? store.latestWeight?.kg
        let start = pos(dict(store.doc["goalStart"])["weight"]) ?? pts.first?.kg
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: goal == nil ? "Your weight" : "Your goal", color: Theme.heroLabel)
            if let now {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Fmt.kg(now)).font(.system(size: 44, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                        Text("kg").font(.headline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let goal {
                        (Text("→ ").foregroundStyle(.secondary) + Text(Fmt.kg(goal)).font(.title3.weight(.heavy)) + Text(" kg").foregroundStyle(.secondary)).font(.title3)
                    }
                }
                if let w = store.lastWeighIn {
                    Text("Trend · last weigh-in \(Fmt.kg(w.kg)) kg, \(Store.whenTaken(day: w.day, at: w.at))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let goal {
                    progress(start: start ?? now, now: now, goal: goal)
                    statusLine(now: now, goal: goal)
                } else {
                    setGoal(suggest: now)
                }
            } else {
                Text("Weigh in to start").font(.title3.bold())
                Text("Your trend, progress and date to your goal show here once you've weighed in a few times.").font(.footnote).foregroundStyle(.secondary)
            }
            Button { weighing = true } label: { Label("Weigh in", systemImage: "scalemass.fill").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
        .padding(.vertical, 6)
    }

    private func progress(start: Double, now: Double, goal: Double) -> some View {
        let total = abs(start - goal), done = max(0, min(total, total - abs(now - goal)))
        let share = total > 0 ? done / total : 1
        return VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(Color.green).frame(width: max(9, g.size.width * share))
                    Circle().fill(.white).frame(width: 15, height: 15).overlay(Circle().stroke(Color.green, lineWidth: 3))
                        .offset(x: max(0, min(g.size.width - 15, g.size.width * share - 7.5)))
                }
            }
            .frame(height: 15)
            HStack {
                Text("Started \(Fmt.kg(start))")
                Spacer()
                Text("\(Fmt.kg(done)) \(goal < start ? "down" : "up") · \(Fmt.kg(abs(now - goal))) to go")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusLine(now: Double, goal: Double) -> some View {
        let s = status(now: now, goal: goal), left = goal - now
        let date: String? = pace.flatMap { p -> String? in
            guard p != 0, (p < 0) == (left < 0) else { return nil }
            let days = Int(abs(left / p) * 7)
            guard days < 1500, let d = Calendar.current.date(byAdding: .day, value: days, to: Date()) else { return nil }
            return d.formatted(.dateTime.day().month(.wide))
        }
        let paceText = pace.map { "\($0 < 0 ? "−" : "+")\(Fmt.one(abs($0))) kg a week" } ?? ""
        let title: String, body: String, tint: Color
        switch s {
        case .there: title = "You're there."; body = "Time to switch your plan to keeping it steady."; tint = .green
        case .early: title = "Keep weighing in."; body = "A trend needs a week or two of weigh-ins before it can give a date."; tint = .gray
        case .ahead: title = "Ahead of plan."; body = "At \(paceText) you'll reach \(Fmt.kg(goal)) kg around \(date ?? "soon")."; tint = .green
        case .onTrack: title = "On track."; body = "At \(paceText) you'll reach \(Fmt.kg(goal)) kg around \(date ?? "soon")."; tint = .green
        case .behind: title = "Slower than planned."; body = date.map { "At \(paceText) you'd get there around \($0)." } ?? "Your weight's barely moving at the moment."; tint = Theme.warn
        case .wrongWay: title = "Going the wrong way."; body = "Your trend is \(paceText) at the moment. See how to get there below."; tint = Theme.warn
        }
        return (Text(title).bold() + Text(" " + body)).font(.footnote)
            .padding(.horizontal, 11).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func setGoal(suggest now: Double) -> some View {
        HStack {
            Text("Set a goal weight").font(.subheadline.weight(.semibold))
            Spacer()
            Stepper(value: Binding(get: { (now - 3).rounded() }, set: { store.setGoalWeight($0) }), in: 35...250, step: 0.5) { EmptyView() }.labelsHidden()
        }
    }

    // MARK: 2 how to get there

    /// Average eaten on logged days over the last two weeks (not today, which isn't over).
    private var twoWeeks: (avg: Double, budget: Double, days: Int)? {
        var kcal = 0.0, budget = 0.0, n = 0
        for i in 1...14 {
            let f = store.dayFacts(DayKey.shift(store.today, days: -i))
            guard f.logged else { continue }
            kcal += f.kcal; budget += f.budget; n += 1
        }
        return n >= 3 ? (kcal / Double(n), budget / Double(n), n) : nil
    }

    private var howCard: some View {
        let base = pos(store.doc["budget"]) ?? store.baseBudget(store.today)
        let tw = twoWeeks
        let burn = store.checkIn.burn ?? pos(plan["learnedBurn"]) ?? pos(plan["tdee"])
        let week = store.weekDates.map(store.dayFacts).filter(\.logged)
        let onBudget = week.filter(store.underBudget).count
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "How to get there", color: Theme.heroLabel)
            line("Your budget", "\(Fmt.int(base)) a day")
            if let wd = store.cheatWeekday {
                line("Cheat day", "\(Calendar.current.weekdaySymbols[wd]) · \(Fmt.int(store.baseBudget(store.nextCheat?.date ?? store.today)))")
            }
            if let tw { line("You've averaged", "\(Fmt.int(tw.avg)) a day", note: "last 2 weeks") }
            if let burn { line("You burn about", "\(Fmt.int(burn)) a day") }
            if !week.isEmpty { line("This week", "\(onBudget) of \(week.count) days on budget") }
            Text(advice(tw: tw)).font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(.vertical, 4)
    }

    private func line(_ l: String, _ v: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(l).font(.subheadline)
            Spacer()
            Text(v).font(.subheadline.weight(.bold)).monospacedDigit()
            if let note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    /// One plain sentence on what to do next, from the numbers.
    private func advice(tw: (avg: Double, budget: Double, days: Int)?) -> String {
        guard let goal, let now = weights.last.map({ $0.trend ?? $0.kg }) ?? store.latestWeight?.kg else {
            return "Set a goal weight and the app works out how to get there."
        }
        let s = status(now: now, goal: goal)
        if s == .there { return "Change your goal to staying where you are in Plan and budget, and you'll get a budget to match." }
        if let tw, tw.avg > tw.budget + 120 {
            return "You're averaging \(Fmt.int(tw.avg - tw.budget)) a day over your budget. Getting the weekdays closer to it is the quickest fix."
        }
        let pDays = store.weekProgress["protein"] ?? 0, logged = store.weekProgress["log"] ?? 0
        if s == .behind || s == .wrongWay {
            if let tw, tw.days < 9 { return "You've logged \(tw.days) of the last 14 days. Logging every day shows what's really going in." }
            return "You're sticking to your budget but losing slower than planned, so you probably burn less than estimated. The weekly check-in will suggest a new budget."
        }
        if store.proteinGoal != nil && logged >= 3 && pDays * 2 < logged {
            return "Keep doing what you're doing. Hitting protein more often (\(pDays) of \(logged) days) will help keep muscle as you lose."
        }
        return "Keep doing what you're doing."
    }

    // MARK: 3 time to adjust

    /// The weekly check-in's suggestion, when it's waiting and worth acting on.
    private var adjustment: CheckIn? {
        let c = store.checkIn
        guard store.checkInDue, let s = c.suggest, abs(s - c.now) >= 50 else { return nil }
        return c
    }

    private func adjustCard(_ c: CheckIn) -> some View {
        let s = c.suggest ?? c.now, up = s > c.now
        let base = pos(store.doc["budget"]) ?? c.now, ratio = c.now > 0 ? s / c.now : 1
        let newBase = (base * ratio / 10).rounded() * 10
        let cheat = store.cheatWeekday.map { _ in store.baseBudget(store.nextCheat?.date ?? store.today) * ratio }
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Time to adjust?", color: Theme.warn)
            Text(why(c, up: up) + " To stay on plan, \(up ? "go up" : "drop") to \(Fmt.int(newBase)) a day\(cheat.map { " (cheat day \(Fmt.int(($0 / 10).rounded() * 10)))" } ?? "").")
                .font(.subheadline)
            HStack(spacing: 10) {
                Button { withAnimation { store.finishCheckIn(c, use: true) } } label: { Text("Use \(Fmt.int(newBase))").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 4) }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
                Button { withAnimation { store.finishCheckIn(c, use: false) } } label: { Text("Keep \(Fmt.int(base))").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 4) }
                    .buttonStyle(.bordered)
            }
            .buttonBorderShape(.roundedRectangle(radius: 12))
            NavigationLink { CheckInView() } label: { Text("See the full check-in").font(.caption.weight(.semibold)) }
        }
        .padding(.vertical, 4)
    }

    private func why(_ c: CheckIn, up: Bool) -> String {
        if let p = c.pace, let w = c.want {
            return up ? "You're losing faster than planned (\(Fmt.one(abs(p))) kg a week against \(Fmt.one(abs(w))))."
                      : "Your weight's moving slower than planned (\(Fmt.one(abs(p))) kg a week against \(Fmt.one(abs(w))))."
        }
        if let b = c.burn { return "You burn about \(Fmt.int(b)) a day, worked out from your logging and weigh-ins." }
        return "Your numbers have changed."
    }

    // MARK: 4 the chart

    private var chartCard: some View {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let pts = weights.filter { $0.date >= since }
        let vals = pts.map(\.kg) + (goal.map { [$0] } ?? [])
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1, pad = max(0.5, (hi - lo) * 0.12)
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Weight · 3 months", color: Theme.heroLabel)
            if pts.count < 2 {
                Text("Weigh in a few times and your trend shows here.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(pts) { p in PointMark(x: .value("Day", p.date), y: .value("kg", p.kg)).foregroundStyle(Theme.accent.opacity(0.45)).symbolSize(18) }
                    ForEach(pts.filter { $0.trend != nil }) { p in
                        LineMark(x: .value("Day", p.date), y: .value("Trend", p.trend ?? 0)).foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round)).interpolationMethod(.catmullRom)
                    }
                    if let goal { RuleMark(y: .value("Goal", goal)).foregroundStyle(Color.green.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .frame(height: 130)
            }
        }
        .padding(.vertical, 4)
    }
}
