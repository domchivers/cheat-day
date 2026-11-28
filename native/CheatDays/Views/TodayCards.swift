import SwiftUI

/// The cheat day's card at the top of Today (21 Nov, design/today-cards-mockup.html, 1): what there is to play with
/// and how much more that is than a normal day, saved meals that fit it, and a button to plan it; once planned, the
/// plan. ✕ hides it for the day.
struct CheatDayCard: View {
    var open: () -> Void
    var hide: () -> Void
    private var store: Store { Store.shared }

    /// Saved meals that fit in what's left, a portion each: at most three.
    private var ideas: [(name: String, kcal: Double)] {
        let left = max(0, store.budgetToday - store.eaten)
        return list(store.doc["meals"]).compactMap { m -> (name: String, kcal: Double)? in
            guard m["saved"] as? Bool == true, !str(m["name"]).isEmpty, let k = pos(store.mealBasis(m)["kcalPerServing"]), k <= left else { return nil }
            return (str(m["name"]), k)
        }
        .prefix(3).map { $0 }
    }

    var body: some View {
        let plan = store.cheatPlan(store.today), slots = list(plan?["slots"])
        let left = max(0, store.budgetToday - store.eaten)
        let free = max(0, store.budgetToday - CheatPlan.total(slots: slots, logged: store.todayItems))
        let normal = pos(store.doc["budget"]) ?? 0, extra = store.budgetToday - normal
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("CHEAT DAY · \(DayKey.date(store.today).formatted(.dateTime.weekday(.wide)).uppercased())")
                    .font(.caption.weight(.heavy)).tracking(1).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button(action: hide) { Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.white.opacity(0.75)) }
                    .buttonStyle(.borderless).accessibilityLabel("Hide for today")
            }
            if plan == nil {
                (Text(Fmt.int(left)).font(.system(size: 30, weight: .black, design: .rounded))
                 + Text(store.eaten > 0 ? "  kcal left" : "  kcal to play with").font(.subheadline.weight(.bold)).foregroundColor(.white.opacity(0.8)))
                    .foregroundStyle(.white).monospacedDigit().padding(.top, 4)
                if extra > 50, store.eaten == 0 {
                    Text("That's \(Fmt.int(extra)) more than a normal day. Plan it, then enjoy it.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.85)).padding(.top, 2)
                }
                let fits = ideas
                if !fits.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(fits.indices, id: \.self) { i in
                                Button(action: open) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(fits[i].name).font(.caption.weight(.bold)).lineLimit(1)
                                        Text("\(Fmt.int(fits[i].kcal)) kcal").font(.caption2.weight(.semibold)).opacity(0.75)
                                    }
                                    .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
            } else {
                Text("Your cheat day plan").font(.title3.weight(.heavy)).foregroundStyle(.white).padding(.top, 4)
                Text("\(slots.count) \(slots.count == 1 ? "meal" : "meals") planned · \(Fmt.int(free)) kcal free")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).padding(.top, 2)
            }
            Button(action: open) {
                Text(plan == nil ? "Plan my cheat day" : "See my plan").font(.subheadline.weight(.heavy))
                    .foregroundStyle(Color(red: 0.18, green: 0.12, blue: 0.43))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain).padding(.top, 12)
        }
        .padding(.vertical, 6)
    }

    /// The card's own colours, the app's cheat-day gradient deepened so white reads on it.
    static let background = LinearGradient(colors: [Color(red: 0.23, green: 0.18, blue: 0.56), Color(red: 0.42, green: 0.25, blue: 0.66),
                                                    Color(red: 0.66, green: 0.34, blue: 0.61)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// After a weigh-in (21 Nov, design/today-cards-mockup.html, 3): the number, how it moved since the last one, a little
/// line of the recent ones, what it means (the check-in's own sums: the weekly check-in, not one reading, changes the
/// budget), body fat and lean mass when the scale sent them, and the way to the goal weight. Shown on the day of the
/// weigh-in; ✕ hides it.
struct WeighInCard: View {
    var hide: () -> Void
    /// The weekly check-in opened, to use its new budget now.
    var review: () -> Void = {}
    private var store: Store { Store.shared }

    /// Today's weigh-in, if there is one.
    static var today: JSON? {
        let s = Store.shared
        return s.bodyRows.last { pos($0["weight"]) != nil && str($0["day"]) == s.today }
    }

    var body: some View {
        let row = Self.today ?? [:]
        let kg = pos(row["weight"]) ?? 0
        let before = store.bodyRows.last { pos($0["weight"]) != nil && str($0["day"]) < store.today }
        let change = before.flatMap { pos($0["weight"]) }.map { kg - $0 }
        let recent = store.bodyRows.compactMap { pos($0["weight"]) }.suffix(8).map { $0 }
        let at = ISO.date(str(row["takenAt"]).isEmpty ? str(row["updatedAt"]) : str(row["takenAt"]))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("✓ WEIGHED IN" + (at.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                    .font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(Theme.walk)
                Spacer()
                if let change, abs(change) >= 0.05 {
                    Text("\(change > 0 ? "+" : "−")\(Fmt.one(abs(change))) kg").font(.caption.weight(.heavy)).monospacedDigit()
                        .foregroundStyle(Theme.walk).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.walk.opacity(0.14), in: Capsule())
                }
                Button(action: hide) { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).accessibilityLabel("Hide for today")
            }
            (Text(Fmt.kg(kg)).font(.system(size: 32, weight: .black, design: .rounded))
             + Text("  kg").font(.subheadline.weight(.bold)).foregroundColor(.secondary)).monospacedDigit()
            if recent.count >= 3 { Spark(values: recent).frame(height: 40) }
            Text(meaning(change: change, before: before)).font(.footnote).fixedSize(horizontal: false, vertical: true)
            let a = advice
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title).font(.subheadline.weight(.bold))
                Text((spike != nil && !a.change ? "Today's reading looks like water, so it won't change your budget. " : "") + a.text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if a.change {
                    Button(action: review) { Text("Review the new budget ›").font(.footnote.weight(.semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.accent).padding(.top, 2)
                }
                paceLine
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            goalBar(kg)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// The pace the check-in aims for, and Change (28 Nov, design/goal-pace-mockup.png): with a goal weight but no plan
    /// it had nothing to aim for and never moved the budget.
    @ViewBuilder private var paceLine: some View {
        if let want = store.paceWant, let goal = pos(store.doc["goalWeight"]) {
            let said: String = abs(want) < 0.01 ? "Holding your weight" : "Aiming for \(Fmt.kg(abs(want))) kg a week to \(Fmt.one(goal)) kg"
            Divider().padding(.vertical, 4)
            HStack {
                Text(said).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Section("How fast to \(Fmt.one(goal)) kg?") {
                        ForEach(Self.paces(gaining: goal > (store.latestWeight?.kg ?? goal)), id: \.kg) { p in
                            Button { store.setGoalPace(p.kg) } label: {
                                if abs(p.kg - want) < 0.01 { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                            }
                        }
                    }
                } label: { Text("Change").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
            }
        }
    }

    static func paces(gaining: Bool) -> [(name: String, kg: Double)] {
        let s: Double = gaining ? 1 : -1
        return [("0.25 kg a week", 0.25 * s), ("0.5 kg a week", 0.5 * s), ("0.75 kg a week", 0.75 * s), ("Hold my weight", 0)]
    }

    /// How far today's reading sits off the trend of the readings before it, when that's more than a water swing
    /// (0.8 kg): salt, carbs or a late meal, not fat (28 Nov: a kilo up after salted popcorn read like a real gain).
    private var spike: Double? {
        guard let kg = pos(Self.today?["weight"]), let r = store.checkIn.rate else { return nil }
        let prior = r.used.filter { $0.day < store.today }
        guard prior.count >= 3, let first = prior.first, let fit = Adaptive.line(prior) else { return nil }
        let x = (DayKey.date(store.today).timeIntervalSince1970 - DayKey.date(first.day).timeIntervalSince1970) / 86400
        let off = kg - (fit.intercept + fit.slope * x)
        return abs(off) > Adaptive.swingKg ? off : nil
    }

    /// What the reading means, in a line or two: against the last one and the trend, then what Monday's check-in is
    /// likely to do (the check-in's own step, worked out the same way it will be).
    private func meaning(change: Double?, before: JSON?) -> String {
        var s = ""
        if let change, let b = before {
            let when = Store.when(str(b["day"]))
            s = abs(change) < 0.05 ? "The same as \(when)" : "\(change < 0 ? "Down" : "Up") \(Fmt.one(abs(change))) kg on \(when)"
        } else { s = "Your first weigh-in" }
        let c = store.checkIn
        if let off = spike {
            s += ", but that's a spike: \(Fmt.one(abs(off))) kg \(off > 0 ? "over" : "under") your trend, most likely water"
                + (off > 0 ? " (salt, carbs, a late snack)" : "") + ". It should settle in a day or two."
            if let pace = c.pace { s += abs(pace) < 0.05 ? " Your trend is still steady." : " Your trend is still \(pace > 0 ? "+" : "−")\(Fmt.one(abs(pace))) kg a week." }
        } else if let pace = c.pace {
            s += abs(pace) < 0.05 ? ", and your trend is steady." : ", and your trend is \(pace > 0 ? "+" : "−")\(Fmt.one(abs(pace))) kg a week."
        } else { s += "." }
        let row = Self.today ?? [:]
        var parts: [String] = []
        if let f = pos(row["fat"]) { parts.append("body fat \(Fmt.one(f))%") }
        if let l = pos(row["lean"]) { parts.append("lean mass \(Fmt.one(l)) kg") }
        if !parts.isEmpty {
            let said = parts.joined(separator: ", ")
            s += " " + said.prefix(1).uppercased() + String(said.dropFirst()) + "."
        }
        return s
    }

    /// What to do about the budget, every time (21 Nov: "doesn't give any advice whether to adjust calories or stay"):
    /// the check-in's own call, worked out as Monday's will be. One reading never changes it; the trend does.
    private var advice: (title: String, text: String, change: Bool) {
        let c = store.checkIn
        if let step = c.step {
            let more = step > 0
            return ("\(more ? "Eat a little more" : "Eat a little less"): \(more ? "+" : "−")\(Fmt.int(abs(step))) kcal a day",
                    c.verdict.isEmpty ? "Your trend has been off your plan for a while." : c.verdict, true)
        }
        if let pace = c.pace, let want = c.want, !Adaptive.off(pace, want: want, tol: c.tol ?? 0.12) {
            return ("Stay on your budget", "You're on track for your plan. Nothing to change.", false)
        }
        if c.pace != nil, !c.verdict.isEmpty {
            return ("Stay on your budget for now", c.verdict, false)
        }
        return ("Stay on your budget for now", "A few more weigh-ins and logged days, and the check-in can tell whether your budget should change.", false)
    }

    @ViewBuilder private func goalBar(_ kg: Double) -> some View {
        if let goal = pos(store.doc["goalWeight"]), let start = pos(dict(store.doc["goalStart"])["weight"]), abs(start - goal) > 0.2 {
            let done = min(1, max(0, (start - kg) / (start - goal)))
            VStack(spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(LinearGradient(colors: [Theme.accent, CheatDayView.tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, g.size.width * done))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("Start \(Fmt.one(start))"); Spacer()
                    Text("\(Int((done * 100).rounded()))% to \(Fmt.one(goal)) kg"); Spacer()
                    Text("Goal \(Fmt.one(goal))")
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.top, 4)
        }
    }
}

/// A little line through some values, the last one dotted.
private struct Spark: View {
    let values: [Double]
    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return }
            let span = max(hi - lo, 0.3)
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: 4 + (size.height - 8) * CGFloat(1 - (values[i] - lo) / span))
            }
            var p = Path(); p.move(to: pt(0))
            for i in 1..<values.count { p.addLine(to: pt(i)) }
            ctx.stroke(p, with: .color(Theme.walk), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            let e = pt(values.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 4, y: e.y - 4, width: 8, height: 8)), with: .color(Theme.walk))
        }
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }
}
