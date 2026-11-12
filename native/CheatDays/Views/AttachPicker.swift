import SwiftUI

/// The last month's foods, saved meals and workouts, to pick one to go with a post: in New post, and when editing
/// one that's already up. It opens on Foods, Meals or Workouts as asked.
struct AttachPicker: View {
    var pick: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var shelf: Int
    private var store: Store { Store.shared }

    init(start: Int = 0, pick: @escaping (JSON) -> Void) {
        self.pick = pick
        _shelf = State(initialValue: start)
    }

    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }
    /// The last 30 days, newest first: today's, then History's.
    private var days: [(date: String, items: [JSON], workouts: [JSON])] {
        let since = DayKey.shift(store.today, days: -30)
        let past = list(store.doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < store.today }
            .map { (date: str($0["date"]), items: list($0["items"]), workouts: list($0["workouts"])) }.sorted { $0.date > $1.date }
        return [(date: store.today, items: store.todayItems, workouts: store.todayWorkouts)] + past
    }
    /// Each food once, the latest time it was had.
    private var recentFoods: [JSON] {
        var seen = Set<String>(), out: [JSON] = []
        for d in days { for it in d.items.reversed() where matches(str(it["name"])) && seen.insert(str(it["name"]).lowercased()).inserted { var x = it; x["_date"] = d.date; out.append(x) } }
        return Array(out.prefix(search.isEmpty ? 25 : 60))
    }
    private var savedMeals: [JSON] {
        Array(list(store.doc["meals"]).filter { $0["saved"] as? Bool == true && matches(str($0["name"])) }.prefix(search.isEmpty ? 12 : 60))
    }
    private var recentWorkouts: [JSON] {
        var out: [JSON] = []
        for d in days { for w in d.workouts.reversed() where matches(str(w["name"])) { var x = w; x["_date"] = d.date; out.append(x) } }
        return Array(out.prefix(search.isEmpty ? 12 : 40))
    }
    private func when(_ v: Any?) -> String {
        let d = str(v)
        if d == store.today { return "today" }
        if d == DayKey.shift(store.today, days: -1) { return "yesterday" }
        return DayKey.date(d).formatted(.dateTime.day().month(.abbreviated))
    }

    /// The last month's foods, saved meals and workouts to attach: one list at a time, or all three when searching.
    var body: some View {
        NavigationStack {
            List {
                let items = recentFoods, meals = savedMeals, wos = recentWorkouts
                if search.isEmpty {
                    Picker("Show", selection: $shelf) {
                        Text("Foods").tag(0); Text("Meals").tag(1); Text("Workouts").tag(2)
                    }
                    .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                if !items.isEmpty && (!search.isEmpty || shelf == 0) {
                    Section("Foods") { ForEach(items.indices, id: \.self) { i in pickRow(str(items[i]["name"]), "\(Int(num(items[i]["kcal"]) ?? 0)) kcal · \(when(items[i]["_date"]))") { pick(food(items[i])); dismiss() } } }
                }
                if !meals.isEmpty && (!search.isEmpty || shelf == 1) {
                    Section("Meals and recipes") { ForEach(meals.indices, id: \.self) { i in let m = meals[i]; pickRow(str(m["name"]), "\(Fmt.int(num(store.mealBasis(m)["kcalPerServing"]) ?? 0)) kcal a portion") { pick(meal(m)); dismiss() } } }
                }
                if !wos.isEmpty && (!search.isEmpty || shelf == 2) {
                    Section("Workouts") { ForEach(wos.indices, id: \.self) { i in pickRow(str(wos[i]["name"]), "\(Int(num(wos[i]["minutes"]) ?? 0)) min · \(when(wos[i]["_date"]))", symbol: "dumbbell.fill") { pick(workout(wos[i])); dismiss() } } }
                }
                let none = search.isEmpty ? [items, meals, wos][shelf].isEmpty : (items.isEmpty && meals.isEmpty && wos.isEmpty)
                if none {
                    Text(!search.isEmpty ? "Nothing called that." : ["Log a food and it's here to share.", "Save a meal or recipe and it's here to share.", "Finish a workout and it's here to share."][shelf])
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods, meals and workouts")
            .navigationTitle("Add to your post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    /// `dot` is what the little picture is of when that isn't the row's own name: a workout's is the dumbbell, not
    /// a plate of food guessed from "Back & Biceps".
    private func pickRow(_ name: String, _ detail: String, dot: String? = nil, symbol: String? = nil, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                // a workout has its own sign: looked up as a food, it got the plate every unknown food gets
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30).background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else { FoodDot(name: dot ?? name, size: 30) }
                VStack(alignment: .leading, spacing: 1) { Text(name).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }

    private func food(_ it: JSON) -> JSON {
        let m = store.macros([it]), k = num(it["kcal"]) ?? 0
        return ["kind": "food", "name": it["name"] ?? "", "kcal": Int(k), "macros": ["p": Int(m.p), "c": Int(m.c), "f": Int(m.f)] as JSON,
                "payload": FoodMath.basisOf(it), "extra": ["grams": it["grams"] ?? NSNull(), "unit": it["unit"] ?? "g", "meal": Meals.of(it)] as JSON]
    }
    private func meal(_ m: JSON) -> JSON {
        let b = store.mealBasis(m), n = num(m["portions"]) ?? 1
        return ["kind": "meal", "name": m["name"] ?? "", "kcal": Int((num(b["kcalPerServing"]) ?? 0).rounded()),
                "macros": ["p": Int(num(b["pServ"]) ?? 0), "c": Int(num(b["cServ"]) ?? 0), "f": Int(num(b["fServ"]) ?? 0)] as JSON,
                "payload": ["name": m["name"] ?? "", "portions": n, "items": m["items"] ?? [Any](), "steps": m["steps"] ?? [Any]()] as JSON, "extra": ["portions": n] as JSON]
    }
    private func workout(_ w: JSON) -> JSON { ComposeSheet.workoutPost(w) }
}
