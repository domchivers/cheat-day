import SwiftUI

/// Goals and badges, at a glance: this week's four goals as tiles (their targets behind Change targets), the streak and
/// the rank with how close the next one is, the badges nearest to earning and the latest ones, and every badge a tap
/// away. Badges are the food icons' Fluent art, in colour once earned and grey until then (the phone's own emoji, and
/// the − + on every goal, didn't fit the rest of the app).
struct GoalsView: View {
    @State private var shown: Badge?
    @State private var ranks = false
    @State private var targets = false
    private var store: Store { Store.shared }

    var body: some View {
        let prog = store.weekProgress, goals = store.weekGoals, stats = store.badgeStats, seen = store.seenBadges
        let daysLeft = 7 - store.weekDates.count
        let defs = Store.weekGoalDefs.filter { $0.key != "protein" || store.proteinGoal != nil }
        List {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(defs, id: \.key) { g in tile(g, now: prog[g.key] ?? 0, target: goals[g.key] ?? 0) }
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } header: {
                HStack {
                    Text(daysLeft == 0 ? "This week · last day" : "This week · \(daysLeft) day\(daysLeft == 1 ? "" : "s") left")
                    Spacer()
                    Button("Change targets") { targets = true }.font(.footnote).textCase(nil)
                }
            } footer: { Text("Each goal you finish is worth \(XPRules.goal) XP.") }

            Section {
                let si = store.streakInfo
                HStack(spacing: 13) {
                    FluentIcon(emoji: "🔥", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(si.days) day\(si.days == 1 ? "" : "s") in a row").font(.body.weight(.semibold))
                        Text("One missed day a week doesn't break it").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                Button { ranks = true } label: { rankRow }.buttonStyle(.plain)
            } header: { Text("Streak and rank") }

            let next = nextBadges(stats: stats, seen: seen)
            if !next.isEmpty {
                Section {
                    ForEach(next, id: \.badge.id) { n in
                        Button { shown = n.badge } label: {
                            HStack(spacing: 13) {
                                BadgeCoin(badge: n.badge, size: 46, got: false, progress: n.now / n.badge.target)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(n.badge.name).font(.body.weight(.semibold))
                                    Text("\(n.badge.how) · \(Fmt.int(max(0, n.badge.target - n.now))) left").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("Next badges") }
            }

            // the newest ones they've earned (seenBadges keeps the order they came in), and the way to all of them
            let recent = Array(((store.doc["seenBadges"] as? [String]) ?? []).reversed().compactMap { id in Badge.all.first { $0.id == id } }.prefix(4))
            Section {
                if !recent.isEmpty {
                    HStack(alignment: .top) {
                        ForEach(recent) { b in
                            Button { shown = b } label: { badgeCell(b, got: true) }.buttonStyle(.plain).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 6)
                }
                NavigationLink {
                    AllBadgesView(shown: $shown)
                } label: {
                    let earned = Badge.all.filter { seen.contains($0.id) || $0.earned(stats) }.count
                    Text("All badges · \(earned) of \(Badge.all.count)").font(.body.weight(.semibold))
                }
            } header: { Text(recent.isEmpty ? "Badges" : "Recently earned") }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Goals and badges")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.checkBadges() }
        .sheet(item: $shown) { b in BadgeSheet(badge: b, stats: stats, got: seen.contains(b.id) || b.earned(stats)).presentationDetents([.height(360)]) }
        .sheet(isPresented: $ranks) { RanksView() }
        .sheet(isPresented: $targets) { targetsSheet(defs).presentationDetents([.medium]) }
    }

    /// One goal: its icon, how far this week, a bar, and its name.
    private func tile(_ g: WeekGoal, now: Int, target: Int) -> some View {
        let done = target > 0 && now >= target
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FluentIcon(emoji: Self.goalIcon[g.key] ?? "🎯", size: 28)
                if target > 0 {
                    (Text("\(now)").font(.title2.weight(.heavy)) + Text(" of \(target)").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)).monospacedDigit()
                } else { Text("Off").font(.title3.weight(.heavy)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.walk) }
            }
            if target > 0 { bar(Double(now) / Double(target), done: done) }
            Text(g.key == "under" ? "Days on budget" : g.name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    private static let goalIcon = ["under": "🎯", "protein": "🥩", "workouts": "💪", "log": "📒"]

    private func bar(_ share: Double, done: Bool = false) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(done ? Theme.walk : Theme.accent).frame(width: geo.size.width * min(1, max(0, share)))
            }
        }
        .frame(height: 6)
    }

    /// The rank, and how far to the next one.
    private var rankRow: some View {
        let xp = store.totalXP, r = store.rank, next = Rank(level: r.level + 1)
        let from = Rank.xp(forLevel: r.level), to = Rank.xp(forLevel: r.level + 1)
        return HStack(spacing: 13) {
            RankBadge(rank: r, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.body.weight(.semibold))
                Text("\(Fmt.int(Double(xp))) XP · \(Fmt.int(Double(max(0, to - xp)))) XP to \(next.name)").font(.footnote).foregroundStyle(.secondary)
                bar(Double(xp - from) / Double(max(1, to - from)))
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2).contentShape(Rectangle())
    }

    /// The three not-yet badges with a target that are closest to it.
    private func nextBadges(stats: [String: Double], seen: Set<String>) -> [(badge: Badge, now: Double)] {
        Array(Badge.all.filter { $0.target > 1 && !seen.contains($0.id) && !$0.earned(stats) }
            .map { (badge: $0, now: min(stats[$0.stat] ?? 0, $0.target)) }
            .filter { $0.now > 0 }
            .sorted { $0.now / $0.badge.target > $1.now / $1.badge.target }
            .prefix(3))
    }

    private func targetsSheet(_ defs: [WeekGoal]) -> some View {
        NavigationStack {
            List {
                ForEach(defs, id: \.key) { g in
                    let target = store.weekGoals[g.key] ?? 0
                    Stepper(value: Binding(get: { target }, set: { setGoal(g.key, $0) }), in: 0...g.max) {
                        HStack(spacing: 10) {
                            FluentIcon(emoji: Self.goalIcon[g.key] ?? "🎯", size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.key == "under" ? "Days on budget" : g.name).font(.subheadline.weight(.semibold))
                                Text(target == 0 ? "Off" : "\(target) a week").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Weekly targets").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { targets = false } } }
        }
    }

    private func setGoal(_ key: String, _ value: Int) {
        var g = store.weekGoals; g[key] = value
        store.perform(["type": "set", "key": "weekGoals", "value": g as JSON], syncAfter: 2)
    }
}

/// A badge as a coin: its picture on navy, rimmed bronze, silver or gold by how hard it is (its XP: 25–50, 100–200,
/// 400 and up). One not earned yet is grey, with a blue ring for how close it is. The picture is the badge's own art
/// (design/badge-art, drawn in the food icons' Fluent style) once it's in, and its Fluent icon until then.
struct BadgeCoin: View {
    let badge: Badge
    var size: CGFloat = 58
    var got = true
    var progress: Double = 0
    private var rim: [Color] {
        let hex = { (v: Int) in Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255) }
        return badge.xp >= 400 ? [hex(0xFFF0B8), hex(0xF2B94A), hex(0x8A5A12)] : badge.xp >= 100 ? [hex(0xFFFFFF), hex(0xB7C3D3), hex(0x5D6A7C)] : [hex(0xF3C29A), hex(0xB9733F), hex(0x6B3D1C)]
    }
    var body: some View {
        ZStack {
            Circle().fill(got ? AnyShapeStyle(LinearGradient(colors: rim, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color(white: 0.17)))
            Circle().fill(RadialGradient(colors: got ? [Color(red: 0.14, green: 0.2, blue: 0.29), Color(red: 0.06, green: 0.09, blue: 0.14)] : [Color(white: 0.14), Color(white: 0.09)],
                                         center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: size * 0.55))
                .padding(size * 0.075)
            if !got && progress > 0 {
                Circle().trim(from: 0, to: min(1, progress)).stroke(Theme.accent, style: StrokeStyle(lineWidth: max(2, size * 0.05), lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(size * 0.025)
            }
            Group {
                if let art = UIImage(named: "badge-\(badge.id)") { Image(uiImage: art).resizable().scaledToFit() }
                else { FluentIcon(emoji: badge.icon, size: size * 0.52) }
            }
            .frame(width: size * 0.56, height: size * 0.56)
            .grayscale(got ? 0 : 1).opacity(got ? 1 : 0.4)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A badge in a grid: its coin, with its name.
func badgeCell(_ b: Badge, got: Bool, progress: Double = 0, count: String? = nil) -> some View {
    VStack(spacing: 5) {
        BadgeCoin(badge: b, size: 58, got: got, progress: progress)
        Text(b.name).font(.caption2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(got ? .primary : .secondary)
        if let count { Text(count).font(.caption2).monospacedDigit().foregroundStyle(.tertiary) }
    }
    .frame(maxWidth: .infinity)
}

/// Every badge, by group, with how many of each group are earned.
struct AllBadgesView: View {
    @Binding var shown: Badge?
    private var store: Store { Store.shared }
    var body: some View {
        let stats = store.badgeStats, seen = store.seenBadges
        List {
            ForEach(Badge.groups, id: \.self) { group in
                let all = Badge.all.filter { $0.group == group }, earned = all.filter { seen.contains($0.id) || $0.earned(stats) }.count
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
                        ForEach(all) { b in
                            let got = seen.contains(b.id) || b.earned(stats)
                            Button { shown = b } label: {
                                let now = min(stats[b.stat] ?? 0, b.target)
                                badgeCell(b, got: got, progress: b.target > 1 ? now / b.target : 0,
                                          count: !got && b.target > 1 ? "\(Fmt.int(now))/\(Fmt.int(b.target))" : nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                } header: { Text("\(group) · \(earned) of \(all.count)") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Badges")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One badge, big: how to get it, and earned or how far.
struct BadgeSheet: View {
    let badge: Badge, stats: [String: Double], got: Bool
    var body: some View {
        VStack(spacing: 12) {
            BadgeCoin(badge: badge, size: 112, got: got, progress: badge.target > 1 ? min(stats[badge.stat] ?? 0, badge.target) / badge.target : 0).padding(.top, 28)
            Text(badge.name).font(.title2.bold())
            Text(badge.how).foregroundStyle(.secondary)
            if got { Label("Earned · +\(badge.xp) XP", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.walk) }
            else if badge.target > 1 {
                let now = min(stats[badge.stat] ?? 0, badge.target)
                ProgressView(value: now, total: badge.target).tint(Theme.accent).padding(.horizontal, 40)
                Text("\(Fmt.int(now)) of \(Fmt.int(badge.target)) · worth \(badge.xp) XP").font(.subheadline).foregroundStyle(.secondary)
            } else { Text("Worth \(badge.xp) XP").font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }
}
