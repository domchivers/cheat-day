import SwiftUI

/// Every way to add food in one sheet: search everything you've had and the food list, your usual foods
/// for this meal, favourites and recents. Barcode, photo, assistant and typing open their web screens for now.
struct AddSheet: View {
    @State var meal: String
    let onFlow: (WebFlow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var store: Store { Store.shared }

    init(meal: String, onFlow: @escaping (WebFlow) -> Void) {
        _meal = State(initialValue: meal)
        self.onFlow = onFlow
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Meal", selection: $meal) { ForEach(Meals.all, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    HStack(spacing: 10) {
                        way("barcode.viewfinder", "Barcode") { onFlow(WebFlow(view: "scan", opts: ["scan": "barcode", "meal": meal], title: "Scan")) }
                        way("camera.fill", "Photo") { onFlow(WebFlow(view: "scan", opts: ["scan": "label", "meal": meal], title: "Photo")) }
                        way("sparkles", "Ask AI") { onFlow(WebFlow(view: "ask", opts: ["meal": meal], title: "Assistant")) }
                        way("square.and.pencil", "Type it") { onFlow(WebFlow(view: "manual", opts: ["meal": meal], title: "Type it in")) }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty { suggestions } else { results }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods and your history")
            .navigationTitle("Add to \(meal)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .navigationDestination(for: EditTarget.self) { t in AmountView(target: t) { dismiss() } }
        }
    }

    @ViewBuilder private var suggestions: some View {
        let usual = store.usual(for: meal)
        let favs = store.favourites.filter { f in !usual.contains { $0.key == f.key } }
        let shown = Set((usual + favs).map(\.key))
        let rest = store.quickEntries.filter { !shown.contains($0.key) }.prefix(20)
        if !usual.isEmpty { Section("Your \(meal == "Snacks" ? "snacks" : meal.lowercased() + "s")") { ForEach(usual) { row($0) } } }
        if !favs.isEmpty { Section("Favourites") { ForEach(favs) { row($0) } } }
        if !rest.isEmpty {
            Section { ForEach(Array(rest)) { row($0) } } header: { Text("Recent") } footer: { Text("Swipe right on a food to star it. Stars stay at the top.") }
        }
        if usual.isEmpty && favs.isEmpty && rest.isEmpty {
            Section { Text("Foods you add come back here, so next time is one tap. Search above, or scan a barcode.").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var results: some View {
        let found = store.search(query)
        if !found.mine.isEmpty { Section("Things you've had") { ForEach(found.mine) { row($0) } } }
        if !found.foods.isEmpty {
            Section("Foods") {
                ForEach(found.foods.indices, id: \.self) { i in
                    let f = found.foods[i]
                    let kcal = pos(f["kcalPerServing"]) ?? pos(f["kcalPer100"]) ?? 0
                    let label = str(f["unitLabel"])
                    row(QuickEntry(key: "food:" + str(f["name"]), basis: f, kcal: kcal,
                                   detail: label.isEmpty ? "\(Fmt.int(num(f["kcalPer100"]) ?? 0)) kcal per 100 \(str(f["unit"]))" : "1 \(label)",
                                   uses: 0, lastUsed: "", kind: .food))
                }
            }
        }
        if found.mine.isEmpty && found.foods.isEmpty {
            Section {
                Text("Nothing matches \"\(query)\".").foregroundStyle(.secondary)
                Button("Ask the assistant about it") { onFlow(WebFlow(view: "ask", opts: ["meal": meal, "q": query], title: "Assistant")) }
                Button("Type the numbers in") { onFlow(WebFlow(view: "manual", opts: ["meal": meal], title: "Type it in")) }
            }
        }
    }

    private func row(_ e: QuickEntry) -> some View {
        let fav = store.isFavourite(e.key)
        return HStack(spacing: 12) {
            NavigationLink(value: EditTarget(basis: e.basis, kcal: e.kcal, editId: nil, meal: meal)) {
                HStack(spacing: 12) {
                    FoodDot(name: e.name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name).font(.body.weight(.semibold)).lineLimit(2)
                        if !e.detail.isEmpty { Text(e.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if fav { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    Text(Fmt.int(e.kcal)).font(.body.weight(.bold)).monospacedDigit().foregroundStyle(Theme.accent)
                }
            }
            Button {
                store.add(e.basis, kcal: e.kcal, meal: meal)
                dismiss()
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add \(e.name)")
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if e.kind != .food {
                Button { store.setFavourite(e, on: !fav) } label: { Label(fav ? "Unstar" : "Star", systemImage: fav ? "star.slash" : "star.fill") }
                    .tint(.yellow)
            }
        }
    }

    private func way(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent)
                Text(label).font(.caption.weight(.bold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
