import SwiftUI

/// Family budgets (helper only), for the people you've invited who said yes: set their daily budget for the week, and
/// fix or remove a food on their day. Their app picks the change up the next time it opens.
struct FamilyView: View {
    @State private var overrides: [String: JSON] = [:]
    @State private var editing: Friends.Person?
    @State private var fixing: (person: Friends.Person, item: JSON)?
    @State private var fixText = ""
    @State private var note: String?
    @State private var inviting = false
    private var friends: Friends { Friends.shared }
    private var family: Family { Family.shared }
    private var api: Supabase { Supabase.shared }

    var body: some View {
        List {
            Section {
                Button { inviting = true } label: { Label("Invite someone", systemImage: "person.badge.plus") }
                ForEach(friends.people.filter { family.isAsked($0.id) }) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text("Waiting for them to allow").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Cancel", role: .destructive) { if let l = family.mine.first(where: { $0.member == p.id }) { Task { await family.remove(l) } } } }
                }
            } footer: { Text("Only people who say yes are here. They can stop it any time in their Settings.") }
            ForEach(friends.people.filter { family.isFamily($0.id) }) { p in
                Section {
                    Button { editing = p } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.headline)
                                Text(summary(overrides[p.id])).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Set budget").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(p.food.indices, id: \.self) { i in
                        let it = p.food[i]
                        Button { fixText = String(Int(num(it["kcal"]) ?? 0)); fixing = (p, it) } label: {
                            HStack {
                                Text(str(it["name"])).font(.subheadline)
                                Spacer()
                                Text(Fmt.int(num(it["kcal"]) ?? 0)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: { if !p.food.isEmpty { Text("Tap a food to change its calories or remove it.") } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Family budgets")
        .navigationBarTitleDisplayMode(.inline)
        .task { if friends.people.isEmpty { await friends.load() }; await family.load(); await loadOverrides() }
        .refreshable { await friends.load(); await family.load(); await loadOverrides() }
        .confirmationDialog("Invite to your family", isPresented: $inviting, titleVisibility: .visible) {
            ForEach(friends.people.filter { p in !family.mine.contains { $0.member == p.id } }) { p in
                Button(p.name) {
                    Task {
                        do { try await family.ask(p.id); flash("Asked \(p.name). They'll see it on their Today.") }
                        catch { flash("Couldn't ask: \(error.localizedDescription)") }
                    }
                }
            }
        } message: { Text("They choose whether to allow it. Once they do, you can set their budget and fix foods on their day.") }
        .sheet(item: $editing) { p in FamilyBudgetSheet(person: p, current: overrides[p.id]) { msg in editing = nil; if let msg { flash(msg) }; Task { await loadOverrides() } } }
        .alert("Change \(str(fixing?.item["name"]))", isPresented: Binding(get: { fixing != nil }, set: { if !$0 { fixing = nil } })) {
            TextField("kcal", text: $fixText).keyboardType(.numberPad)
            Button("Save") { if let f = fixing { Task { await fix(f.person, f.item, kcal: Double(fixText) ?? 0) } } }
            Button("Remove it", role: .destructive) { if let f = fixing { Task { await fix(f.person, f.item, kcal: 0) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their app updates next time it opens.") }
        .overlay(alignment: .bottom) {
            if let note { Text(note).font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 20).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
    }

    private func summary(_ o: JSON?) -> String {
        guard let o, let b = pos(o["budget"]) else { return "Their own budget" }
        let days = dict(o["days"])
        if days.isEmpty { return "You set \(Fmt.int(b)) a day" }
        let names = Calendar.current.shortWeekdaySymbols
        let odd = [1, 2, 3, 4, 5, 6, 0].compactMap { d -> String? in
            guard let v = pos(days[String(d)]), v != b else { return nil }
            return "\(names[d]) \(Fmt.int(v))"
        }
        return "You set \(Fmt.int(b)) most days" + (odd.isEmpty ? "" : ", " + odd.joined(separator: ", "))
    }

    private func loadOverrides() async {
        let ids = friends.people.map(\.id).joined(separator: ",")
        guard !ids.isEmpty, let d = try? await api.rest("/rest/v1/budget_overrides?user_id=in.(\(ids))&select=*"),
              let rows = (try? JSONSerialization.jsonObject(with: d)) as? [JSON] else { return }
        overrides = Dictionary(rows.map { (str($0["user_id"]), $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func fix(_ p: Friends.Person, _ it: JSON, kcal: Double) async {
        guard let me = api.userId, kcal >= 0, kcal <= 5000 else { return }
        var row: JSON = ["user_id": p.id, "set_by": me, "day": str(p.current?["day"]).isEmpty ? DayKey.string(Date()) : str(p.current?["day"]),
                         "item_name": str(it["name"]), "old_kcal": Int(num(it["kcal"]) ?? 0), "remove": kcal <= 0]
        if kcal > 0 { row["new_kcal"] = Int(kcal.rounded()) } else { row["new_kcal"] = NSNull() }
        do {
            _ = try await api.rest("/rest/v1/helper_edits", method: "POST", body: [row])
            flash(kcal > 0 ? "\(str(it["name"])) will be \(Fmt.int(kcal)) kcal for \(p.name)" : "\(str(it["name"])) will be removed for \(p.name)")
        } catch { flash("Couldn't change it: \(error.localizedDescription)") }
        fixing = nil
    }

    private func flash(_ t: String) {
        withAnimation { note = t }
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); withAnimation { if note == t { note = nil } } }
    }
}

/// One person's budget for the week: the same every day, or different on some days.
private struct FamilyBudgetSheet: View {
    let person: Friends.Person
    let current: JSON?
    var done: (String?) -> Void
    @State private var base = 1600.0
    @State private var perDay = false
    @State private var days: [Int: Double] = [:]
    @State private var busy = false
    @State private var problem: String?
    private let order = [1, 2, 3, 4, 5, 6, 0]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $base, in: 1000...5000, step: 50) { HStack { Text("Most days"); Spacer(); Text(Fmt.int(base)).font(.headline.monospacedDigit()) } }
                    Toggle("Different on some days", isOn: $perDay.animation())
                    if perDay {
                        ForEach(order, id: \.self) { d in
                            Stepper(value: Binding(get: { days[d] ?? base }, set: { days[d] = $0 }), in: 1000...6000, step: 50) {
                                HStack { Text(Calendar.current.weekdaySymbols[d]); Spacer(); Text(Fmt.int(days[d] ?? base)).monospacedDigit().foregroundStyle((days[d] ?? base) != base ? Theme.warn : .primary) }
                            }
                        }
                    }
                } footer: { Text("\(person.name)'s app uses this from the next time it opens. They can still see it in their Plan and budget.") }
                if current != nil {
                    Section { Button("Stop setting their budget", role: .destructive) { Task { await stop() } } }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
            }
            .keyboardDone()
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .topBarTrailing) { Button(busy ? "Saving…" : "Save") { Task { await save() } }.fontWeight(.bold).disabled(busy) }
            }
            .onAppear {
                if let c = current, let b = pos(c["budget"]) { base = b }
                for (k, v) in dict(current?["days"]) { if let i = Int(k), let n = pos(v) { days[i] = n } }
                perDay = days.values.contains { $0 != base }
            }
        }
    }

    private func save() async {
        guard let me = Supabase.shared.userId else { return }
        busy = true; defer { busy = false }
        var row: JSON = ["user_id": person.id, "budget": Int(base), "set_by": me, "updated_at": ISO.now()]
        if perDay { var d = JSON(); for k in order { d[String(k)] = Int(days[k] ?? base) }; row["days"] = d } else { row["days"] = NSNull() }
        do {
            _ = try await Supabase.shared.rest("/rest/v1/budget_overrides", method: "POST", body: [row], prefer: "resolution=merge-duplicates")
            done("\(person.name)'s budget is set")
        } catch { problem = "Couldn't save it: \(error.localizedDescription)" }
    }

    private func stop() async {
        do {
            _ = try await Supabase.shared.rest("/rest/v1/budget_overrides?user_id=eq.\(person.id)", method: "DELETE")
            done("No longer setting \(person.name)'s budget")
        } catch { problem = "Couldn't change it: \(error.localizedDescription)" }
    }
}
