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

/// The trim along the top of the calorie panel: a metal line that gets fancier with each tier, dipping in the middle where the badge sits,
/// with a shine that sweeps across every few seconds.
struct RankTrim: View {
    let rank: Rank
    @State private var sweep = false

    var body: some View {
        let t = rank.tier
        let metal = LinearGradient(colors: [rank.dark, rank.color, rank.light, rank.color, rank.dark], startPoint: .leading, endPoint: .trailing)
        let width: CGFloat = t >= 3 ? 3 : 2
        ZStack {
            TrimPath(tier: t).stroke(metal, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            if t >= 1 { TrimPath(tier: t, inner: true).stroke(rank.light.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)) }
            if t == 0 { Diamond().fill(metal).frame(width: 10, height: 10).offset(y: -2) }
            // the shine: a bright band passing along the metal
            GeometryReader { g in
                LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 70)
                    .offset(x: sweep ? g.size.width + 70 : -140)
            }
            .mask(TrimPath(tier: t).stroke(style: StrokeStyle(lineWidth: width + 1, lineCap: .round, lineJoin: .round)))
        }
        .frame(height: 30)
        .shadow(color: rank.color.opacity(t >= 4 ? 0.7 : 0.3), radius: t >= 4 ? 6 : 3)
        .task {
            // a sweep every few seconds, not a constant shimmer
            while !Task.isCancelled {
                sweep = false
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeInOut(duration: 1.4)) { sweep = true }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath()
        return p
    }
}

/// The trim's lines. Tier 0: a plain line. 1: it dips into a notch. 2: end caps. 3: wings beside the notch. 4: a second rail. 5: flourishes at the ends.
private struct TrimPath: Shape {
    let tier: Int
    var inner = false

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, mid = r.midX, inset: CGFloat = 6   // the same trim, stretched out to the panel's corners
        let y: CGFloat = inner ? 10 : 6
        let notch: CGFloat = tier == 0 ? 0 : 30 + CGFloat(tier) * 5
        let depth: CGFloat = tier == 0 ? 0 : 13 + CGFloat(tier)
        p.move(to: CGPoint(x: inset + (inner ? 6 : 0), y: y))
        if notch > 0 {
            p.addLine(to: CGPoint(x: mid - notch, y: y))
            p.addLine(to: CGPoint(x: mid - notch * 0.42, y: y + depth))
            p.addLine(to: CGPoint(x: mid + notch * 0.42, y: y + depth))
            p.addLine(to: CGPoint(x: mid + notch, y: y))
        }
        p.addLine(to: CGPoint(x: w - inset - (inner ? 6 : 0), y: y))
        guard !inner else { return p }
        if tier >= 2 {   // end caps
            for (x, d) in [(inset, CGFloat(-1)), (w - inset, CGFloat(1))] {
                p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + d * 8, y: y + 7))
            }
        }
        if tier >= 3 {   // wings beside the notch
            for d in [CGFloat(-1), 1] {
                p.move(to: CGPoint(x: mid + d * (notch + 46), y: y + 5))
                p.addLine(to: CGPoint(x: mid + d * (notch + 8), y: y + 5))
                p.addLine(to: CGPoint(x: mid + d * (notch * 0.42 + 4), y: y + depth + 5))
            }
        }
        if tier >= 4 {   // a second rail near the ends
            for d in [CGFloat(-1), 1] {
                let x0 = d < 0 ? inset + 14 : w - inset - 14
                p.move(to: CGPoint(x: x0, y: y + 4)); p.addLine(to: CGPoint(x: x0 - d * 60, y: y + 4))
            }
        }
        if tier >= 5 {   // flourishes
            for (x, d) in [(inset, CGFloat(1)), (w - inset, CGFloat(-1))] {
                p.move(to: CGPoint(x: x + d * 4, y: y - 3)); p.addLine(to: CGPoint(x: x + d * 34, y: y - 3)); p.addLine(to: CGPoint(x: x + d * 40, y: y - 1))
            }
        }
        return p
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
                        RankTrim(rank: rank).padding(.top, 4)
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
            Text(rank.step == 1 || rank.step == nil ? "A new rank. Look at the trim on your calorie panel." : "Another step up. Keep it going.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            RankTrim(rank: rank).padding(.horizontal, 20)
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
