import SwiftUI
import UserNotifications

/// Settings: reminders, weigh-in days, sharing, your account. Everything else is under "More".
struct SettingsView: View {
    @State private var lunch = true
    @State private var weighOn = true
    @State private var weighTime = Calendar.current.date(from: DateComponents(hour: 7, minute: 30)) ?? Date()
    @State private var days: Set<Int> = [0]
    @State private var share = true
    @State private var allowed = true
    @State private var loaded = false
    private var store: Store { Store.shared }
    private let order = [1, 2, 3, 4, 5, 6, 0]

    var body: some View {
        Form {
            Section {
                Toggle("Nudge at 2pm if nothing's logged", isOn: $lunch)
                Toggle("Weigh-in reminder", isOn: $weighOn)
                if weighOn { DatePicker("At", selection: $weighTime, displayedComponents: .hourAndMinute) }
                if !allowed {
                    Button("Allow notifications") { Task { allowed = await Reminders.ask(); save() } }
                }
            } header: { Text("Reminders") } footer: {
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
            Section {
                Toggle("Share my day with friends", isOn: $share)
            } footer: { Text("Friends see your calories and what you had today.") }
            Section("Account") {
                LabeledContent("Signed in as", value: Supabase.shared.email)
                NavigationLink { WebScreen(view: "settings", pushed: true).navigationTitle("More settings").navigationBarTitleDisplayMode(.inline) } label: { Text("More settings") }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let p = store.reminderPrefs
            lunch = p.lunch; weighOn = p.weigh != nil
            if let w = p.weigh { let parts = w.split(separator: ":").compactMap { Int($0) }; weighTime = Calendar.current.date(from: DateComponents(hour: parts.first ?? 7, minute: parts.count > 1 ? parts[1] : 30)) ?? weighTime }
            days = Set(store.weighDays); share = (store.doc["shareDay"] as? Bool) ?? true
            let s = await UNUserNotificationCenter.current().notificationSettings()
            allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            loaded = true
        }
        .onChange(of: lunch) { _, _ in saveAsking() }
        .onChange(of: weighOn) { _, _ in saveAsking() }
        .onChange(of: weighTime) { _, _ in save() }
        .onChange(of: days) { _, now in if loaded { store.setWeighDays(Array(now)) } }
        .onChange(of: share) { _, now in if loaded { store.setShareDay(now) } }
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
