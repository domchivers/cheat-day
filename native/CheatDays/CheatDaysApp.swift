import SwiftUI

/// Where the website lives: the parts of the app that are still web (Workouts, Friends, scanning, the assistant)
/// load it from here, so web changes reach them without a new build.
enum AppConfig {
    static let host = "domchivers.github.io"
    static let startURL = URL(string: "https://domchivers.github.io/cheat-day/?app=ios")!
}

@main
struct CheatDaysApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .fontDesign(.rounded)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-uitest-assistant") { AssistantHarness() }
        else if Supabase.shared.session == nil { SignInView() } else { MainTabs() }
    }
}

/// For the keyboard UI test only: the assistant opened as a sheet the way Today opens it, with no sign-in needed.
private struct AssistantHarness: View {
    @State private var open = false
    var body: some View {
        Button("Open assistant") { open = true }.accessibilityIdentifier("openAssistant")
            .sheet(isPresented: $open) { AssistantView(meal: "Lunch", firstQuestion: "") }
    }
}

struct MainTabs: View {
    @State private var tab = 0
    @State private var onboarding = false
    @State private var habits = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $tab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max.fill") }.tag(0)
            WorkoutsView()
                .tabItem { Label("Workouts", systemImage: "dumbbell.fill") }.tag(1)
            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }.tag(2)
                .badge(FriendActivity.shared.unread)
            MeView()
                .tabItem { Label("Me", systemImage: "person.crop.circle.fill") }.tag(3)
        }
        .sensoryFeedback(.selection, trigger: tab)
        .onReceive(NotificationCenter.default.publisher(for: .openTab)) { n in if let t = n.object as? Int { tab = t } }
        .onOpenURL { url in
            guard url.scheme == "cheatdays" else { return }
            tab = 0
            if url.host == "add" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: .openAdd, object: nil) } }
        }
        .task {
            await Store.shared.sync()
            if Store.shared.needsOnboarding { onboarding = true } else if Store.shared.needsHabits { habits = true }
            await Store.shared.applyHelperChanges(); await Store.shared.pullBody(); await Reminders.reschedule(Store.shared)
            await HealthSync.pull()
            await FriendActivity.shared.load()
            await Push.start()
        }
        .fullScreenCover(isPresented: $onboarding, onDismiss: { if Store.shared.needsHabits { habits = true } }) { OnboardingView(firstRun: true) { onboarding = false } }
        .fullScreenCover(isPresented: $habits) { HabitsView { habits = false } }
        .onChange(of: phase) { _, now in
            if now == .background { Store.shared.flush() }
            if now == .active { Task { await Store.shared.sync(); await Store.shared.applyHelperChanges(); await Reminders.reschedule(Store.shared); await HealthSync.pull(); await Steps.shared.refresh(); await FriendActivity.shared.load() } } }
        .onChange(of: tab) { _, _ in
            if Store.shared.lastSynced.map({ Date().timeIntervalSince($0) > 60 }) ?? true { Task { await Store.shared.sync() } }
        }
    }
}

struct SignInView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @FocusState private var field: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "chart.pie.fill").font(.system(size: 54)).foregroundStyle(Theme.accent).padding(.top, 60)
                Text("Cheat Days").font(.largeTitle.bold())
                Text("Sign in with the same email and password as the Cheat Days website. Everything you've logged comes with you.")
                    .foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($field, equals: 0).submitLabel(.next).onSubmit { field = 1 }
                    SecureField("Password", text: $password)
                        .textContentType(.password).focused($field, equals: 1).submitLabel(.go).onSubmit { Task { await go(create: false) } }
                }
                .padding(16).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.warn) }
                Button { Task { await go(create: false) } } label: {
                    Text(busy ? "Signing in…" : "Sign in").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 16)).disabled(busy || email.isEmpty || password.isEmpty)
                Button("Create an account") { Task { await go(create: true) } }
                    .frame(maxWidth: .infinity).disabled(busy || email.isEmpty || password.count < 6)
            }
            .padding(.horizontal, 24)
        }
        .keyboardDone()
        .background(Theme.bg.ignoresSafeArea())
    }

    private func go(create: Bool) async {
        busy = true; message = nil
        defer { busy = false }
        do {
            if create {
                let inNow = try await Supabase.shared.signUp(email: email.trimmingCharacters(in: .whitespaces), password: password)
                if !inNow { message = "Check your email to confirm the account, then sign in here." }
            } else {
                try await Supabase.shared.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            }
            if Supabase.shared.session != nil { await Store.shared.sync() }
        } catch {
            message = error.localizedDescription == "Invalid login credentials" ? "Email or password isn't right." : error.localizedDescription
        }
    }
}
