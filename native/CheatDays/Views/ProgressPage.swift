import Charts
import SwiftUI

private extension VerticalAlignment {
    /// The middle of the big number at the top of Progress: the round + sits level with it.
    private enum NumberCentre: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] } }
    static let numberCentre = VerticalAlignment(NumberCentre.self)
}

/// The Progress tab, laid out like Friends: the big title and round buttons, a quiet line on how you're doing, your
/// weight on one clean chart across the card, the week as bars, protein and streak, then everything else in a list.
struct ProgressPage: View {
    @State private var range = 30
    @State private var weighing = false
    @State private var metric = "weight"
    @State private var picked: Date?   // a day held on the chart
    @State private var editing: JSON?   // a reading being changed
    @State private var weekDay: String?   // a day tapped in This week
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
                    HStack(alignment: .firstTextBaseline) {
                        section("Your plan")
                        Spacer()
                        NavigationLink { BudgetView() } label: { Text("Change").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent) }.padding(.trailing, 18)
                    }
                    planCard.padding(.horizontal, 14)
                    weekHeader
                    weekCard.padding(.horizontal, 14)
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
        HStack(alignment: .numberCentre, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
            if let sel = selected(points) {
                // a day held on the chart takes over the three lines: its date, its number, and how it compares with now
                let unit = BodyView.metrics.first { $0.key == metric }?.unit ?? ""
                Text(sel.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(unit == "%" ? Fmt.dec(sel.kg) : Fmt.kg(sel.kg)).font(.system(size: 48, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text(unit).font(.headline).foregroundStyle(.secondary)
                }
                .alignmentGuide(.numberCentre) { $0[VerticalAlignment.center] }
                Text(heldLine(sel)).font(.subheadline).foregroundStyle(.primary.opacity(0.8))
            } else if metric != "weight", let m = BodyView.metrics.first(where: { $0.key == metric }),
                      let last = store.bodyRows.filter({ pos($0[metric]) != nil && str($0["day"]) <= store.today }).max(by: { str($0["day"]) < str($1["day"]) }),
                      let v = pos(last[metric]) {
                // another measure picked on the chart: the top is that measure's latest reading, not the weight
                Text(m.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(m.unit == "%" ? Fmt.dec(v) : Fmt.kg(v)).font(.system(size: 48, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text(m.unit).font(.headline).foregroundStyle(.secondary)
                }
                .alignmentGuide(.numberCentre) { $0[VerticalAlignment.center] }
                Text("Latest reading · \(DayKey.date(str(last["day"])).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))").font(.subheadline).foregroundStyle(.primary.opacity(0.8))
            } else if let now {
                Text(greeting).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.kg(now)).font(.system(size: 48, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text("kg").font(.headline).foregroundStyle(.secondary)
                }
                .alignmentGuide(.numberCentre) { $0[VerticalAlignment.center] }
                Text(toGo).font(.subheadline).foregroundStyle(.primary.opacity(0.8))
            } else {
                Text(greeting).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("Weigh in to start").font(.title2.weight(.heavy)).padding(.top, 2)
                Text("Your trend and the date you'll reach your goal show here after a few weigh-ins.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 0)
        // level with the number it adds to, round like the buttons on Friends
        round("plus") { weighing = true }.accessibilityLabel("Weigh in")
        }
    }

    /// Under a held day's number: how far it is from the latest reading of the same measure.
    private func heldLine(_ sel: Point) -> String {
        let m = BodyView.metrics.first { $0.key == metric }
        guard let last = points.last, last.id != sel.id else { return metric == "weight" ? "Your latest weigh-in" : (m?.name ?? "") }
        let d = sel.kg - last.kg, unit = m?.unit ?? ""
        if abs(d) < 0.05 { return "Same as now" }
        let amount = unit == "%" ? "\(Fmt.dec(abs(d)))%" : "\(Fmt.kg(abs(d)))\(unit.isEmpty ? "" : " " + unit)"
        return "\(amount) \(d > 0 ? "more" : "less") than now"
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
                                    Text(m.name).font(.footnote.weight(.bold)).foregroundStyle(metric == m.key ? .primary : .secondary)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(metric == m.key ? AnyShapeStyle(Color(.systemGray3)) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    // the chips have the row to themselves (a held day shows in the big number above); without them, a hint
                    Text("Your weight").font(.subheadline.weight(.bold))
                    Spacer(minLength: 6)
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
                        Text(r.label).font(.footnote.weight(.bold)).foregroundStyle(range == r.days ? .primary : .secondary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(range == r.days ? AnyShapeStyle(Color(.systemGray3)) : AnyShapeStyle(Color.clear), in: Capsule())
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

    private var weekDays: [(date: String, f: Store.DayFacts)] {
        (0..<7).reversed().map { DayKey.shift(store.today, days: -$0) }.map { (date: $0, f: store.dayFacts($0)) }
    }

    /// "This week" with the average a day beside it.
    private var weekHeader: some View {
        let logged = weekDays.map(\.f).filter(\.logged)
        let avg = logged.isEmpty ? 0 : logged.reduce(0) { $0 + $1.kcal } / Double(logged.count)
        return HStack(alignment: .firstTextBaseline) {
            section("This week")
            Spacer()
            if !logged.isEmpty { Text("\(Fmt.int(avg)) a day avg").font(.footnote).foregroundStyle(.secondary).monospacedDigit().padding(.trailing, 18) }
        }
    }

    /// The last seven days as bars against each day's budget (green on it, amber over, grey not logged) with the
    /// calories on top; tap one for that day; then on budget, protein and the streak in a row.
    private var weekCard: some View {
        let days = weekDays
        let top = max(1, days.map { max($0.f.kcal, $0.f.budget) }.max() ?? 1)
        return VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days, id: \.date) { d in weekBar(d.date, d.f, top: top) }
            }
            .frame(height: 104, alignment: .bottom)
            if let day = weekDay, let d = days.first(where: { $0.date == day }) {
                Divider().padding(.top, 12)
                weekDetail(d.date, d.f).padding(.top, 12)
            }
            Divider().padding(.top, 12)
            weekFigures(days.map(\.f)).padding(.top, 12)
        }
        .padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func weekBar(_ date: String, _ f: Store.DayFacts, top: Double) -> some View {
        let on = weekDay == date
        let fill: Color = !f.logged ? Color(.tertiarySystemFill) : store.underBudget(f) ? Theme.walk : Theme.warn
        return Button { withAnimation(.snappy) { weekDay = on ? nil : date } } label: {
            VStack(spacing: 5) {
                Spacer(minLength: 0)
                Text(f.logged ? Fmt.int(f.kcal) : " ").font(.system(size: 10.5, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(on ? .primary : .secondary)
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
                    .frame(height: f.logged ? max(12, 62 * f.kcal / top) : 12)
                    .opacity(weekDay == nil || on ? 1 : 0.35)
                Text(DayKey.date(date).formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(.semibold)).foregroundStyle(on ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(DayKey.date(date).formatted(.dateTime.weekday(.wide))), \(f.logged ? "\(Fmt.int(f.kcal)) of \(Fmt.int(f.budget))" : "nothing logged")")
    }

    /// The tapped day: what was eaten against its budget, the protein, and a way in to the day itself.
    private func weekDetail(_ date: String, _ f: Store.DayFacts) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                (Text(date == store.today ? "Today" : DayKey.date(date).formatted(.dateTime.weekday(.wide))).font(.body.weight(.semibold))
                 + Text(store.isCheatDay(date) ? " · cheat day" : "").font(.footnote).foregroundStyle(.secondary))
                Text(f.logged ? "\(Fmt.int(f.kcal)) of \(Fmt.int(f.budget)) kcal · \(Fmt.int(f.p)) g protein" : "Nothing logged")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if date == store.today {
                Button { NotificationCenter.default.post(name: .openTab, object: 0) } label: { openDayLabel }.buttonStyle(.plain)
            } else if f.logged {
                NavigationLink { HistoryView(start: date) } label: { openDayLabel }
            }
        }
    }
    private var openDayLabel: some View {
        HStack(spacing: 3) { Text("Open day"); Image(systemName: "chevron.right").font(.caption2.weight(.bold)) }.font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
    }

    /// On budget this week, protein over the last 30 days, and the streak.
    private func weekFigures(_ fs: [Store.DayFacts]) -> some View {
        let logged = fs.filter(\.logged), ok = logged.filter { store.underBudget($0) }.count
        let month = (1...30).map { store.dayFacts(DayKey.shift(store.today, days: -$0)) }.filter(\.logged)
        let hit = store.proteinGoal.map { g in month.filter { $0.p >= g * 0.9 }.count } ?? 0
        let pct = month.isEmpty ? 0 : Int((Double(hit) / Double(month.count) * 100).rounded())
        return HStack(spacing: 0) {
            figure(logged.isEmpty ? "–" : "\(ok)", unit: logged.isEmpty ? "" : "of \(logged.count)", note: "on budget", icon: nil)
            Divider().frame(height: 34)
            figure(store.proteinGoal == nil ? "–" : "\(pct)%", unit: "", note: store.proteinGoal == nil ? "no protein goal" : "protein days", icon: nil)
            Divider().frame(height: 34)
            figure("\(store.streakInfo.days)", unit: "", note: "day streak", icon: "🔥")
        }
    }

    private func figure(_ value: String, unit: String, note: String, icon: String?) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let icon { FluentIcon(emoji: icon, size: 18) }
                Text(value).font(.title3.weight(.heavy)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                VStack(spacing: 3) {
                    Text("Budget").font(.footnote).foregroundStyle(.secondary)
                    (Text(Fmt.int(base)).font(.title3.weight(.heavy)) + Text(" a day").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity).padding(14)
                Divider().frame(height: 40)
                VStack(spacing: 3) {
                    Text("Cheat day").font(.footnote).foregroundStyle(.secondary)
                    Text(cheat).font(.title3.weight(.heavy)).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity).padding(14)
            }
            .overlay(alignment: .trailing) { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary).padding(.trailing, 12) }
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
                        Text(([pos(r["weight"]).map { "\(Fmt.kgRow($0)) kg" }, pos(r["fat"]).map { "\(Fmt.dec($0))%" }].compactMap { $0 }).joined(separator: " · "))
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
