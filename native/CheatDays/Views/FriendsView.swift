import SwiftUI

/// Friends: each friend's day as a card (tap for what they had), the week as dots, requests, and the feed.
struct FriendsView: View {
    @State private var seg = 0
    @State private var open: Set<String> = []
    @State private var adding = false
    private var model: Friends { Friends.shared }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $seg) { Text("People").tag(0); Text("Feed").tag(1) }
                    .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
                if seg == 0 { people } else { WebScreen(view: "friends", opts: ["seg": "feed"]) }
            }
            .background(Theme.bg)
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("Add a friend")
                }
            }
            .sheet(isPresented: $adding) { AddFriendSheet().presentationDetents([.medium]) }
            .task { await model.load() }
        }
    }

    private var people: some View {
        List {
            if !model.requests.isEmpty {
                Section("Requests") {
                    ForEach(model.requests) { r in
                        HStack {
                            Text("\(r.name) wants to be friends").font(.subheadline)
                            Spacer()
                            Button("Accept") { Task { await model.accept(r) } }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                }
            }
            if model.people.isEmpty && !model.loading {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No friends yet").font(.title3.bold())
                        Text("Swap friend codes with someone and you'll see each other's day. Tap the person icon at the top.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            ForEach(model.people) { p in
                Section {
                    DisclosureGroup(isExpanded: Binding(get: { open.contains(p.id) }, set: { now in if now { open.insert(p.id) } else { open.remove(p.id) } })) {
                        let food = p.food
                        if food.isEmpty { Text("Nothing shared today yet.").font(.footnote).foregroundStyle(.secondary) }
                        ForEach(Meals.all, id: \.self) { meal in
                            let its = food.filter { (str($0["meal"]).isEmpty ? Meals.of($0) : str($0["meal"])) == meal }
                            if !its.isEmpty {
                                Text(meal.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                ForEach(its.indices, id: \.self) { i in
                                    HStack {
                                        FoodDot(name: str(its[i]["name"]), size: 28)
                                        Text(str(its[i]["name"])).font(.subheadline)
                                        Spacer()
                                        Text(Fmt.int(num(its[i]["kcal"]) ?? 0)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                    }
                                }
                            }
                        }
                    } label: { card(p) }
                    .tint(.secondary)
                }
            }
            let leaders = model.people.filter { $0.streak > 0 }.sorted { $0.streak > $1.streak }.prefix(5)
            if !leaders.isEmpty {
                Section("Streaks") {
                    ForEach(Array(leaders.enumerated()), id: \.element.id) { pair in
                        let i = pair.offset, p = pair.element
                        HStack {
                            Text("\(i + 1)").font(.headline).foregroundStyle(i == 0 ? Theme.accent : .secondary).frame(width: 22)
                            Text(p.name)
                            Spacer()
                            Label("\(p.streak) days", systemImage: "flame.fill").font(.subheadline).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    WebScreen(view: "friends", opts: ["seg": "friends"], pushed: true).navigationTitle("Friends").navigationBarTitleDisplayMode(.inline)
                } label: { Label("Shared meals, sending food and more", systemImage: "ellipsis.circle") }
            } footer: {
                if let e = model.error { Text("Couldn't load friends: \(e)") }
                else { Text("Your code is \(model.myCode). Friends see what you choose to share.") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private func card(_ p: Friends.Person) -> some View {
        let day = p.current
        let kcal = num(day?["kcal"]) ?? 0, budget = pos(day?["budget"]) ?? 0
        let over = budget > 0 && kcal > budget * 1.1, near = budget > 0 && !over && kcal > budget
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(String(p.name.prefix(1)).uppercased()).font(.headline.weight(.heavy)).foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42).background(Theme.hero, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.headline)
                    Text(p.isActive ? (open.contains(p.id) ? "Their day so far" : "Tap to see what they had") : "Nothing logged today yet")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if p.isActive {
                    (Text(Fmt.int(kcal)).foregroundStyle(over || near ? Theme.warn : Theme.accent) + Text(" / \(Fmt.int(budget))").foregroundStyle(.secondary))
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                }
            }
            if p.isActive && budget > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(over || near ? Theme.warn : Theme.accent).frame(width: g.size.width * min(1, kcal / budget))
                    }
                }
                .frame(height: 7)
            }
            HStack {
                HStack(spacing: 5) {
                    ForEach(Array(p.week.enumerated()), id: \.offset) { pair in
                        let v = pair.element
                        Circle().fill(v == 1 ? Theme.accent : v == 2 ? Theme.warn : v == 3 ? Color.red.opacity(0.75) : Theme.track).frame(width: 10, height: 10)
                    }
                }
                if p.streak > 1 { Label("\(p.streak)", systemImage: "flame.fill").font(.caption.weight(.bold)).foregroundStyle(.orange) }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var message: String?
    @State private var busy = false
    private var model: Friends { Friends.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(model.myCode.isEmpty ? "…" : model.myCode).font(.title2.weight(.heavy)).monospaced()
                        Spacer()
                        ShareLink(item: "Add me on Cheat Days: my friend code is \(model.myCode)") { Image(systemName: "square.and.arrow.up") }
                    }
                } header: { Text("Your code") } footer: { Text("Send it to a friend, or type theirs below.") }
                Section {
                    TextField("Their code, like DOM-1234", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button(busy ? "Sending…" : "Send request") {
                        busy = true
                        Task { message = await model.add(code: code); busy = false }
                    }
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 4)
                } footer: { if let message { Text(message) } }
            }
            .navigationTitle("Add a friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
