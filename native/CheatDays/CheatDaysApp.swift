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
        else if ProcessInfo.processInfo.arguments.contains("-uitest-session") { SessionHarness() }
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

/// For the timer bar UI test only: a session with a sample workout inside a tab, the way Workouts shows it, no sign-in.
private struct SessionHarness: View {
    var body: some View {
        TabView {
            NavigationStack {
                SessionView(sample: LiveSession(startedAt: Double(nowMs()), name: "Legs", routineId: nil, exercises:
                    ["Squat", "Leg press", "Calf raises"].map { n in LiveExercise(name: n, sets: (0..<4).map { _ in LiveSet(reps: 10, kg: 100) }) }))
            }
            .tabItem { Label("Workouts", systemImage: "dumbbell") }
        }
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
    @State private var showPassword = false
    @State private var creating = false
    @FocusState private var field: Int?

    var body: some View {
        let ready = !busy && !email.isEmpty && password.count >= (creating ? 6 : 1)
        ScrollView {
            VStack(spacing: 0) {
                LogoMark().fill(Color(red: 0.91, green: 0.93, blue: 0.97)).frame(width: 94, height: 50).padding(.top, 104)
                    .accessibilityLabel("Cheat Days")
                Text("Every day can feel like a cheat day.").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top, 24)
                Picker("", selection: $creating) { Text("Sign in").tag(false); Text("New account").tag(true) }
                    .pickerStyle(.segmented).controlSize(.small).padding(.top, 32)
                    .onChange(of: creating) { _, _ in message = nil }
                VStack(spacing: 10) {
                    box(icon: "envelope", on: field == 0) {
                        TextField("Email", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($field, equals: 0).submitLabel(.next).onSubmit { field = 1 }
                    }
                    box(icon: "lock", on: field == 1) {
                        Group {
                            let prompt = creating ? "Choose a password" : "Password"
                            if showPassword { TextField(prompt, text: $password).textInputAutocapitalization(.never).autocorrectionDisabled() }
                            else { SecureField(prompt, text: $password) }
                        }
                        .textContentType(creating ? .newPassword : .password).focused($field, equals: 1).submitLabel(.go)
                        .onSubmit { if ready { Task { await go(create: creating) } } }
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    if creating && message == nil {
                        Text("At least 6 characters").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(Theme.warn).frame(maxWidth: .infinity, alignment: .leading) }
                    Button { Task { await go(create: creating) } } label: {
                        Text(busy ? (creating ? "Creating…" : "Signing in…") : (creating ? "Create account" : "Sign in")).font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Theme.accent.opacity(ready ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(!ready).padding(.top, 8)
                }
                .padding(.top, 18)
            }
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .keyboardDone()
        .background(Theme.bg.ignoresSafeArea())
    }

    /// A text box on its own: an icon at the start, no outline until you're typing in it, then a blue one.
    private func box<Content: View>(icon: String, on: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(.secondary).frame(width: 20)
            content()
        }
        .padding(.horizontal, 14).frame(height: 46)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { if on { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5) } }
        .contentShape(Rectangle())
        .onTapGesture { field = icon == "envelope" ? 0 : 1 }
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
