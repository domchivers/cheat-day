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
    init() { KeyboardDone.install() }
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
        else if ProcessInfo.processInfo.arguments.contains("-uitest-tour") { TourHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-signin") { SignInView() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-plan") { PlanHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-recipe") { RecipeHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-scale") { ScaleSetupView {} }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-weigh") { WeighInSheet() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-body") { BodyHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-walk") { WalkHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-ranks") { RanksHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-mealcheck") { MealCheckHarness() }
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

/// For the Plan screenshot only: the planner with two sample scanned foods in the cupboard, no sign-in.
private struct PlanHarness: View {
    init() {
        let samples = [
            PantryItem(basis: ["name": "Chicken breast fillets", "brand": "Tesco", "kcalPer100": 106.0, "p100": 24.0, "c100": 0.0, "f100": 1.5]),
            PantryItem(basis: ["name": "Basmati rice pouch", "kcalPer100": 148.0, "p100": 3.0, "c100": 31.0, "f100": 1.2])
        ].compactMap { $0 }
        UserDefaults.standard.set(PantryItem.Saved.save(samples), forKey: "pantry.scans")
        UserDefaults.standard.set("peppers, eggs, spinach", forKey: "pantry")
    }
    var body: some View { MealPlannerView() }
}

/// For the Body screenshot only: ten weeks of weigh-ins (one odd) with body fat and a goal, no sign-in.
private struct BodyHarness: View {
    init() {
        let s = Store.shared
        let kg = [83.0, 83.2, 83.4, 87.4, 83.3, 83.1, 82.9, 82.4, 82.1, 82.0, 81.7, 81.4, 81.2, 80.9, 80.65]
        for (i, w) in kg.enumerated() {
            let day = DayKey.shift(DayKey.string(Date()), days: -(kg.count - 1 - i) * 5)
            s.perform(["type": "body", "row": ["day": day, "weight": w, "fat": 17.4 - Double(i) * 0.08, "updatedAt": ISO.now()] as JSON])
        }
        s.perform(["type": "set", "key": "goalWeight", "value": 80.0])
    }
    var body: some View { NavigationStack { BodyView() } }
}

/// For the Workouts screenshot only: a week of steps from Apple Health, no sign-in.
private struct WalkHarness: View {
    init() {
        let steps = [6100, 4800, 8300, 3900, 7400, 6900, 8240]
        var days: [String: Int] = [:]
        for (i, n) in steps.enumerated() { days[DayKey.shift(DayKey.string(Date()), days: i - 6)] = n }
        Steps.shared.preview(days)
    }
    var body: some View { WorkoutsView() }
}

/// For the meal check screenshot only: toast logged for lunch, then the word about it, no sign-in.
private struct MealCheckHarness: View {
    let check: MealCheck?
    init() {
        let s = Store.shared
        if !s.todayItems.contains(where: { str($0["name"]) == "Toast with butter" }) {
            s.add(["name": "Toast with butter", "source": "manual", "kcalPerServing": 260, "pServ": 7, "cServ": 34, "fServ": 11], kcal: 260, meal: "Lunch")
        }
        check = s.mealCheck("Lunch")
    }
    var body: some View {
        if let check { MealCheckSheet(check: check) {} } else { Text("No check") }
    }
}

/// For the ranks screenshot only: every tier's badge with its steps, then the Ranks screen.
private struct RanksHarness: View {
    @State private var open = false
    var body: some View {
        VStack(spacing: 18) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(0..<3, id: \.self) { col in
                        let r = Rank(level: (row * 3 + col) * 3 + 1 + col % 3)
                        VStack(spacing: 6) { RankBadge(rank: r, size: 84); RankSteps(rank: r, width: 50); Text(r.name).font(.caption.weight(.bold)).foregroundStyle(r.color) }
                    }
                }
            }
            HStack(spacing: 10) { ForEach(0..<6, id: \.self) { t in RankBadge(rank: Rank.first(ofTier: t), size: 16) } }
            Button("Open ranks") { open = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        .sheet(isPresented: $open) { RanksView() }
    }
}

/// For the recipe swap UI test only: a written recipe and one cupboard food, no sign-in or AI.
private struct RecipeHarness: View {
    let idea: JSON
    init() {
        let chicken = PantryItem(basis: ["name": "Chicken breast fillets", "brand": "Tesco", "kcalPer100": 106.0, "p100": 24.0, "c100": 0.0, "f100": 1.5])
        UserDefaults.standard.set(PantryItem.Saved.save([chicken].compactMap { $0 }), forKey: "pantry.scans")
        UserDefaults.standard.set("{}", forKey: "recipe.swaps")
        UserDefaults.standard.set("[]", forKey: "recipe.removed")
        func ing(_ n: String, _ a: String, _ g: Double, _ k: Double, _ p: Double, _ c: Double, _ f: Double) -> JSON {
            ["name": n, "amount": a, "grams": g, "kcal": k, "protein_g": p, "carbs_g": c, "fat_g": f]
        }
        let ings = [ing("Chicken thigh", "150 g", 150, 270, 26, 0, 18), ing("Basmati rice, cooked", "180 g", 180, 230, 5, 50, 1),
                    ing("Red pepper", "1", 120, 37, 1, 7, 0), ing("Soy sauce", "1 tbsp", 15, 8, 1, 1, 0)]
        idea = ["name": "Chicken and pepper rice bowl", "meal": "Dinner", "recipe": [
            "cuisine": "Asian", "minutes": 15.0, "portions": 1.0,
            "authentic": ["ingredients": ings, "steps": ["Cook the chicken.", "Add the peppers and rice.", "Season with soy."]] as JSON,
            "healthier": ["ingredients": ings, "steps": ["Cook the chicken.", "Add the peppers and rice."], "changes": ["Less oil"]] as JSON
        ] as JSON]
    }
    var body: some View { RecipeSheet(idea: idea) }
}

/// For the tour UI test only: the real tabs with the tour started on Today, no sign-in or sync.
private struct TourHarness: View {
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            TodayView().tabItem { Label("Today", systemImage: "sun.max.fill") }.tag(0)
            Color.clear.tabItem { Label("Workouts", systemImage: "dumbbell.fill") }.tag(1)
            Color.clear.tabItem { Label("Friends", systemImage: "person.2.fill") }.tag(2)
            Color.clear.tabItem { Label("Me", systemImage: "person.crop.circle.fill") }.tag(3)
        }
        .overlay { TourOverlay() }
        .task {
            try? await Task.sleep(for: .seconds(1))
            Tour.shared.pending = true
            Tour.shared.startIfPending()
        }
    }
}

struct MainTabs: View {
    @State private var tab = 0
    @State private var onboarding = false
    @State private var habits = false
    @State private var scaleSetup = false
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
            await Store.shared.sync()   // waits for the account to come down, even if signing in started the sync
            // just signed in: the whole setup, each step with Skip; otherwise only what an account still needs
            if UserDefaults.standard.bool(forKey: "signin.setup") || Store.shared.needsOnboarding { onboarding = true }
            else if Store.shared.needsHabits { habits = true }
            else { afterSetup() }
            await Store.shared.applyHelperChanges(); await Store.shared.pullBody(); await Reminders.reschedule(Store.shared)
            await HealthSync.pull()
            await FriendActivity.shared.load()
            await Push.start()
        }
        .fullScreenCover(isPresented: $onboarding, onDismiss: {
            if UserDefaults.standard.bool(forKey: "signin.setup") || Store.shared.needsHabits { habits = true } else { afterSetup() }
        }) { OnboardingView(firstRun: true) { onboarding = false } }
        .fullScreenCover(isPresented: $habits, onDismiss: { UserDefaults.standard.set(false, forKey: "signin.setup"); afterSetup() }) { HabitsView { habits = false } }
        .fullScreenCover(isPresented: $scaleSetup, onDismiss: { Tour.shared.startIfPending() }) { ScaleSetupView { scaleSetup = false } }
        .overlay { TourOverlay() }   // the show-me tour, over everything including the tab bar
        .onChange(of: Tour.shared.pending) { _, now in
            // Settings' replay; a fresh sign-in waits for the first sync's onboarding check in .task instead
            let s = Store.shared
            if now && !onboarding && !habits && !scaleSetup && !UserDefaults.standard.bool(forKey: "scaleSetup.pending")
                && !UserDefaults.standard.bool(forKey: "signin.setup")
                && s.lastSynced != nil && !s.needsOnboarding && !s.needsHabits { Tour.shared.startIfPending() }
        }
        .onChange(of: phase) { _, now in
            if now == .background { Store.shared.flush() }
            if now == .active { Task { await Store.shared.sync(); await Store.shared.applyHelperChanges(); await Reminders.reschedule(Store.shared); await HealthSync.pull(); await Steps.shared.refresh(); await FriendActivity.shared.load() } } }
        .onChange(of: tab) { _, _ in
            if Store.shared.lastSynced.map({ Date().timeIntervalSince($0) > 60 }) ?? true { Task { await Store.shared.sync() } }
        }
    }

    /// Once sign-up and the food plan are done: connect a scale (first sign-in only, if there's Health and it isn't
    /// on yet), then the show-me tour.
    private func afterSetup() {
        let d = UserDefaults.standard
        if d.bool(forKey: "scaleSetup.pending") {
            d.set(false, forKey: "scaleSetup.pending"); d.set(true, forKey: "scaleSetup.asked")
            if HealthSync.available && !HealthSync.on { scaleSetup = true; return }
        }
        Tour.shared.startIfPending()
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
        let ready = !busy && !email.isEmpty && password.count >= (creating ? 8 : 1)   // 8, the same as changing it in Settings
        ScrollView {
            VStack(spacing: 0) {
                LogoMark().fill(Color(red: 0.91, green: 0.93, blue: 0.97)).frame(width: 94, height: 50)
                    .accessibilityLabel("Cheat Days")
                (Text("Every day can feel like a ") + Text("cheat day").bold() + Text(".")).font(.body).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top, 28)
                Picker("", selection: $creating) { Text("Sign in").tag(false); Text("New account").tag(true) }
                    .pickerStyle(.segmented).controlSize(.small).padding(.top, 44)
                    .onChange(of: creating) { _, _ in message = nil }
                VStack(spacing: 14) {
                    box(icon: "envelope", on: field == 0) {
                        TextField("Email", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($field, equals: 0).submitLabel(.next).onSubmit { field = 1 }
                    }
                    box(icon: "lock", on: field == 1) {
                        Group {
                            if showPassword { TextField("Password", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled() }
                            else { SecureField("Password", text: $password) }
                        }
                        .textContentType(creating ? .newPassword : .password).focused($field, equals: 1).submitLabel(.go)
                        .onSubmit { if ready { Task { await go(create: creating) } } }
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(Theme.warn).frame(maxWidth: .infinity, alignment: .leading) }
                    else if creating && !password.isEmpty && password.count < 8 {
                        // only while a new password is too short; it goes at 8
                        Text("At least 8 characters").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4).padding(.top, -6)
                    }
                    Button { if ready { Task { await go(create: creating) } } } label: {
                        Text(busy ? (creating ? "Creating…" : "Signing in…") : (creating ? "Create account" : "Sign in"))
                            .font(.subheadline.weight(.bold)).foregroundStyle(ready ? Color.black : Theme.heroLabel)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            // until it can go: the calories panel's navy, its words still readable; then the bright blue
                            .background(ready ? Theme.accent : Theme.hero, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 26)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)   // a touch above the middle reads as centred
            .containerRelativeFrame(.vertical)   // the whole block sits in the middle of the screen
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
        .padding(.horizontal, 16).frame(height: 50)
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
            if Supabase.shared.session != nil {
                // every sign-in goes through the whole setup (plan, food, scale, tour), each step skippable: an
                // account that's set up before keeps its answers, so skipping changes nothing
                let d = UserDefaults.standard
                Tour.shared.pending = true
                d.set(true, forKey: "scaleSetup.pending")
                d.set(true, forKey: "signin.setup")
                await Store.shared.sync()
            }
        } catch {
            message = error.localizedDescription == "Invalid login credentials" ? "Email or password isn't right." : error.localizedDescription
        }
    }
}
