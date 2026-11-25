import SwiftUI

/// Group chats (25 Nov, design/group-chats-mockup.html): two faces stacked for a group, making one, its info page
/// (rename, add people, mute, leave, its invite link), and joining by an invite.

/// A group's picture: the first two other people's faces, one over the other.
struct GroupFace: View {
    let group: String
    var size: CGFloat = 52
    private var messages: Messages { Messages.shared }
    var body: some View {
        let others: [String] = messages.people(in: group).map { str($0["user_id"]) }.filter { $0 != messages.me }
        let a: String = others.first ?? messages.me
        let b: String = others.dropFirst().first ?? messages.me
        let small: CGFloat = size * 0.68
        ZStack {
            Avatar(id: a, size: small).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Avatar(id: b, size: small)
                .overlay(Circle().stroke(Theme.bg, lineWidth: 2.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The people a group can have: friends, and people I follow who follow me back.
@MainActor enum GroupPeople {
    static func choices() -> [(id: String, name: String)] {
        var out: [(id: String, name: String)] = Friends.shared.people.map { (id: $0.id, name: Profiles.shared.all[$0.id]?.name ?? $0.name) }
        let f = Follows.shared
        for id in f.following where f.followsMe(id) && !out.contains(where: { $0.id == id }) {
            out.append((id: id, name: Feed.shared.name(id)))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A new group: its name, then who's in it. Create makes it and opens its chat.
struct NewGroupSheet: View {
    var made: (String) -> Void
    @State private var name = ""
    @State private var picked: [String] = []
    @State private var q = ""
    @State private var making = false
    @State private var joining = false
    @Environment(\.dismiss) private var dismiss
    private var messages: Messages { Messages.shared }

    var body: some View {
        let all = GroupPeople.choices().filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || Profiles.shared.handle($0.id).localizedCaseInsensitiveContains(q) }
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name).font(.body.weight(.semibold))
                }
                if !picked.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(picked, id: \.self) { (id: String) in
                                Button { picked.removeAll { $0 == id } } label: {
                                    Text("\(Feed.shared.name(id)) ✕").font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 10).padding(.vertical, 5).background(Theme.hero, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                Section {
                    if all.isEmpty {
                        Text("Add friends first, or follow people who follow you back. Or join a group with an invite.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(all, id: \.id) { p in
                        Button {
                            if picked.contains(p.id) { picked.removeAll { $0 == p.id } } else { picked.append(p.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(id: p.id, size: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(.subheadline.weight(.bold))
                                    if !Profiles.shared.handle(p.id).isEmpty { Text(Profiles.shared.handle(p.id)).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: picked.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(picked.contains(p.id) ? Theme.accent : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button { joining = true } label: { Label("Join with an invite", systemImage: "link") }
                }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle("New group").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    making = true
                    Task {
                        let id = await messages.makeGroup(name.trimmingCharacters(in: .whitespacesAndNewlines), people: picked)
                        making = false
                        if let id { made(id) }
                    }
                } label: {
                    Text(making ? "Making it…" : "Create group · \(picked.count + 1) people")
                        .font(.headline).foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Theme.accent.opacity(canMake ? 1 : 0.4), in: Capsule())
                }
                .buttonStyle(.plain).disabled(!canMake || making)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .alert("Couldn't make it", isPresented: Binding(get: { messages.error != nil && !making }, set: { if !$0 { messages.error = nil } })) {
                Button("OK", role: .cancel) { messages.error = nil }
            } message: { Text(messages.error ?? "") }
            .sheet(isPresented: $joining) { JoinGroupSheet { id in joining = false; made(id) }.presentationDetents([.medium]) }
        }
    }

    private var canMake: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !picked.isEmpty }
}

/// Joining a group by its invite: the link or just its code.
struct JoinGroupSheet: View {
    var joined: (String) -> Void
    @State private var code = ""
    @State private var working = false
    @Environment(\.dismiss) private var dismiss
    private var messages: Messages { Messages.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite link or code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text(messages.error ?? "Whoever made the group can share its invite from the group's info.") }
                Button(working ? "Joining…" : "Join") {
                    working = true
                    Task { let id = await messages.join(code); working = false; if let id { joined(id) } }
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            .navigationTitle("Join a group").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { messages.error = nil }
        }
    }
}

/// A group's info: who's in it (whoever made it can take someone out), add people, its invite, rename, mute, leave.
struct GroupInfoView: View {
    let group: String
    var left: () -> Void = {}
    @State private var adding = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmLeave = false
    private var messages: Messages { Messages.shared }

    var body: some View {
        let g: JSON = messages.group(group) ?? [:]
        let people: [JSON] = messages.people(in: group)
        let maker: String = str(g["created_by"])
        let muted: Bool = messages.myRow(in: group)?["muted"] as? Bool ?? false
        List {
            Section {
                ForEach(people.map { str($0["user_id"]) }, id: \.self) { (id: String) in
                    NavigationLink { ProfileView(id: id) } label: {
                        HStack(spacing: 12) {
                            Avatar(id: id, size: 36)
                            Text(id == messages.me ? "You" : Feed.shared.name(id)).font(.body.weight(.semibold))
                            Spacer()
                            if id == maker { Text("made it").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .swipeActions {
                        if maker == messages.me && id != messages.me {
                            Button("Remove", role: .destructive) { Task { await messages.remove(id, from: group) } }
                        }
                    }
                }
                Button { adding = true } label: { Label("Add people", systemImage: "plus") }
            } header: { Text("\(people.count) \(people.count == 1 ? "person" : "people")") }
            Section {
                ShareLink(item: Messages.inviteLink(g), message: Text("Join \(str(g["name"])) on Cheat Days")) {
                    Label("Share invite link", systemImage: "link")
                }
                Text("Or the code: \(str(g["invite"]))").font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            } footer: { Text("Anyone with the link or code can join. They open it on their iPhone with Cheat Days installed, or paste the code in New group › Join with an invite.") }
            Section {
                Toggle(isOn: Binding(get: { muted }, set: { v in Task { await messages.setMuted(group, v) } })) { Label("Mute", systemImage: "bell.slash") }
                Button(role: .destructive) { confirmLeave = true } label: { Text("Leave group") }
            }
        }
        .navigationTitle(str(g["name"])).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { newName = str(g["name"]); renaming = true } } }
        .alert("Rename group", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { Task { await messages.rename(group, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Leave \(str(g["name"]))?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await messages.remove(messages.me, from: group); left() } }
        } message: { Text("You won't get its messages. Someone in it can add you back.") }
        .sheet(isPresented: $adding) { AddToGroupSheet(group: group).presentationDetents([.medium, .large]) }
        .task { await messages.loadGroups() }
    }
}

/// People to add to a group: the ones who can be, not already in it.
struct AddToGroupSheet: View {
    let group: String
    @State private var picked: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    private var messages: Messages { Messages.shared }

    var body: some View {
        let inIt = Set(messages.people(in: group).map { str($0["user_id"]) })
        let all = GroupPeople.choices().filter { !inIt.contains($0.id) }
        NavigationStack {
            List {
                if all.isEmpty { Text("Everyone you can add is in it. Share the invite link for anyone else.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(all, id: \.id) { p in
                    Button { if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) } } label: {
                        HStack(spacing: 12) {
                            Avatar(id: p.id, size: 40)
                            Text(p.name).font(.subheadline.weight(.bold))
                            Spacer()
                            Image(systemName: picked.contains(p.id) ? "checkmark.circle.fill" : "circle").font(.title3)
                                .foregroundStyle(picked.contains(p.id) ? Theme.accent : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add people").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await messages.add(Array(picked), to: group); dismiss() } }.disabled(picked.isEmpty)
                }
            }
        }
    }
}
