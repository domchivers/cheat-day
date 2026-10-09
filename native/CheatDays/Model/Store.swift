import Foundation
import Observation

/// The account's record (the same JSON the website syncs), kept on the phone and in the cloud.
///
/// Safety rule: the app never uploads its own idea of the whole record. Each change is an operation
/// (add, delete, edit, star); to sync, it downloads the latest record, applies the operations it hasn't
/// sent yet on top, and uploads that. Food logged on the website in the meantime is kept, and every
/// field the native app doesn't know about passes through untouched.
@MainActor @Observable
final class Store {
    static let shared = Store()

    private(set) var doc: JSON = [:]
    private(set) var pending: [JSON] = []
    private(set) var syncing = false
    private(set) var lastSynced: Date?
    var syncError: String?

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CheatDays", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        doc = (Self.read(folder.appendingPathComponent("doc.json")) as? JSON) ?? [:]
        pending = (Self.read(folder.appendingPathComponent("pending.json")) as? [Any])?.compactMap { $0 as? JSON } ?? []
    }

    // MARK: reading

    var day: JSON { dict(doc["day"]) }

    /// The day being logged. Before 5am, yesterday carries on (the web app's late-night rule).
    var today: String {
        let now = Date(), key = DayKey.string(now)
        let logged = str(day["date"])
        if Calendar.current.component(.hour, from: now) < 5, logged == DayKey.shift(key, days: -1) { return logged }
        return key
    }

    var todayItems: [JSON] { str(day["date"]) == today ? list(day["items"]) : [] }
    var todayWorkouts: [JSON] { str(day["date"]) == today ? list(day["workouts"]) : [] }
    var burned: Double { todayWorkouts.reduce(0) { $0 + (num($1["kcal"]) ?? 0) } }
    var eaten: Double { todayItems.reduce(0) { $0 + (num($1["kcal"]) ?? 0) } }

    func baseBudget(_ date: String) -> Double { Self.baseBudget(date, in: doc) }
    static func baseBudget(_ date: String, in d: JSON) -> Double {
        if let v = pos(dict(d["dayBudgets"])[String(DayKey.weekday(date))]) { return v }
        return pos(d["budget"]) ?? 1600
    }
    var budgetToday: Double { baseBudget(today) + ((doc["eatBack"] as? Bool ?? false) ? burned : 0) }
    var left: Double { budgetToday - eaten }

    var proteinGoal: Double? { pos(dict(doc["goals"])["p"]) }
    func macros(_ items: [JSON]) -> (p: Double, c: Double, f: Double) {
        var p = 0.0, c = 0.0, f = 0.0
        for it in items { if let m = FoodMath.macros(it, kcal: num(it["kcal"]) ?? 0) { p += m.p; c += m.c; f += m.f } }
        return (p, c, f)
    }

    /// A past day: from History, or the logged day itself if it hasn't been filed yet.
    func pastDay(_ date: String) -> (items: [JSON], budget: Double, kcal: Double)? {
        if str(day["date"]) == date {
            let items = list(day["items"])
            return (items, baseBudget(date), items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) })
        }
        guard let h = list(doc["history"]).first(where: { str($0["date"]) == date }) else { return nil }
        return (list(h["items"]), num(h["budget"]) ?? baseBudget(date), num(h["kcal"]) ?? 0)
    }

    // MARK: changing

    func add(_ basis: JSON, kcal: Double, meal: String?) {
        let k = kcal.rounded()
        var item = FoodMath.basisOf(basis)
        item["id"] = uid()
        item["kcal"] = Int(k)
        item["shareLabel"] = Fmt.share(k, of: baseBudget(today))
        item["addedAt"] = ISO.now()
        if let meal, Meals.all.contains(meal) { item["meal"] = meal }
        perform(["type": "add", "item": item])
    }

    func delete(_ id: String) { perform(["type": "delete", "id": id, "at": nowMs()]) }

    func edit(_ id: String, kcal: Double, meal: String) {
        let k = kcal.rounded()
        perform(["type": "edit", "id": id, "kcal": Int(k), "shareLabel": Fmt.share(k, of: baseBudget(today)), "meal": meal])
    }

    func setFavourite(_ entry: QuickEntry, on: Bool) {
        var op: JSON = ["type": "fav", "key": entry.key, "on": on, "at": ISO.now()]
        if entry.kind == .past {   // an old food starred from search joins Quick add so it stays
            op["recent"] = ["key": entry.key, "basis": entry.basis, "lastKcal": Int(entry.kcal.rounded()), "lastShareLabel": "", "lastUsed": ISO.now(), "uses": max(1, Int(entry.uses))] as JSON
        }
        perform(op)
    }

    func perform(_ op: JSON, syncAfter: Double = 0.6) {
        var d = doc
        Self.apply(op, to: &d, today: today)
        d["updatedAt"] = nowMs()
        doc = d
        // a live session changes often: only its latest state needs sending
        if str(op["type"]) == "session", let last = pending.last, str(last["type"]) == "session" { pending[pending.count - 1] = op }
        else { pending.append(op) }
        persist()
        scheduleSync(after: syncAfter)
    }

    // MARK: the operations, applied to any copy of the record

    static func apply(_ op: JSON, to d: inout JSON, today: String) {
        ensureDay(&d, today: today)
        var day = dict(d["day"])
        var items = list(day["items"])
        switch str(op["type"]) {
        case "add":
            let item = dict(op["item"]), id = str(item["id"])
            let tombs = dict(d["tombs"])
            guard !id.isEmpty, tombs["item:\(id)"] == nil, !items.contains(where: { str($0["id"]) == id }) else { return }
            items.append(item); day["items"] = items; d["day"] = day
            rememberUse(item, in: &d)
        case "delete":
            let id = str(op["id"])
            items.removeAll { str($0["id"]) == id }
            day["items"] = items; d["day"] = day
            var tombs = dict(d["tombs"])
            tombs["item:\(id)"] = op["at"] ?? nowMs()
            let cutoff = Double(nowMs()) - 60 * 864e5
            for (k, t) in tombs where (num(t) ?? 0) < cutoff { tombs.removeValue(forKey: k) }
            d["tombs"] = tombs
        case "edit":
            let id = str(op["id"])
            guard let i = items.firstIndex(where: { str($0["id"]) == id }) else { return }
            items[i]["kcal"] = op["kcal"]
            items[i]["shareLabel"] = op["shareLabel"]
            if let m = op["meal"] as? String { items[i]["meal"] = m }
            day["items"] = items; d["day"] = day
        case "fav":
            var favs = dict(d["favs"])
            let key = str(op["key"]), on = op["on"] as? Bool ?? false
            favs[key] = ["on": on, "at": str(op["at"])] as JSON
            d["favs"] = favs
            if on, let r = op["recent"] as? JSON {
                var recent = list(d["recent"])
                if !recent.contains(where: { str($0["key"]) == key }) { recent.insert(r, at: 0); d["recent"] = recent }
            }
        default:
            applyWorkoutOp(op, to: &d, today: today)
        }
    }

    /// A new day starts clean; the old one is filed in History first (the web app's archiveDay).
    static func ensureDay(_ d: inout JSON, today: String) {
        let day = dict(d["day"])
        if str(day["date"]) == today { return }
        let history = list(d["history"])
        let date = str(day["date"])
        if !date.isEmpty, !(list(day["items"]).isEmpty && list(day["workouts"]).isEmpty), !history.contains(where: { str($0["date"]) == date }) {
            archive(day, in: &d)
        }
        d["day"] = ["date": today, "items": [Any](), "workouts": [Any]()] as JSON
    }

    static func archive(_ day: JSON, in d: inout JSON) {
        let items = list(day["items"]), workouts = list(day["workouts"]), date = str(day["date"])
        let burned = workouts.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let budget = baseBudget(date, in: d) + ((d["eatBack"] as? Bool ?? false) ? burned : 0)
        var p = 0.0, c = 0.0, f = 0.0
        for it in items { if let m = FoodMath.macros(it, kcal: num(it["kcal"]) ?? 0) { p += m.p; c += m.c; f += m.f } }
        let filedItems: [JSON] = items.map { it in
            var b = FoodMath.basisOf(it)
            b["kcal"] = it["kcal"] ?? 0
            b["shareLabel"] = it["shareLabel"] ?? ""
            b["addedAt"] = it["addedAt"] ?? NSNull()
            b["meal"] = it["meal"] ?? NSNull()
            return b
        }
        let filedWorkouts: [JSON] = workouts.map { w in
            ["name": w["name"] ?? "", "type": w["type"] ?? NSNull(), "effort": w["effort"] ?? NSNull(),
             "minutes": w["minutes"] ?? 0, "kcal": w["kcal"] ?? 0, "lifts": w["lifts"] ?? [Any]()]
        }
        let entry: JSON = ["date": date, "budget": budget, "kcal": items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) },
                           "items": filedItems, "p": Int(p.rounded()), "c": Int(c.rounded()), "f": Int(f.rounded()),
                           "burned": burned, "workouts": filedWorkouts]
        var history = list(d["history"])
        history.insert(entry, at: 0)
        d["history"] = Array(history.prefix(400))
    }

    /// Quick add learns from what you add (the web app's rememberRecent, preset and meal counts).
    static func rememberUse(_ item: JSON, in d: inout JSON) {
        let source = str(item["source"]), name = str(item["name"])
        if source == "quick" {
            var uses = dict(d["presetUses"]); uses[name] = Int(num(uses[name]) ?? 0) + 1; d["presetUses"] = uses
            return
        }
        if source == "meal" {
            var meals = list(d["meals"])
            if let i = meals.firstIndex(where: { str($0["id"]) == str(item["mealId"]) }) {
                meals[i]["uses"] = Int(num(meals[i]["uses"]) ?? 0) + 1
                meals[i]["lastUsed"] = ISO.now()
                d["meals"] = meals
            }
            return
        }
        let key = (name + "|" + str(item["brand"])).lowercased()
        var recent = list(d["recent"])
        let old = recent.first { str($0["key"]) == key }
        recent.removeAll { str($0["key"]) == key }
        recent.insert(["key": key, "basis": FoodMath.basisOf(item), "lastKcal": item["kcal"] ?? 0, "lastShareLabel": item["shareLabel"] ?? "",
                       "lastUsed": ISO.now(), "uses": Int(num(old?["uses"]) ?? 0) + 1] as JSON, at: 0)
        let favs = dict(d["favs"])
        var room = 15
        recent = recent.filter { r in
            if (dict(favs[str(r["key"])])["on"] as? Bool) == true { return true }
            room -= 1; return room >= 0
        }
        d["recent"] = recent
    }

    // MARK: sync

    func scheduleSync(after seconds: Double = 0.6) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard Supabase.shared.session != nil else { return }
        if syncing { scheduleSync(after: 1); return }
        syncing = true
        defer { syncing = false }
        do {
            let ops = pending
            if var base = try await Supabase.shared.pullDoc() {
                if ops.isEmpty {
                    if num(base["updatedAt"]) != num(doc["updatedAt"]) { doc = base; persist() }
                } else {
                    for op in ops { Self.apply(op, to: &base, today: today) }
                    base["updatedAt"] = nowMs()
                    try await Supabase.shared.pushDoc(base)
                    finish(sent: ops.count, base: base)
                    await publishDay()
                }
            } else {
                // a brand-new account: start its record from what's here
                var base = doc
                Self.ensureDay(&base, today: today)
                base["updatedAt"] = nowMs()
                try await Supabase.shared.pushDoc(base)
                finish(sent: ops.count, base: base)
            }
            syncError = nil
            lastSynced = Date()
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// After an upload: the record is what was sent, plus anything added while it was on its way.
    private func finish(sent: Int, base: JSON) {
        let later = Array(pending.dropFirst(sent))
        var d = base
        for op in later { Self.apply(op, to: &d, today: today) }
        doc = d
        pending = later
        persist()
    }

    /// What friends see of today (the web app's publishDay).
    func publishDay() async {
        guard (doc["shareDay"] as? Bool) ?? true else { return }
        var items: [JSON] = todayItems.map { it -> JSON in ["name": str(it["name"]), "kcal": it["kcal"] ?? 0, "addedAt": it["addedAt"] ?? NSNull(), "meal": Meals.of(it)] }
        items += todayWorkouts.map { w -> JSON in ["name": "Workout: \(str(w["name"])), \(Int(num(w["minutes"]) ?? 0)) min", "kcal": -Int((num(w["kcal"]) ?? 0).rounded())] }
        try? await Supabase.shared.publishDay(["day": today, "budget": budgetToday, "kcal": eaten, "items": items])
    }

    /// Signing out keeps nothing of this account on the phone.
    func reset() {
        syncTask?.cancel()
        doc = [:]; pending = []; syncError = nil; lastSynced = nil
        persist()
    }

    // MARK: disk

    private func persist() {
        write(doc, "doc.json")
        write(pending, "pending.json")
    }
    private func write(_ obj: Any, _ name: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? d.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
    private static func read(_ url: URL) -> Any? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
}
