import SwiftUI
import UserNotifications

/// Settings: one short list, like the iPhone's own; each row opens its own page (reminders, sharing, portions, the assistant, data, account).
struct SettingsView: View {
    @State private var lunch = true
    @State private var weighOn = true
    @State private var weighTime = Calendar.current.date(from: DateComponents(hour: 7, minute: 30)) ?? Date()
    @State private var days: Set<Int> = [0]
    @State private var share = true
    @State private var pushNote: String?
    @AppStorage("region") private var region = ""   // the same setting Region reads; this way the picker shows the change
    @State private var allowed = true
    @State private var loaded = false
    @State private var notes = ""
    @State private var newPassword = ""
    @State private var passwordNote: String?
    @State private var confirmSignOut = false
    private var store: Store { Store.shared }
    private let order = [1, 2, 3, 4, 5, 6, 0]
    @AppStorage("dailyTips") private var dailyTips = true

    var body: some View {
        let helpers = Family.shared.helpers.count
        Form {
            Section {
                NavigationLink { page("Account") { accountPage } } label: {
                    HStack(spacing: 12) {
                        Text(String(Supabase.shared.email.prefix(1)).uppercased()).font(.title3.weight(.heavy)).foregroundStyle(.black)
                            .frame(width: 44, height: 44).background(Theme.accent, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Supabase.shared.email).font(.body.weight(.semibold)).lineLimit(1)
                            Text("Account and password").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                NavigationLink { page("Reminders") { remindersPage } } label: {
                    row("🔔", "Reminders", value: "\([lunch, dailyTips, weighOn].filter { $0 }.count) on")
                }
                NavigationLink { page("Friends and sharing") { friendsPage } } label: { row("👥", "Friends and sharing") }
            }
            Section {
                NavigationLink { page("Portion sizes") { portionsPage } } label: {
                    row("🍽️", "Portion sizes", value: Region(rawValue: region)?.label ?? "Automatic")
                }
                NavigationLink { page("Assistant") { assistantPage } } label: { row("✨", "Assistant") }
            }
            Section {
                if helpers > 0 {
                    NavigationLink { page("Family") { familyPage } } label: { row("🏡", "Family", value: "\(helpers) helper\(helpers == 1 ? "" : "s")") }
                }
                NavigationLink { page("Your data") { dataPage } } label: { row("💾", "Your data and backups") }
            }
            Section {
                Button { Tour.shared.pending = true } label: { row("📖", "Show me around") }.foregroundStyle(.primary)
            }
            Section {
                Button("Sign out", role: .destructive) { confirmSignOut = true }.frame(maxWidth: .infinity)
            } footer: {
                Text("Cheat Days \(Bundle.main.shortVersion)\(store.lastSynced.map { " · synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "")")
                    .frame(maxWidth: .infinity).padding(.top, 6)
            }
        }
        .task { await Family.shared.load() }
        .confirmationDialog("Sign out of Cheat Days on this phone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                WebHost.shared.signOut()
                Supabase.shared.signOut()
                store.reset()
            }
        } message: { Text("Everything stays in your account. Sign in again to get it back.") }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let p = store.reminderPrefs
            lunch = p.lunch; weighOn = p.weigh != nil
            if let w = p.weigh { let parts = w.split(separator: ":").compactMap { Int($0) }; weighTime = Calendar.current.date(from: DateComponents(hour: parts.first ?? 7, minute: parts.count > 1 ? parts[1] : 30)) ?? weighTime }
            days = Set(store.weighDays); share = (store.doc["shareDay"] as? Bool) ?? true
            notes = str(store.doc["notes"])
            let s = await UNUserNotificationCenter.current().notificationSettings()
            allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            loaded = true
        }
        .onChange(of: lunch) { _, _ in saveAsking() }
        .onChange(of: weighOn) { _, _ in saveAsking() }
        .onChange(of: weighTime) { _, _ in save() }
        .onChange(of: days) { _, now in if loaded { store.setWeighDays(Array(now)) } }
        .onChange(of: share) { _, now in if loaded { store.setShareDay(now) } }
        .onChange(of: notes) { _, now in if loaded { store.perform(["type": "set", "key": "notes", "value": String(now.prefix(1000))], syncAfter: 3) } }
    }

    /// A row on the main list: the Fluent icon, the name, and what it's set to.
    private func row(_ emoji: String, _ title: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            FluentIcon(emoji: emoji, size: 26)
            Text(title)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary) }
        }
    }

    /// Each row opens one of these: its own short page.
    private func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .keyboardDone()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var remindersPage: some View {
        Section {
            Toggle("Plan each meal (7am, 12pm, 5pm)", isOn: $lunch)
            Toggle("Tips each morning and after meals", isOn: $dailyTips)
            Toggle("Weigh-in reminder", isOn: $weighOn)
            if weighOn { DatePicker("At", selection: $weighTime, displayedComponents: .hourAndMinute) }
            if !allowed {
                Button("Allow notifications") { Task { allowed = await Reminders.ask(); save() } }
            }
        } footer: {
            Text(allowed ? "They're skipped on days you've already logged or weighed." : "Notifications are off for Cheat Days. Allow them to get reminders.")
        }
        Section {
            HStack(spacing: 6) {
                ForEach(order, id: \.self) { d in
                    let on = days.contains(d)
                    Button { if on { if days.count > 1 { days.remove(d) } } else { days.insert(d) } } label: {
                        Text(Calendar.current.veryShortWeekdaySymbols[d]).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity, minHeight: 36)
                            .background(on ? Theme.accent : Color(.tertiarySystemFill), in: Circle())
                            .foregroundStyle(on ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: { Text("Weigh-in days") } footer: { Text("Once a week is plenty. Your plan's check-in uses these too.") }
    }

    @ViewBuilder private var friendsPage: some View {
        Section {
            Toggle("Share my day with friends", isOn: $share)
            Toggle("Notifications from friends", isOn: Binding(get: { Push.on }, set: { v in Task { await Push.setOn(v) } }))
            if Push.on { Button("Send a test notification") { Task { pushNote = await Push.test() } } }
            Toggle("Show my workouts on the feed", isOn: Binding(get: { store.shareWorkouts }, set: { store.perform(["type": "set", "key": "shareWorkouts", "value": $0]) }))
        } footer: { Text("Friends see your calories and what you had today.") }
        .alert("Notifications", isPresented: Binding(get: { pushNote != nil }, set: { if !$0 { pushNote = nil } })) { Button("OK") {} } message: { Text(pushNote ?? "") }
    }

    @ViewBuilder private var portionsPage: some View {
        Section {
            Picker("Portion sizes", selection: $region) {
                Text("Automatic (\(Region.detected.label))").tag("")
                ForEach(Region.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .onChange(of: region) { _, _ in Store.shared.clearCaches() }   // lists worked out with the old sizes
        } footer: { Text("A chicken thigh or a glass of wine isn't the same size everywhere. This sets the usual portions in the food list and for the assistant.") }
    }

    @ViewBuilder private var assistantPage: some View {
        Section {
            Toggle("Use Apple Intelligence for quick jobs", isOn: Binding(get: { OnDevice.allowed }, set: { OnDevice.allowed = $0 }))
                .disabled(!OnDevice.ready)
        } header: { Text("Assistant") } footer: { Text(OnDevice.status + " Photos, recipes and plans always use the online AI.") }
        Section {
            TextField("Vegetarian, no dairy, I train in the mornings…", text: $notes, axis: .vertical).lineLimit(3...6)
        } header: { Text("About you") } footer: { Text("The assistant reads this before every answer.") }
    }

    @ViewBuilder private var dataPage: some View {
        Section {
            ShareLink(item: exportText, preview: SharePreview("Cheat Days data")) { Label("Export my data", systemImage: "square.and.arrow.up") }
            NavigationLink { WebScreen(view: "settings", pushed: true).navigationTitle("Backups").navigationBarTitleDisplayMode(.inline) } label: { Label("Backups and restore", systemImage: "clock.arrow.circlepath") }
        } header: { Text("Your data") } footer: { Text("Everything syncs to your account. Export gives you a copy of it all as a file. Daily backups and restoring stay on the website's page for now.") }
        Section { EmptyView() } footer: { Text("Food icons: Fluent Emoji by Microsoft, MIT licence.") }
    }

    @ViewBuilder private var familyPage: some View {
        Section {
            ForEach(Family.shared.helpers) { l in
                HStack {
                    Text("\(Family.shared.name(l.helper)) can set your budget")
                    Spacer()
                    Button("Stop", role: .destructive) { Task { await Family.shared.remove(l) } }.buttonStyle(.borderless)
                }
            }
        } footer: { Text("They can set your daily budget and fix foods on your day. Stop it and they can't any more.") }
    }

    @ViewBuilder private var accountPage: some View {
        Section {
            LabeledContent("Signed in as", value: Supabase.shared.email)
        }
        Section {
            SecureField("New password (8 or more characters)", text: $newPassword).textContentType(.newPassword)
            if !newPassword.isEmpty {
                Button("Change password") { Task { await changePassword() } }.disabled(newPassword.count < 8)
            }
            if let passwordNote { Text(passwordNote).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Change password") }
    }

    /// The whole record as a file to keep.
    private var exportText: String {
        guard let d = try? JSONSerialization.data(withJSONObject: store.doc, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    private func changePassword() async {
        do {
            _ = try await Supabase.shared.rest("/auth/v1/user", method: "PUT", body: ["password": newPassword])
            newPassword = ""; passwordNote = "Password changed. Use the new one on the website too."
        } catch { passwordNote = "Couldn't change it: \(error.localizedDescription)" }
    }

    private var timeText: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: weighTime)
        return String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 30)
    }

    private func saveAsking() {
        guard loaded else { return }
        Task {
            if (lunch || weighOn) && !allowed { allowed = await Reminders.ask() }
            save()
        }
    }

    private func save() {
        guard loaded else { return }
        store.setReminders(lunch: lunch, weigh: weighOn ? timeText : nil)
    }
}
