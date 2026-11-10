import SwiftUI

/// Explore, the public feed: public profiles' posts as a grid (some tiles tall, like Instagram's), most liked and
/// newest first, with a search for people and foods. Tap one to scroll the posts from there.
/// Private profiles never show here, and nobody's day, week, food log or weight does.
struct ExploreView: View {
    @State private var chip = "For you"
    @State private var q = ""
    @State private var people: [Profiles.Profile] = []
    @State private var opened: Int?
    private var follows: Follows { Follows.shared }
    private static let chips = ["For you", "💪 High protein", "Under 500", "🍳 Breakfast", "🥗 Lunch", "🍝 Dinner", "🏋️ Workouts"]

    private var shown: [JSON] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        return follows.explore.filter { p in
            if Profiles.shared.muted.contains(str(p["owner"])) { return false }
            if !t.isEmpty && !str(p["name"]).lowercased().contains(t) && !str(p["caption"]).lowercased().contains(t) { return false }
            let kcal = num(p["kcal"]) ?? 0, pr = num(dict(p["macros"])["p"]) ?? 0, kind = str(p["kind"]), meal = str(dict(p["extra"])["meal"])
            switch chip {
            case "💪 High protein": return kind != "workout" && (pr >= 30 || (kcal > 0 && pr / kcal * 100 >= 8))
            case "Under 500": return kind != "workout" && kcal > 0 && kcal < 500
            case "🍳 Breakfast": return meal == "Breakfast"
            case "🥗 Lunch": return meal == "Lunch"
            case "🍝 Dinner": return meal == "Dinner"
            case "🏋️ Workouts": return kind == "workout"
            default: return true
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let side = (geo.size.width - 4) / 3
            ScrollView {
                VStack(spacing: 0) {
                    // its own search box: Friends has no navigation bar to hang one from
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search people or foods", text: $q).autocorrectionDisabled()
                        if !q.isEmpty { Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                    // no filter chips under the search (the owner: they looked cheap); the search narrows it
                    if !people.isEmpty { peopleRow.padding(.bottom, 8) }
                    if let e = follows.error { Text(e).font(.footnote).foregroundStyle(Theme.warn).padding(16) }
                    else if shown.isEmpty && !follows.exploring {
                        Text(follows.explore.isEmpty ? "Nothing on Explore yet. Posts from public profiles show here." : "Nothing matches that.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 40).padding(.horizontal, 30).multilineTextAlignment(.center)
                    }
                    mosaic(side)
                }
                .padding(.bottom, 110)
            }
            .refreshable { await follows.loadExplore() }
        }
        .task(id: q) {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { people = q.count >= 2 ? await follows.search(q) : [] }
        }
        .task { if follows.explore.isEmpty { await follows.loadExplore() } }
        .overlay { if follows.exploring && follows.explore.isEmpty { ProgressView() } }
        .navigationDestination(item: $opened) { i in
            let list = shown
            FeedView(only: Array(list[min(i, max(0, list.count - 1))...])).navigationTitle("Explore").navigationBarTitleDisplayMode(.inline)
        }
    }

    private var peopleRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(people, id: \.id) { p in
                    NavigationLink { ProfileView(id: p.id) } label: {
                        VStack(spacing: 4) {
                            Avatar(id: p.id, size: 56)
                            Text(p.username.isEmpty ? p.name : "@\(p.username)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 70)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden)
    }

    /// Groups of five: one tall tile and four small, the tall one switching sides each time.
    private func mosaic(_ side: CGFloat) -> some View {
        let posts = shown
        let groups = stride(from: 0, to: posts.count, by: 5).map { Array(posts.indices[$0..<min($0 + 5, posts.count)]) }
        return LazyVStack(spacing: 2) {
            ForEach(groups.indices, id: \.self) { g in
                let idx = groups[g], tallLeft = g % 2 == 0
                HStack(spacing: 2) {
                    if tallLeft { tile(posts, idx[0], w: side, h: side * 2 + 2) }
                    VStack(spacing: 2) {
                        HStack(spacing: 2) { small(posts, idx, 1, side); small(posts, idx, 2, side) }
                        HStack(spacing: 2) { small(posts, idx, 3, side); small(posts, idx, 4, side) }
                    }
                    if !tallLeft { tile(posts, idx[0], w: side, h: side * 2 + 2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func small(_ posts: [JSON], _ idx: [Int], _ k: Int, _ side: CGFloat) -> some View {
        if k < idx.count { tile(posts, idx[k], w: side, h: side) } else { Color.clear.frame(width: side, height: side) }
    }

    private func tile(_ posts: [JSON], _ i: Int, w: CGFloat, h: CGFloat) -> some View {
        let p = posts[i], kind = str(p["kind"]), photo = str(p["photo"])
        let pr = num(dict(p["macros"])["p"])
        return Button { opened = i } label: {
            ZStack {
                if Feed.hasPhoto(p) { FeedPhoto(src: photo, fill: true) }
                else {
                    LinearGradient(colors: [Theme.hero, Theme.accent.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    FoodDot(name: kind == "workout" ? "Workout" : str(p["name"]), size: h > w ? 70 : 48)
                }
            }
            .frame(width: w, height: h).clipped()
            .overlay(alignment: .bottomLeading) {
                Group {
                    if kind == "workout" { Text("\(Int(num(dict(p["extra"])["minutes"]) ?? 0)) min") }
                    else { Text(Fmt.int(num(p["kcal"]) ?? 0)) + Text(pr.map { " · \(Int($0)) g" } ?? "").foregroundStyle(Theme.walk) }
                }
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5)).padding(5)
            }
        }
        .buttonStyle(.plain)
    }
}
