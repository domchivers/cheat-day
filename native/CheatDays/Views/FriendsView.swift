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
                if seg == 0 { people } else { FeedView() }
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

    /// Cards in a scroll view rather than a list: an opened card grows downwards with its corners intact, and the ones below slide down.
    private var people: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !model.requests.isEmpty {
                    box {
                        Eyebrow(text: "Requests")
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
                    box {
                        Text("No friends yet").font(.title3.bold())
                        Text("Swap friend codes with someone and you'll see each other's day. Tap the person icon at the top.").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.people) { p in friendCard(p) }
                let leaders = model.people.filter { $0.streak > 0 }.sorted { $0.streak > $1.streak }.prefix(5)
                if !leaders.isEmpty {
                    box {
                        Eyebrow(text: "Streaks")
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
                NavigationLink {
                    WebScreen(view: "friends", opts: ["seg": "friends"], pushed: true).navigationTitle("Friends").navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Label("Shared meals, sending food and more", systemImage: "ellipsis.circle")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                Group {
                    if let e = model.error { Text("Couldn't load friends: \(e)") }
                    else { Text("Your code is \(model.myCode). Friends see what you choose to share.") }
                }
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 100)
        }
        .refreshable { await model.load() }
    }

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func friendCard(_ p: Friends.Person) -> some View {
        let isOpen = open.contains(p.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.35)) { if isOpen { open.remove(p.id) } else { open.insert(p.id) } }
            } label: { card(p) }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.vertical, 4)
                    let food = p.food
                    if food.isEmpty { Text("Nothing shared today yet.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(Meals.all, id: \.self) { meal in
                        let its = food.filter { (str($0["meal"]).isEmpty ? Meals.of($0) : str($0["meal"])) == meal }
                        if !its.isEmpty {
                            Text(meal.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 4)
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
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .offset(y: -10)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open.contains(p.id) ? 180 : 0))
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
