import SwiftUI

/// Goals and badges: this week's goals (set your own targets), your streaks, your rank, and every achievement with progress.
struct GoalsView: View {
    @State private var shown: Badge?
    @State private var ranks = false
    private var store: Store { Store.shared }

    var body: some View {
        let prog = store.weekProgress, goals = store.weekGoals, stats = store.badgeStats, seen = store.seenBadges
        let si = store.streakInfo
        let daysLeft = 7 - store.weekDates.count
        List {
            Section {
                ForEach(Store.weekGoalDefs.filter { $0.key != "protein" || store.proteinGoal != nil }, id: \.key) { g in
                    let target = goals[g.key] ?? 0, now = prog[g.key] ?? 0
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: g.symbol).foregroundStyle(Theme.accent).frame(width: 24)
                            Text(g.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            if target > 0 && now >= target { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                            Text(target > 0 ? "\(now) / \(target)" : "Off").font(.subheadline.weight(.heavy)).monospacedDigit()
                                .foregroundStyle(target > 0 && now >= target ? Color.green : .primary)
                        }
                        if target > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.track)
                                    Capsule().fill(now >= target ? Color.green : Theme.accent).frame(width: geo.size.width * min(1, Double(now) / Double(target)))
                                }
                            }
                            .frame(height: 7)
                        }
                        Stepper("Target: \(target == 0 ? "off" : "\(target)")", value: Binding(get: { target }, set: { setGoal(g.key, $0) }), in: 0...g.max)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: { Text("This week") } footer: {
                Text("\(daysLeft == 0 ? "Last day of the week." : "\(daysLeft) day\(daysLeft == 1 ? "" : "s") left.") Each goal you finish is worth \(XPRules.goal) XP.")
            }
            Section {
                HStack(spacing: 0) {
                    streak("\(si.days)", "days logged in a row", "flame.fill", .orange)
                    Divider()
                    streak("\(store.underStreak)", "days under budget", "target", .green)
                }
                .frame(maxWidth: .infinity)
                if !si.rests.isEmpty { Text("One missed day a week is a free rest day, so it doesn't break your streak.").font(.caption).foregroundStyle(.secondary) }
                Button { ranks = true } label: {
                    HStack(spacing: 12) {
                        RankBadge(rank: store.rank, size: 40)
                        VStack(alignment: .leading, spacing: 1) { Text(store.rank.name).font(.headline); Text("\(Fmt.int(Double(store.totalXP))) XP").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            let earned = Badge.all.filter { seen.contains($0.id) || $0.earned(stats) }.count
            ForEach(Badge.groups, id: \.self) { group in
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                        ForEach(Badge.all.filter { $0.group == group }) { b in
                            let got = seen.contains(b.id) || b.earned(stats)
                            Button { shown = b } label: {
                                VStack(spacing: 5) {
                                    Text(b.icon).font(.system(size: 30))
                                        .frame(width: 58, height: 58)
                                        .background(got ? Theme.hero : Color(.tertiarySystemFill), in: Circle())
                                        .overlay(Circle().stroke(got ? Theme.warn.opacity(0.8) : .clear, lineWidth: 2))
                                        .grayscale(got ? 0 : 1).opacity(got ? 1 : 0.45)
                                    Text(b.name).font(.caption2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(got ? .primary : .secondary)
                                    if !got && b.target > 1 {
                                        Text("\(Fmt.int(min(stats[b.stat] ?? 0, b.target)))/\(Fmt.int(b.target))").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                } header: { Text(group == Badge.groups.first ? "Badges · \(earned) of \(Badge.all.count) · \(group)" : group) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Goals and badges")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.checkBadges() }
        .sheet(item: $shown) { b in badgeSheet(b, stats: stats, got: seen.contains(b.id) || b.earned(stats)).presentationDetents([.height(320)]) }
        .sheet(isPresented: $ranks) { RanksView() }
    }

    private func streak(_ n: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Label(n, systemImage: symbol).font(.title2.weight(.heavy)).foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private func badgeSheet(_ b: Badge, stats: [String: Double], got: Bool) -> some View {
        VStack(spacing: 12) {
            Text(b.icon).font(.system(size: 64)).grayscale(got ? 0 : 1).padding(.top, 24)
            Text(b.name).font(.title2.bold())
            Text(b.how).foregroundStyle(.secondary)
            if got { Label("Earned · +\(b.xp) XP", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green) }
            else if b.target > 1 {
                let now = min(stats[b.stat] ?? 0, b.target)
                ProgressView(value: now, total: b.target).tint(Theme.accent).padding(.horizontal, 40)
                Text("\(Fmt.int(now)) of \(Fmt.int(b.target)) · worth \(b.xp) XP").font(.subheadline).foregroundStyle(.secondary)
            } else { Text("Worth \(b.xp) XP").font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }

    private func setGoal(_ key: String, _ value: Int) {
        var g = store.weekGoals; g[key] = value
        store.perform(["type": "set", "key": "weekGoals", "value": g as JSON], syncAfter: 2)
    }
}
