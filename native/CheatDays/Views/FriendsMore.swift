import SwiftUI

/// Food friends have sent you, waiting on Today to add in one tap (the website's inbox).
@Observable @MainActor
final class Inbox {
    static let shared = Inbox()
    private(set) var items: [JSON] = []
    private(set) var names: [String: String] = [:]
    private var at = Date.distantPast
    private var api: Supabase { Supabase.shared }

    func refresh(force: Bool = false) async {
        guard let me = api.userId, force || Date().timeIntervalSince(at) > 60 else { return }
        at = Date()
        guard let d = try? await api.rest("/rest/v1/sends?to_user=eq.\(me)&status=eq.new&select=*&order=created_at.desc&limit=20"),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] else { return }
        items = rows
        let who = Set(rows.map { str($0["from_user"]) }).filter { names[$0] == nil }
        if !who.isEmpty, let p = try? await api.rest("/rest/v1/profiles?user_id=in.(\(who.joined(separator: ",")))&select=user_id,display_name"),
           let people = (try? JSONSerialization.jsonObject(with: p)) as? [JSON] {
            for x in people { names[str(x["user_id"])] = str(x["display_name"]) }
        }
    }

    func name(_ id: String) -> String { names[id].flatMap { $0.isEmpty ? nil : $0 } ?? "A friend" }

    func settle(_ x: JSON, _ status: String) {
        items.removeAll { str($0["id"]) == str(x["id"]) }
        guard let me = api.userId else { return }
        Task { _ = try? await api.rest("/rest/v1/sends?id=eq.\(str(x["id"]))&to_user=eq.\(me)", method: "PATCH", body: ["status": status]) }
    }

    func add(_ x: JSON) {
        var b = dict(x["payload"])
        if b.isEmpty { b = ["name": x["name"] ?? "", "kcalPerServing": x["kcal"] ?? 0, "unitLabel": "portion"] }
        if str(b["name"]).isEmpty { b["name"] = x["name"] ?? "" }
        Store.shared.add(b, kcal: num(x["kcal"]) ?? 0, meal: Meals.now)
        settle(x, "added")
    }
}

/// Friends, more: send one of today's foods to a friend, share your meals, take meals friends share, and remove a friend.
struct FriendsMore: View {
    @State private var shared: [JSON] = []
    @State private var sending: Friends.Person?
    @State private var confirmRemove: Friends.Person?
    @State private var note: String?
    @State private var taking: JSON?
    private var store: Store { Store.shared }
    private var friends: Friends { Friends.shared }
    private var api: Supabase { Supabase.shared }

    var body: some View {
        let mine = Set((store.doc["sharedMealIds"] as? [String]) ?? [])
        let meals = list(store.doc["meals"]).filter { $0["saved"] as? Bool == true }
        let theirs = shared.filter { str($0["owner"]) != api.userId }
        List {
            Section {
                ForEach(friends.people) { p in
                    HStack {
                        Text(p.name).font(.body.weight(.semibold))
                        Spacer()
                        Button { sending = p } label: { Label("Send food", systemImage: "paperplane.fill") }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    }
                    .swipeActions { Button(role: .destructive) { confirmRemove = p } label: { Label("Remove", systemImage: "person.badge.minus") } }
                }
                if friends.people.isEmpty { Text("No friends yet.").foregroundStyle(.secondary) }
            } header: { Text("Your friends") } footer: { Text("Send one of today's foods and they can add it with one tap. Swipe left to remove a friend.") }
            Section {
                if meals.isEmpty { Text("Save a meal first, then share it here.").foregroundStyle(.secondary) }
                ForEach(meals.indices, id: \.self) { i in
                    let m = meals[i], id = str(m["id"])
                    Toggle(isOn: Binding(get: { mine.contains(id) }, set: { on in Task { await share(m, on) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(str(m["name"]))
                            Text("\(Fmt.int(num(store.mealBasis(m)["kcalPerServing"]) ?? 0)) kcal a portion").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Share your meals") } footer: { Text("Friends can save a shared meal, ingredients and all.") }
            Section("Meals your friends share") {
                if theirs.isEmpty { Text("Nothing shared yet.").foregroundStyle(.secondary) }
                ForEach(theirs.indices, id: \.self) { i in
                    let m = theirs[i]
                    Button { taking = m } label: {
                        HStack(spacing: 12) {
                            FoodDot(name: str(m["name"]), size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(str(m["name"])).font(.subheadline.weight(.semibold))
                                Text("From \(friends.people.first { $0.id == str(m["owner"]) }?.name ?? "a friend") · \(Fmt.int(num(m["kcal_per_portion"]) ?? 0)) kcal a portion").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadShared(); if friends.people.isEmpty { await friends.load() } }
        .refreshable { await loadShared(); await friends.load() }
        .overlay(alignment: .bottom) {
            if let note { Text(note).font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 20).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .confirmationDialog("Send one of today's foods", isPresented: Binding(get: { sending != nil }, set: { if !$0 { sending = nil } }), titleVisibility: .visible) {
            ForEach(store.todayItems.indices, id: \.self) { i in
                let it = store.todayItems[i]
                Button("\(str(it["name"])) · \(Int(num(it["kcal"]) ?? 0)) kcal") { if let p = sending { Task { await send(it, to: p) } } }
            }
        } message: { Text(store.todayItems.isEmpty ? "Log something first, then send it from here." : "They'll see it on their Today and can add it in one tap.") }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "this friend")? You'll stop seeing each other's days.", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let p = confirmRemove { Task { _ = try? await api.rest("/rest/v1/friendships?id=eq.\(p.friendship)", method: "DELETE"); await friends.load() } } }
        }
        .sheet(item: Binding(get: { taking.map { SharedBox(meal: $0) } }, set: { taking = $0?.meal })) { b in
            PostRecipeSheet(post: ["id": b.meal["meal_id"] ?? "", "kind": "meal", "name": b.meal["name"] ?? "", "owner": b.meal["owner"] ?? "", "kcal": b.meal["kcal_per_portion"] ?? 0,
                                   "payload": ["name": b.meal["name"] ?? "", "portions": b.meal["portions"] ?? 1, "items": b.meal["items"] ?? [Any](), "steps": [Any]()] as JSON])
        }
    }

    private func loadShared() async {
        if let d = try? await api.rest("/rest/v1/shared_meals?select=*&order=updated_at.desc"), let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] { shared = rows }
    }

    private func share(_ m: JSON, _ on: Bool) async {
        guard let me = api.userId else { return }
        let id = str(m["id"])
        do {
            if on {
                let b = store.mealBasis(m)
                _ = try await api.rest("/rest/v1/shared_meals?on_conflict=owner,meal_id", method: "POST",
                                       body: [["owner": me, "meal_id": id, "name": m["name"] ?? "", "portions": m["portions"] ?? 1, "kcal_per_portion": Int((num(b["kcalPerServing"]) ?? 0).rounded()), "items": m["items"] ?? [Any](), "updated_at": ISO.now()]],
                                       prefer: "resolution=merge-duplicates")
            } else {
                _ = try await api.rest("/rest/v1/shared_meals?owner=eq.\(me)&meal_id=eq.\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)", method: "DELETE")
            }
            store.perform(["type": "shareMeal", "id": id, "on": on])
            flash(on ? "Shared with your friends" : "No longer shared")
        } catch { flash("Couldn't change that: \(error.localizedDescription)") }
    }

    private func send(_ it: JSON, to p: Friends.Person) async {
        guard let me = api.userId else { return }
        var row: JSON = ["from_user": me, "to_user": p.id, "name": it["name"] ?? "", "kcal": Int((num(it["kcal"]) ?? 0).rounded()),
                         "unit": str(it["unit"]).isEmpty ? "g" : str(it["unit"]), "payload": FoodMath.basisOf(it)]
        row["grams"] = num(it["grams"]).map { Int($0.rounded()) as Any } ?? NSNull()
        if str(it["photo"]).hasPrefix("http") { row["photo"] = str(it["photo"]) } else { row["photo"] = NSNull() }
        do {
            _ = try await api.rest("/rest/v1/sends", method: "POST", body: [row])
            _ = try? await api.call("/functions/v1/push", body: ["action": "notify", "to": p.id, "kind": "send", "text": str(it["name"])])
            store.perform(["type": "bump", "key": "sendCount"], syncAfter: 3)
            flash("Sent \(str(it["name"])) to \(p.name)")
        } catch { flash("Couldn't send: \(error.localizedDescription)") }
    }

    private func flash(_ t: String) {
        withAnimation { note = t }
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); withAnimation { if note == t { note = nil } } }
    }
}

private struct SharedBox: Identifiable { let meal: JSON; var id: String { str(meal["owner"]) + str(meal["meal_id"]) } }
