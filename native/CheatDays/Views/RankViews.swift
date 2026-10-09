import SwiftUI

/// A rank's badge: the art from design/rank-art when it's in the app, else a drawn shield in the rank's colours.
struct RankBadge: View {
    let rank: Rank
    var size: CGFloat = 40
    var body: some View {
        if UIImage(named: "rank-\(rank.key)") != nil {
            Image("rank-\(rank.key)").resizable().scaledToFit().frame(width: size, height: size)
        } else {
            ZStack {
                Image(systemName: "shield.fill").resizable().scaledToFit().foregroundStyle(rank.dark)
                Image(systemName: "shield").resizable().scaledToFit().foregroundStyle(rank.color)
                Text(String(rank.tierName.prefix(1))).font(.system(size: size * 0.36, weight: .heavy, design: .rounded)).foregroundStyle(rank.light)
            }
            .frame(width: size, height: size)
        }
    }
}

/// The ladder: your rank and XP to the next step, every tier, how to earn XP, and friends' ranks.
struct RanksView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }
    private var friends: Friends { Friends.shared }

    var body: some View {
        let xp = store.totalXP, rank = store.rank
        let base = Rank.xp(forLevel: rank.level), next = Rank.xp(forLevel: rank.level + 1)
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        RankBadge(rank: rank, size: 110)
                            .shadow(color: rank.color.opacity(0.5), radius: 18)
                        Text(rank.name).font(.largeTitle.bold())
                        Text("\(Fmt.int(Double(xp))) XP").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 4) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.track)
                                    Capsule().fill(rank.color).frame(width: g.size.width * min(1, Double(xp - base) / Double(max(1, next - base))))
                                }
                            }
                            .frame(height: 10)
                            Text("\(Fmt.int(Double(next - xp))) XP to \(Rank(level: rank.level + 1).name)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .listRowBackground(Theme.hero)
                Section("The ranks") {
                    ForEach(0..<6, id: \.self) { t in
                        let r = Rank.first(ofTier: t), reached = rank.tier >= t
                        HStack(spacing: 14) {
                            RankBadge(rank: r, size: 40).saturation(reached ? 1 : 0).opacity(reached ? 1 : 0.5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.tierName).font(.headline)
                                Text(t == 5 ? "From \(Fmt.int(Double(Rank.xp(forLevel: r.level)))) XP" : "\(Fmt.int(Double(Rank.xp(forLevel: r.level)))) XP, then steps II and III")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if rank.tier == t { Text("You").font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3).background(r.color, in: Capsule()).foregroundStyle(.black) }
                            else if !reached { Image(systemName: "lock.fill").foregroundStyle(.tertiary) }
                        }
                    }
                }
                Section("How to earn XP") {
                    ForEach(XPRules.ways, id: \.0) { w in
                        HStack { Text(w.0).font(.subheadline); Spacer(); Text(w.1).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent) }
                    }
                }
                let people = friends.people.filter { $0.level > 0 }.map { (name: $0.name, xp: Int(num($0.stats?["xp"]) ?? 0), rank: Rank(level: $0.level)) }
                if !people.isEmpty {
                    Section("You and your friends") {
                        let all = (people + [(name: "You", xp: xp, rank: rank)]).sorted { $0.xp > $1.xp }
                        ForEach(all.indices, id: \.self) { i in
                            let p = all[i]
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.headline).foregroundStyle(i == 0 ? Theme.warn : .secondary).frame(width: 22)
                                RankBadge(rank: p.rank, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(.subheadline.weight(p.name == "You" ? .heavy : .semibold))
                                    Text(p.rank.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(Fmt.int(Double(p.xp))) XP").font(.subheadline.weight(.bold)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Ranks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.bold) } }
            .task { if friends.people.isEmpty { await friends.load() } }
        }
    }
}

/// The moment you go up a rank.
struct RankUpView: View {
    let rank: Rank
    var done: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Eyebrow(text: "Ranked up", color: rank.color)
            RankBadge(rank: rank, size: 160)
                .shadow(color: rank.color.opacity(0.7), radius: shown ? 30 : 0)
                .scaleEffect(shown ? 1 : 0.3).rotationEffect(.degrees(shown ? 0 : -25))
            Text(rank.name).font(.system(size: 40, weight: .heavy, design: .rounded))
            Text(rank.step == 1 || rank.step == nil ? "A new rank. It's next to your name in Me." : "Another step up. Keep it going.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
            Button { done() } label: { Text("Nice").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).tint(rank.color).foregroundStyle(.black)
                .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .sensoryFeedback(.success, trigger: shown)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.55).delay(0.15)) { shown = true } }
    }
}
