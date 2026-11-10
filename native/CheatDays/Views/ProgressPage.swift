import Charts
import SwiftUI

/// The Progress tab, laid out like Friends: the big title and round buttons, a quiet line on how you're doing, your
/// weight on one clean chart across the card, the week as bars, protein and streak, then everything else in a list.
struct ProgressPage: View {
    @State private var range = 30
    @State private var weighing = false
    @State private var metric = "weight"
    @State private var picked: Date?   // a day held on the chart
    @State private var editing: JSON?   // a reading being changed
    private var store: Store { Store.shared }
    private static let ranges: [(label: String, days: Int)] = [("1W", 7), ("1M", 30), ("3M", 90), ("6M", 180), ("1Y", 365), ("All", 100_000)]

    private struct Point: Identifiable { let id: String; let date: Date; let kg: Double; let trend: Double }
    private struct Reading: Identifiable { let row: JSON; var id: String { str(row["day"]) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    top.padding(.horizontal, 18).padding(.top, 14)
                    chartCard.padding(.horizontal, 14).padding(.top, 14)
                    if store.checkInDue { checkInRow.padding(.horizontal, 14).padding(.top, 10) }
                    section("Your plan")
                    planCard.padding(.horizontal, 14)
                    section("This week")
                    weekCard.padding(.horizontal, 14)
                    smallCards.padding(.horizontal, 14).padding(.top, 10)
                    weighInsHeader
                    weighIns.padding(.horizontal, 14)
                    section("Food")
                    food.padding(.horizontal, 14)
                }
                .padding(.bottom, 110)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.sync(); await store.pullBody() }
            .sheet(isPresented: $weighing) { WeighInSheet() }
            .sheet(item: Binding(get: { editing.map { Reading(row: $0) } }, set: { editing = $0?.row })) { r in WeighInSheet(row: r.row) }
        }
    }

    // MARK: the top

    private var header: some View {
        HStack(spacing: 8) {
            Text("Progress").font(.system(size: 30, weight: .heavy))
            Spacer()
            Button { weighing = true } label: {
                Label("Weigh in", systemImage: "plus").font(.subheadline.weight(.heavy)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 9).background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private func round(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(symbol) }.buttonStyle(.plain)
    }
    private func roundLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
            .frame(width: 38, height: 38).background(Color(.tertiarySystemFill), in: Circle())
    }

    private var goal: Double? { pos(store.doc["goalWeight"]) }
    private var now: Double? { store.lastWeighIn?.kg ?? store.latestWeight?.kg }
    private var firstName: String { Friends.shared.myName.split(separator: " ").first.map(String.init) ?? "" }

    /// Three quiet lines: a word on how it's going, the weight, and how far and how long.
    private var top: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let now {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.kg(now)).font(.system(size: 48, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text("kg").font(.headline).foregroundStyle(.secondary)
                }
                Text(toGo).font(.subheadline).foregroundStyle(.primary.opacity(0.8))
            } else {
                Text("Weigh in to start").font(.title2.weight(.heavy)).padding(.top, 2)
                Text("Your trend and the date you'll reach your goal show here after a few weigh-ins.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var greeting: String {
        let who = firstName.isEmpty ? "" : ", \(firstName)"
        guard let goal, let now else { return "Your progress" }
        let left = abs(now - goal)
        if left < 0.3 { return "You made it\(who) 🎉" }
        let pace = store.weightTrend().map { $0.perDay * 7 }
        let towards = pace.map { $0 != 0 && ($0 < 0) == (goal < now) } ?? false
        if !towards { return pace == nil ? "Keep weighing in\(who)" : "Let's get back on track\(who)" }
        return left <= 1.5 ? "Nearly there\(who) 👋" : "On your way\(who)"
    }

    private var toGo: String {
        guard let goal, let now else { return "Set a goal weight in Body" }
        let left = abs(now - goal)
        if left < 0.3 { return "At your goal of \(Fmt.kg(goal)) kg" }
        var line = "\(Fmt.kg(left)) kg to go"
        if let d = store.reachDate(goal) {
            let days = max(1, Calendar.current.dateComponents([.day], from: Date(), to: d).day ?? 1)
            line += days <= 45 ? " · about \(days) day\(days == 1 ? "" : "s")" : " · around \(d.formatted(.dateTime.day().month(.abbreviated)))"
        } else if store.nearGoal(goal) { line += " · any day now" }
        return line
    }

    // MARK: the chart

    /// Weigh-ins and the smoothed trend through them, in the range picked.
    private var points: [Point] {
        let rows = store.bodyRows.compactMap { r -> (String, Double)? in
            guard let kg = pos(r[metric]), str(r["day"]) <= store.today else { return nil }
            return (str(r["day"]), kg)
        }.sorted { $0.0 < $1.0 }
        guard !rows.isEmpty else { return [] }
        let trend = rows.count >= 4 ? Trend.fit(days: rows.map(\.0), values: rows.map(\.1)).fit : rows.map(\.1)
        let since = DayKey.shift(store.today, days: -min(range, 20_000))
        return rows.indices.filter { rows[$0].0 >= since }.map { Point(id: rows[$0].0, date: DayKey.date(rows[$0].0), kg: rows[$0].1, trend: trend[$0]) }
    }

    private var chartCard: some View {
        let pts = points
        let goalLine = metric == "weight" ? goal : nil
        let vals = pts.map(\.trend) + pts.map(\.kg) + (goalLine.map { [$0] } ?? [])
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1, pad = max(0.5, (hi - lo) * 0.25)   // room above and below the line
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                let have = BodyView.metrics.filter { m in store.bodyRows.contains { pos($0[m.key]) != nil } }
                if have.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(have.prefix(4), id: \.key) { m in
                                Button { withAnimation(.easeInOut(duration: 0.25)) { metric = m.key; picked = nil } } label: {
                                    Text(m.name).font(.footnote.weight(.bold)).foregroundStyle(metric == m.key ? Theme.onAccent : .secondary)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(metric == m.key ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Text("Your weight").font(.subheadline.weight(.bold))
                }
                Spacer(minLength: 6)
                // a held day's number, or what holding does
                if let sel = selected(pts) {
                    Text("\(sel.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))  ").font(.footnote).foregroundStyle(.secondary)
                        + Text(value(sel.kg)).font(.footnote.weight(.bold))
                } else {
                    Text(pts.count >= 2 ? "Hold to see a day" : rangeName).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            if pts.count >= 2, let first = pts.first, let last = pts.last {
                // a little time either side of the weigh-ins, so the end dots aren't cut by the card; the fill carries on
                // flat to both edges, so it still runs the card's full width
                let span = last.date.timeIntervalSince(first.date), slack = max(span * 0.05, 3600 * 12)
                let x0 = first.date.addingTimeInterval(-slack), x1 = last.date.addingTimeInterval(slack)
                let fill = [Point(id: "start", date: x0, kg: first.trend, trend: first.trend)] + pts + [Point(id: "end", date: x1, kg: last.trend, trend: last.trend)]
                Chart {
                    ForEach(fill) { p in
                        AreaMark(x: .value("Day", p.date), yStart: .value("Low", lo - pad), yEnd: .value("Trend", p.trend))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.32), Theme.accent.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    }
                    ForEach(pts) { p in
                        PointMark(x: .value("Day", p.date), y: .value("Weigh-in", p.kg)).symbolSize(10).foregroundStyle(Theme.accent.opacity(0.28))
                    }
                    ForEach(pts) { p in
                        LineMark(x: .value("Day", p.date), y: .value("Trend", p.trend))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.9), Theme.accent], startPoint: .leading, endPoint: .trailing))
                    }
                    if let sel = selected(pts) {
                        RuleMark(x: .value("Held", sel.date)).foregroundStyle(.white.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Held", sel.date), y: .value("Reading", sel.kg)).symbolSize(60).foregroundStyle(Theme.accent)
                    }
                    if let goal = goalLine {
                        RuleMark(y: .value("Goal", goal)).foregroundStyle(.white.opacity(0.16)).lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .bottom, alignment: .trailing) {
                                Text("Goal \(Fmt.kg(goal)) kg").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.trailing, 12)
                            }
                    }
                    // today: a white dot with a soft halo and the number above it
                    PointMark(x: .value("Day", last.date), y: .value("Trend", last.trend)).symbolSize(420).foregroundStyle(Theme.accent.opacity(0.22))
                    // no number on it: the trend there is a touch off the scale's number in big type above, and two
                    // different weights side by side looked like a mistake
                    PointMark(x: .value("Day", last.date), y: .value("Trend", last.trend)).symbolSize(70).foregroundStyle(.white)
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: [first.date, mid(first.date, last.date), last.date]) { v in
                        // the end dates hang inwards, so "7 Nov" at the right isn't cut to "7 N"
                        let d0 = v.as(Date.self)
                        let anchor: UnitPoint = d0.map { abs($0.timeIntervalSince(last.date)) < 60 ? .topTrailing : abs($0.timeIntervalSince(first.date)) < 60 ? .topLeading : .top } ?? .top
                        AxisValueLabel(anchor: anchor) {
                            if let d = v.as(Date.self) {
                                Text(Calendar.current.isDate(d, inSameDayAs: last.date) && last.id == store.today ? "Today" : d.formatted(.dateTime.day().month(.abbreviated)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartXScale(domain: x0...x1)
                .chartPlotStyle { $0.padding(.horizontal, 0) }
                .chartXSelection(value: $picked)
                .frame(height: 170)
                // a fade from one range to the next: reshaping the line between them looked messy
                .id("\(range)|\(metric)")
                .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(pts.isEmpty ? "Weigh in a few times and your trend shows here." : "One more weigh-in and your line starts.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { weighing = true } label: { Text("Weigh in").font(.subheadline.weight(.bold)) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).foregroundStyle(Theme.onAccent)
                }
                .frame(maxWidth: .infinity).frame(height: 170)
            }
            HStack(spacing: 0) {
                ForEach(Self.ranges, id: \.days) { r in
                    Button { picked = nil; withAnimation(.easeInOut(duration: 0.25)) { range = r.days } } label: {
                        Text(r.label).font(.footnote.weight(.bold)).foregroundStyle(range == r.days ? Theme.onAccent : .secondary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(range == r.days ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear), in: Capsule())
                    }
                    .buttonStyle(.plain).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 14)
        .background(LinearGradient(colors: [Theme.accent.opacity(0.10), Color(.secondarySystemGroupedBackground)], startPoint: .top, endPoint: .center),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var rangeName: String {
        switch range { case 7: "Last week"; case 30: "Last month"; case 90: "Last 3 months"; case 180: "Last 6 months"; case 365: "Last year"; default: "Since you started" }
    }
    /// The reading nearest the day held on the chart.
    private func selected(_ pts: [Point]) -> Point? {
        guard let picked else { return nil }
        return pts.min { abs($0.date.timeIntervalSince(picked)) < abs($1.date.timeIntervalSince(picked)) }
    }
    private func value(_ v: Double) -> String {
        let unit = BodyView.metrics.first { $0.key == metric }?.unit ?? ""
        return unit == "%" ? "\(Fmt.dec(v))%" : "\(Fmt.kg(v))\(unit.isEmpty ? "" : " " + unit)"
    }

    private func mid(_ a: Date, _ b: Date) -> Date { Date(timeIntervalSince1970: (a.timeIntervalSince1970 + b.timeIntervalSince1970) / 2) }

    // MARK: the week

    private var checkInRow: some View {
        NavigationLink { CheckInView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34).background(Color(.tertiarySystemFill), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your weekly check-in").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    Text("See how the week went and your budget for the next").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The last seven days as bars against each day's budget: green on it, amber over, grey not logged.
    private var weekCard: some View {
        let dates = (0..<7).reversed().map { DayKey.shift(store.today, days: -$0) }
        let days = dates.map { (date: $0, f: store.dayFacts($0)) }
        let logged = days.filter { $0.f.logged }
        let ok = logged.filter { store.underBudget($0.f) }.count
        let avg = logged.isEmpty ? 0 : logged.reduce(0) { $0 + $1.f.kcal } / Double(logged.count)
        let top = max(1, days.map { max($0.f.kcal, $0.f.budget) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(logged.isEmpty ? "Nothing logged yet" : "\(ok) of \(logged.count) on budget").font(.subheadline.weight(.bold))
                Spacer()
                if !logged.isEmpty { Text("\(Fmt.int(avg)) a day avg").font(.footnote).foregroundStyle(.secondary) }
            }
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(days, id: \.date) { d in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(!d.f.logged ? Color(.tertiarySystemFill) : store.underBudget(d.f) ? Theme.walk : Theme.warn)
                            .frame(height: d.f.logged ? max(10, 46 * d.f.kcal / top) : 10)
                        Text(DayKey.date(d.date).formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 66, alignment: .bottom)
            Text(weekLine(days.map(\.f))).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// One plain line about the week.
    private func weekLine(_ fs: [Store.DayFacts]) -> String {
        let logged = fs.filter(\.logged)
        if logged.isEmpty { return "Log what you eat and your week shows here." }
        let over = logged.filter { !store.underBudget($0) }
        if over.isEmpty { return "Every day you logged was on budget. Lovely work." }
        let overBy = over.reduce(0) { $0 + ($1.kcal - $1.budget) } / Double(over.count)
        if over.count * 2 > logged.count { return "Most days ran over, by about \(Fmt.int(overBy)) on average. A smaller dinner is the easiest win." }
        return "\(over.count == 1 ? "One day" : "\(over.count) days") ran over, by about \(Fmt.int(overBy)) each. The rest were on budget."
    }

    private var smallCards: some View {
        let dates = (1...30).map { DayKey.shift(store.today, days: -$0) }
        let logged = dates.map(store.dayFacts).filter(\.logged)
        let hit = store.proteinGoal.map { g in logged.filter { $0.p >= g * 0.9 }.count } ?? 0
        let pct = logged.isEmpty ? 0 : Int((Double(hit) / Double(logged.count) * 100).rounded())
        return HStack(spacing: 10) {
            small(title: "Protein", value: store.proteinGoal == nil ? "–" : "\(pct)", unit: store.proteinGoal == nil ? "" : "%",
                  note: store.proteinGoal == nil ? "No goal set" : "of days hit", icon: nil)
            small(title: "Streak", value: "\(store.streakInfo.days)", unit: "", note: "days logged", icon: "🔥")
        }
    }

    private func small(title: String, value: String, unit: String, note: String, icon: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let icon { FluentIcon(emoji: icon, size: 20) }
                Text(value).font(.title3.weight(.heavy)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: your plan, weigh-ins and food

    private func section(_ t: String) -> some View {
        Text(t).font(.headline.weight(.heavy)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 8)
    }

    /// The budget a day and the cheat day, which set everything else: tap to change them.
    private var planCard: some View {
        let base = pos(store.doc["budget"]) ?? store.baseBudget(store.today)
        let cheat = store.cheatWeekday.map { Calendar.current.weekdaySymbols[$0] } ?? "None"
        return NavigationLink { BudgetView() } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Budget").font(.footnote).foregroundStyle(.secondary)
                    (Text(Fmt.int(base)).font(.title3.weight(.heavy)) + Text(" a day").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                Divider().frame(height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cheat day").font(.footnote).foregroundStyle(.secondary)
                    Text(cheat).font(.title3.weight(.heavy)).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary).padding(.trailing, 14)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your plan: \(Fmt.int(base)) a day, cheat day \(cheat)")
    }

    private var weighInsHeader: some View {
        HStack {
            Text("Weigh-ins").font(.headline.weight(.heavy)).foregroundStyle(.secondary)
            Spacer()
            NavigationLink { BodyView() } label: { Text("See all").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 8)
    }

    /// The last three readings; tap one to change it. Everything else about your body (every reading, the scale) is
    /// behind See all.
    private var weighIns: some View {
        let recent = Array(store.bodyRows.filter { pos($0["weight"]) != nil }.sorted { str($0["day"]) > str($1["day"]) }.prefix(3))
        return VStack(spacing: 0) {
            if recent.isEmpty {
                Button { weighing = true } label: {
                    HStack { Text("No weigh-ins yet").foregroundStyle(.secondary); Spacer(); Text("Weigh in").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent) }
                        .padding(14)
                }
                .buttonStyle(.plain)
            }
            ForEach(recent.indices, id: \.self) { i in
                let r = recent[i]
                Button { editing = r } label: {
                    HStack {
                        Text(DayKey.date(str(r["day"])).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Spacer()
                        Text(([pos(r["weight"]).map { "\(Fmt.kg($0)) kg" }, pos(r["fat"]).map { "\(Fmt.dec($0))%" }].compactMap { $0 }).joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < recent.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var food: some View {
        let meals = CheatDays.list(store.doc["meals"]).count
        let changes = store.habitItems.filter { $0.plan != nil }.count
        var rows: [(icon: String, title: String, value: String, to: AnyView)] = [
            ("book.closed.fill", "Meals", meals == 0 ? "" : "\(meals) saved", AnyView(MealsView())),
            ("checkmark", "Food habits", changes == 0 ? "" : "\(changes) change\(changes == 1 ? "" : "s")", AnyView(HabitsView())),
            ("clock.arrow.circlepath", "History", "", AnyView(HistoryView())),
        ]
        if store.isHelper { rows.append(("person.2.fill", "Family", "", AnyView(FamilyView()))) }
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                NavigationLink { r.to } label: {
                    HStack(spacing: 12) {
                        Image(systemName: r.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Color(.tertiarySystemFill), in: Circle())
                        Text(r.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        if !r.value.isEmpty { Text(r.value).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < rows.count - 1 { Divider().padding(.leading, 60) }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
