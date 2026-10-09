import SwiftUI

/// The weekly check-in: last week, what you really burn, how you're doing against your goal, and a budget to use or keep.
struct CheckInView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    var body: some View {
        let c = store.checkIn
        List {
            Section {
                fact("Ate on average", c.avg.map { "\(Fmt.int($0)) kcal a day" } ?? "nothing logged")
                fact("Days logged", "\(c.logged) of 7")
                fact("Weight trend", change(c.change))
                fact("Workouts", "\(c.workouts)")
            } header: { Text("Last week · \(range(c))") }
            Section {
                if let burn = c.burn {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "You burn about", color: Theme.heroLabel)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Fmt.int(burn)).font(.system(size: 40, weight: .heavy, design: .rounded))
                            Text("kcal a day").foregroundStyle(.secondary)
                        }
                        Text("Worked out from \(c.burnDays) days of food and \(c.burnWeighins) weigh-ins.\(pos(dict(store.doc["plan"])["tdee"]).map { " Your plan guessed \(Fmt.int($0))." } ?? "")")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What you really burn").font(.headline)
                        Text("Not enough to tell yet. It needs \(c.needs.joined(separator: " and ")).").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            if let want = c.want {
                Section("Your goal: \(goal(want))") {
                    fact("Last week", change(c.change))
                    fact("Last 4 weeks", c.pace.map { abs($0) < 0.05 ? "steady" : "\($0 < 0 ? "down" : "up") \(String(format: "%.2f", abs($0))) kg a week" } ?? "not enough weigh-ins")
                    if let s = status(c) { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            if let s = c.suggest, Int(s) != Int(c.now.rounded()) {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Suggested budget", color: Theme.heroLabel)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Fmt.int(s)).font(.system(size: 40, weight: .heavy, design: .rounded))
                            Text("now \(Fmt.int(c.now))").foregroundStyle(.secondary)
                        }
                        Text(s > c.now ? "A little more food, and still on pace for your goal." : "A little less food, to match the pace you chose.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button { store.finishCheckIn(c, use: true); dismiss() } label: { Text("Use \(Fmt.int(s))").font(.headline).frame(maxWidth: .infinity) }
                    Button { store.finishCheckIn(c, use: false); dismiss() } label: { Text("Keep \(Fmt.int(c.now))").frame(maxWidth: .infinity) }
                }
            } else {
                Section {
                    Button { store.finishCheckIn(c, use: false); dismiss() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity) }
                } footer: {
                    Text(c.want == nil ? "Set a goal under Plan and budget, and the check-in works out the calories that get you there."
                                       : "Nothing changes unless you choose it. The burn gets better the more you log and weigh in.")
                }
            }
        }
        .navigationTitle("Weekly check-in")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).fontWeight(.semibold) }
    }
    private func change(_ c: Double?) -> String {
        guard let c else { return "not enough weigh-ins" }
        return abs(c) < 0.05 ? "steady" : "\(c < 0 ? "down" : "up") \(String(format: "%.1f", abs(c))) kg"
    }
    private func goal(_ w: Double) -> String { w < 0 ? "lose \(String(format: "%.2f", -w)) kg a week" : w > 0 ? "gain \(String(format: "%.2f", w)) kg a week" : "hold steady" }
    private func range(_ c: CheckIn) -> String {
        let f = { (d: String) in DayKey.date(d).formatted(.dateTime.day().month(.abbreviated)) }
        return "\(f(c.mon)) to \(f(c.sun))"
    }
    private func status(_ c: CheckIn) -> String? {
        guard let want = c.want, let pace = c.pace else { return nil }
        let gap = pace - want
        if abs(gap) < 0.15 { return "You're on track." }
        if want == 0 { return gap > 0 ? "Drifting up a little." : "Drifting down a little." }
        return (want < 0 ? gap < 0 : gap > 0) ? "A little faster than planned." : "A little slower than planned."
    }
}
