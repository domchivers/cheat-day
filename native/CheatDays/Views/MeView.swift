import Charts
import SwiftUI

private struct WeightPoint: Identifiable { let id: String; let date: Date; let kg: Double; let trend: Double? }

/// Me: your weight against your goal, what it takes to get there, a nudge when the plan needs adjusting,
/// the weight chart, then the rest of the app in a short list.
struct MeView: View {
    @State private var weighing = false
    @State private var ranks = false
    @State private var showBody = false
    private var store: Store { Store.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    card(Theme.hero) { goalCard }
                    if let c = adjustment { card(Color(red: 0.13, green: 0.11, blue: 0.07)) { adjustCard(c) } }
                    card { weekCard }
                    tiles
                }
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.sync(); await store.pullBody() }
            .sheet(isPresented: $weighing) { WeighInSheet() }
            .navigationDestination(isPresented: $showBody) { BodyView() }
            .sheet(isPresented: $ranks) { RanksView() }
        }
    }

    // MARK: you

    private var header: some View {
        let name = Friends.shared.myName.isEmpty ? "Me" : Friends.shared.myName
        let streak = store.streakInfo.days
        return HStack(spacing: 12) {
            Text(String(name.prefix(1)).uppercased())
                .font(.title3.weight(.heavy)).foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48).background(Theme.hero, in: Circle())
            Button { ranks = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.title2.weight(.heavy)).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 5) {
                        RankBadge(rank: store.rank, size: 18)
                        Text("\(store.rank.name) rank").font(.caption.weight(.semibold)).foregroundStyle(store.rank.color)
                        if streak > 1 {
                            FluentIcon(emoji: "🔥", size: 14)
                            Text("\(streak)-day streak").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(store.rank.name) rank. Show ranks")
            Spacer()
            NavigationLink { SettingsView() } label: {
                FluentIcon(emoji: "⚙️", size: 24)
                    .frame(width: 44, height: 44).background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }

    private func card<C: View>(_ tint: Color = Color(.secondarySystemGroupedBackground), @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: the rest of the app, as tiles

    private var tiles: some View {
        let meals = CheatDays.list(store.doc["meals"]).count
        var items: [(icon: String, title: String, hint: String, to: AnyView)] = [
            ("🎯", "Plan", "Budget and cheat day", AnyView(BudgetView())),
            ("📈", "Body", "Weigh-ins and scale", AnyView(BodyView())),
            ("📖", "Meals", meals == 0 ? "Recipes you save" : "\(meals) saved", AnyView(MealsView())),
            ("🥗", "Food habits", store.habitItems.isEmpty ? "Keep, tweak or swap" : "\(store.habitItems.filter { $0.plan != nil }.count) changes", AnyView(HabitsView())),
            ("🗓️", "History", "Past days", AnyView(HistoryView())),
            ("🏆", "Badges", "\(store.seenBadges.count) of \(Badge.all.count)", AnyView(GoalsView()))
        ]
        if store.isHelper { items.append(("👨‍👩‍👧", "Family", "People you help", AnyView(FamilyView()))) }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(items.indices, id: \.self) { i in
                let t = items[i]
                NavigationLink { t.to } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        FluentIcon(emoji: t.icon, size: 30)
                        Text(t.title).font(.headline).foregroundStyle(.primary)
                        Text(t.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
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
        let now = store.lastWeighIn?.kg ?? pts.last?.kg   // the scale's own number; the trend is the small print
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
                    let fat = store.fatTrend.map { " · \(Fmt.one($0.pct))% body fat" } ?? ""
                    Text("Weighed \(Store.whenTaken(day: w.day, at: w.at))\(fat)").font(.caption).foregroundStyle(.secondary)
                }
                miniChart
                if let goal { statusLine(now: now, goal: goal) } else { setGoal(suggest: now) }
            } else {
                Text("Weigh in to start").font(.title3.bold())
                Text("Your trend, progress and date to your goal show here once you've weighed in a few times.").font(.footnote).foregroundStyle(.secondary)
            }
            Button { weighing = true } label: { Label("Weigh in", systemImage: "scalemass.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).foregroundStyle(.black)
        }
        .padding(.vertical, 6)
        // a simple summary here; the chart, readings, goals and the scale are all in Body
        .contentShape(Rectangle())
        .onTapGesture { showBody = true }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) { Text("Body"); Image(systemName: "chevron.right") }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    private func statusLine(now: Double, goal: Double) -> some View {
        let s = status(now: now, goal: goal)
        // the same date Body shows: the trend weight at the 4-week pace
        let date = store.reachDate(goal)?.formatted(.dateTime.day().month(.wide))
        let toGo = " · \(Fmt.kg(abs(now - goal))) kg to go"
        let paceText = pace.map { "\($0 < 0 ? "−" : "+")\(Fmt.one(abs($0))) kg a week" } ?? ""
        let title: String, body: String, tint: Color
        switch s {
        case .there: title = "You're there."; body = "Time to switch your plan to keeping it steady."; tint = .green
        case .early: title = "Keep weighing in."; body = "A trend needs a week or two of weigh-ins before it can give a date."; tint = .gray
        case .ahead: title = "Ahead of plan."; body = "\(Fmt.kg(goal)) kg around \(date ?? "soon")\(toGo)"; tint = .green
        case .onTrack: title = "On track."; body = "\(Fmt.kg(goal)) kg around \(date ?? "soon")\(toGo)"; tint = .green
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

    private var weekCard: some View {
        let base = pos(store.doc["budget"]) ?? store.baseBudget(store.today)
        let tw = twoWeeks
        let week = store.weekDates.map(store.dayFacts).filter(\.logged)
        let onBudget = week.filter(store.underBudget).count
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "This week", color: Theme.heroLabel)
            HStack {
                bigStat(Fmt.int(base), "budget a day")
                bigStat(tw.map { Fmt.int($0.avg) } ?? "–", "averaged")
                bigStat(week.isEmpty ? "–" : "\(onBudget)/\(week.count)", "on budget")
            }
            Text(advice(tw: tw)).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func bigStat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.weight(.heavy)).monospacedDigit()
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
        guard let goal, let now = store.lastWeighIn?.kg ?? store.latestWeight?.kg else {
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

    /// The last three months as one smooth trend line and the dashed goal. Tap for Body, which has the detail.
    private var miniChart: some View {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let pts = weights.filter { $0.date >= since && $0.trend != nil }
        let vals = pts.compactMap(\.trend) + (goal.map { [$0] } ?? [])
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1, pad = max(0.3, (hi - lo) * 0.15)
        return Group {
            if pts.count >= 2 {
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Day", p.date), y: .value("Trend", p.trend ?? 0)).foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)).interpolationMethod(.monotone)
                    }
                    if let goal { RuleMark(y: .value("Goal", goal)).foregroundStyle(Color.green.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 56)
                .overlay(alignment: .topTrailing) { Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary) }
            } else {
                Text("Weigh in a few times to see your trend").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Weight trend, last 3 months. Opens Body")
    }
}
