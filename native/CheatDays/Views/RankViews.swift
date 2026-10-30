import SwiftUI

/// A rank's badge: the app's logo on an emblem of the tier's own shape (coin, tile, hexagon, shield, octagon, eight-point
/// star), filled top to bottom in the tier's colours with a bright edge. No glow: it sits flat on the page.
struct RankBadge: View {
    let rank: Rank
    var size: CGFloat = 40
    var body: some View {
        let shape = RankShape(tier: rank.tier)
        let edge = LinearGradient(stops: [.init(color: .white.opacity(0.9), location: 0), .init(color: rank.color, location: 0.5),
                                          .init(color: rank.color.opacity(0.7), location: 1)], startPoint: .top, endPoint: .bottom)
        ZStack {
            shape.fill(LinearGradient(colors: [rank.mid, rank.dark], startPoint: .top, endPoint: .bottom))
            shape.stroke(edge, lineWidth: max(1.2, size * 0.04))
            if rank.tier >= 4 {   // Elite and Legend: a second, inner edge
                shape.stroke(rank.color.opacity(0.75), lineWidth: max(0.8, size * 0.02)).scaleEffect(0.8)
            }
            LogoMark().fill(rank.color)
                .frame(width: size * 0.5, height: size * 0.27)
                .offset(y: rank.tier == 3 ? -size * 0.03 : 0)   // a shield's middle sits a little high
        }
        .frame(width: size, height: size)
    }
}

/// Each tier's emblem, drawn on a 100 × 100 grid.
struct RankShape: Shape {
    let tier: Int
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100, ox = rect.midX - 50 * s, oy = rect.midY - 50 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func poly(_ pts: [(CGFloat, CGFloat)]) -> Path { var g = Path(); g.addLines(pts.map { p($0.0, $0.1) }); g.closeSubpath(); return g }
        switch tier {
        case 0: return Path(ellipseIn: CGRect(origin: p(6, 6), size: CGSize(width: 88 * s, height: 88 * s)))
        case 1: return Path(roundedRect: CGRect(origin: p(8, 8), size: CGSize(width: 84 * s, height: 84 * s)), cornerRadius: 20 * s, style: .continuous)
        case 2: return poly([(50, 4), (90, 27), (90, 73), (50, 96), (10, 73), (10, 27)])
        case 3:
            var g = Path()
            g.move(to: p(50, 4)); g.addLine(to: p(88, 16)); g.addLine(to: p(88, 48))
            g.addQuadCurve(to: p(50, 96), control: p(88, 78)); g.addQuadCurve(to: p(12, 48), control: p(12, 78))
            g.addLine(to: p(12, 16)); g.closeSubpath()
            return g
        case 4: return poly([(33, 5), (67, 5), (95, 33), (95, 67), (67, 95), (33, 95), (5, 67), (5, 33)])
        default:   // an eight-point star, the step up from Elite's octagon
            return poly((0..<16).map { i in
                let a = Double(i) / 16 * 2 * .pi - .pi / 2, r: Double = i % 2 == 0 ? 49 : 37
                return (CGFloat(50 + r * cos(a)), CGFloat(50 + r * sin(a)))
            })
        }
    }
}

/// Steps I, II and III as three chevrons under a badge, lit up to the step you're on. Legend has none.
struct RankSteps: View {
    let rank: Rank
    var width: CGFloat = 60
    var body: some View {
        if let step = rank.step {
            HStack(spacing: width * 0.06) {
                ForEach(1...3, id: \.self) { i in
                    Chevron().stroke(i <= step ? rank.color : Theme.track, style: StrokeStyle(lineWidth: width * 0.07, lineCap: .round, lineJoin: .round))
                        .frame(width: width * 0.22, height: width * 0.1)
                }
            }
            .accessibilityHidden(true)
        }
    }
    private struct Chevron: Shape {
        func path(in r: CGRect) -> Path { var g = Path(); g.move(to: CGPoint(x: r.minX, y: r.minY)); g.addLine(to: CGPoint(x: r.midX, y: r.maxY)); g.addLine(to: CGPoint(x: r.maxX, y: r.minY)); return g }
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
                    VStack(spacing: 8) {
                        RankBadge(rank: rank, size: 112)
                        RankSteps(rank: rank, width: 64)
                        Text(rank.name).font(.system(size: 30, weight: .heavy, design: .rounded)).padding(.top, 2)
                        Text("Level \(rank.level) · \(Fmt.int(Double(xp))) XP").font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.track)
                                    Capsule().fill(LinearGradient(colors: [rank.mid, rank.color], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: g.size.width * min(1, Double(xp - base) / Double(max(1, next - base))))
                                }
                            }
                            .frame(height: 8)
                            HStack {
                                (Text("Next: ").foregroundStyle(.secondary) + Text(Rank(level: rank.level + 1).name).bold())
                                Spacer()
                                (Text("\(Fmt.int(Double(next - xp))) XP").bold() + Text(" to go").foregroundStyle(.secondary))
                            }
                            .font(.footnote)
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .listRowBackground(Theme.hero)
                Section("The ladder") {
                    ForEach(0..<6, id: \.self) { t in
                        let r = Rank.first(ofTier: t), reached = rank.tier >= t
                        HStack(spacing: 14) {
                            RankBadge(rank: r, size: 40).saturation(reached ? 1 : 0).opacity(reached ? 1 : 0.45)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.tierName).font(.headline).foregroundStyle(reached ? r.color : .primary)
                                Text(t == 5 ? "The top" : "Steps I, II and III").font(.caption).foregroundStyle(.secondary)
                            }
                            .opacity(reached ? 1 : 0.55)
                            Spacer()
                            if rank.tier == t { Text("You").font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3).background(r.color, in: Capsule()).foregroundStyle(.black) }
                            else { Text("\(Fmt.int(Double(Rank.xp(forLevel: r.level)))) XP").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        // the line joining the ladder, lit up to where you are
                        .background(alignment: .leading) {
                            VStack(spacing: 0) {
                                Rectangle().fill(t == 0 ? .clear : (reached ? r.color.opacity(0.7) : Theme.track))
                                Rectangle().fill(t == 5 ? .clear : (rank.tier > t ? Rank.first(ofTier: t + 1).color.opacity(0.7) : Theme.track))
                            }
                            .frame(width: 2).padding(.vertical, -12).offset(x: 19)
                        }
                        .listRowSeparator(.hidden)
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.bold) } }
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
                .scaleEffect(shown ? 1 : 0.3).rotationEffect(.degrees(shown ? 0 : -25))
            RankSteps(rank: rank, width: 80).opacity(shown ? 1 : 0)
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
