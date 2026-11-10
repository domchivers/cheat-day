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
    @AppStorage(Palette.key) private var theme = "classic"   // the colour picked in Settings, so the tint follows it
    @AppStorage(Appearance.key) private var appearance = "dark"   // dark as it's always been, until light or the phone's is picked
    init() {
        KeyboardDone.install()
        // no scroll bars down the side of the screens; the assistant's chat keeps its own (a long conversation needs one)
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(Appearance.scheme(appearance))
                .fontDesign(.rounded)
                .tint(Palette.named(theme).accent)
        }
    }
}

struct RootView: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-uitest-assistant") { AssistantHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-takeaway") { TakeawayHarness() }
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
        else if ProcessInfo.processInfo.arguments.contains("-uitest-stickers") { StickersHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-honors") { HonorsHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-editor") { EditorHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-tabicons") { TabIconsHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-editprofile") { EditProfileHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-review") { ReviewHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-cards") { CardsHarness() }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-checkin-step") { CheckInHarness(acting: true) }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-checkin") { CheckInHarness(acting: false) }
        else if ProcessInfo.processInfo.arguments.contains("-uitest-budget") { NavigationStack { BudgetView() } }
        else if ProcessInfo.processInfo.arguments.contains("-demo-checkin") { DemoRoot(checkIn: true) }
        else if ProcessInfo.processInfo.arguments.contains("-demo-budget") || ProcessInfo.processInfo.arguments.contains("-demo-weigh") { DemoRoot(checkIn: false) }
        else if ProcessInfo.processInfo.arguments.contains("-demo") || ProcessInfo.processInfo.arguments.contains("-demo-session") { DemoRoot(checkIn: false) }
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

/// For the takeaway screenshots only: the assistant open on three answers worked out here from a made-up restaurant's kJ (no AI,
/// no sign-in): just Seoul Chicken for tomorrow's lunch with a shake offered, dinner with a shake and ice cream asked for, and a
/// burger logged from its page with each part checked.
private struct TakeawayHarness: View {
    @State private var open = false
    init() {
        let rows: [(String, Double, Double)] = [("Spicy Chicken Cupbap", 2414, 30), ("Original tenders, 4 pcs", 2800, 42), ("Chicken Burger", 2280, 30),
                                                ("Boneless Chicken", 3720, 50), ("Bibimbap", 2740, 28), ("Kimchi Fried Rice", 3053, 15)]
        let menu = Takeaway.items(["items": rows.map { ["name": $0.0, "kind": "main", "published": "energy", "kj": $0.1, "kcal": 0, "protein_g": $0.2, "carbs_g": 50, "fat_g": 25] as JSON }])
        let home = [Takeaway.home(name: "Milk Chocolate Protein Powder", kcal100: 380, p100: 69.3, c100: 16, f100: 4.3, serving: 30, label: true),
                    Takeaway.home(name: "High protein milk", kcal100: 68, p100: 6, c100: 5, f100: 1, serving: nil, label: true),
                    Takeaway.home(name: "Protein ice cream", kcal100: 106, p100: 7.2, c100: 11.6, f100: 3.4, serving: nil, label: true)].compactMap { $0 }
        let lunch = Takeaway.result(Takeaway.plan(menu: menu, home: [], kcal: 600, protein: 45, place: "Seoul Chicken Prahran"), home: [], tips: home, menu: menu,
                                    shown: "Seoul Chicken Prahran", kcal: 600, protein: 45, meal: "Lunch", smallest: 545)
        let dinner = Takeaway.result(Takeaway.plan(menu: menu, home: home, kcal: 854, protein: 59, want: ["chicken burger"], place: "Seoul Chicken"), home: home, menu: menu,
                                     shown: "Seoul Chicken", kcal: 854, protein: 59, meal: "Dinner", smallest: 545)
        func part(_ n: String, _ g: Double, _ k: Double, _ p: Double) -> JSON { ["name": n, "grams": g, "kcal": k, "protein_g": p, "carbs_g": 0, "fat_g": 0, "src": "au", "match": n] }
        let burger: JSON = ["kind": "estimate", "meal": "Lunch", "trail": ["Energy from the kJ on Seoul Chicken's page in your photo"],
                            "estimate": ["name": "Seoul Chicken burger", "shop": "Seoul Chicken", "portion_g": 255, "unit": "g", "kcal_total": 544, "protein_g": 28, "carbs_g": 60, "fat_g": 21,
                                         "parts": [part("Burger bun, toasted", 85, 235, 7), part("Chicken fillet, crumbed, fried", 100, 223, 22), part("Coleslaw", 40, 42, 1), part("Creamy cheese sauce", 30, 44, 2)]] as JSON]
        // made-up places, the way the search gives them
        func spot(_ n: String, _ a: String, _ c: String, _ d: String, _ pub: String, _ kj: Double, _ k: Double, _ p: Double) -> JSON {
            ["name": n, "area": a, "cuisine": c, "dish": d, "published": pub, "kj": kj, "kcal": k, "protein_g": p, "carbs_g": 50, "fat_g": 20]
        }
        let places = Takeaway.places(["found": true, "places": [spot("Spud Shack", "Chapel St", "Potato bowls", "The Chicken Power Bowl", "full", 0, 497, 46),
                                                                spot("Olive Street Greek", "Chapel St", "Greek", "Chargrilled Chicken", "energy", 2760, 660, 50),
                                                                spot("Wok in a Hurry", "South Yarra", "Asian", "The Satay", "energy", 2739, 655, 40),
                                                                spot("Burger Yard", "South Yarra", "Burgers", "Classic chicken burger", "none", 0, 605, 30)]],
                                     area: "South Yarra", asked: "Any good lunch spots near me in South Yarra?", meal: "Lunch", kcal: 700, protein: 45)
        AssistantLive.shared.turns = [
            Assistant.Turn(me: true, text: "want something from seoul chicken tomorrow, lunch"), Assistant.Turn(me: false, text: str(lunch["reply"]), result: lunch),
            Assistant.Turn(me: true, text: "854 left, Seoul Chicken for dinner, the chicken burger with a shake and ice cream"), Assistant.Turn(me: false, text: str(dinner["reply"]), result: dinner),
            Assistant.Turn(me: true, text: "This burger for lunch"), Assistant.Turn(me: false, text: "The Seoul Chicken burger, sized to the 2,280 kJ on the page. Tap Add to put it on today's list.", result: burger),
            Assistant.Turn(me: true, text: "Any good lunch spots near me in South Yarra that's healthy and high protein?"), Assistant.Turn(me: false, text: str(places["reply"]), result: places)]
        AssistantLive.shared.used = Date()
    }
    var body: some View {
        Button("Open assistant") { open = true }.accessibilityIdentifier("openAssistant")
            .sheet(isPresented: $open) { AssistantView(meal: "Lunch", firstQuestion: "") }
            .onAppear { open = true }
    }
}

/// For the Plan screenshot only: the planner with two sample scanned foods in the cupboard, no sign-in.
private struct PlanHarness: View {
    init() {
        let samples = [
            PantryItem(basis: ["name": "Chicken breast fillets", "brand": "Fresh Farm", "kcalPer100": 106.0, "p100": 24.0, "c100": 0.0, "f100": 1.5]),
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

/// For the profile tag screenshots only: a made-up profile with the Founder tag and a label, no sign-in.
private struct HonorsHarness: View {
    static let id = "00000000-0000-4000-8000-000000000001"
    init() {
        Profiles.shared.keep([Profiles.Profile(["user_id": Self.id, "display_name": "Dom Chivers", "username": "domchivers", "label": "Founder of Cheat Days",
                                                "bio": "Lifting, eating, building the app 💪", "tags": ["💪 Lifting", "Eating"], "honors": ["founder", "alpha", "first100"],
                                                "top_honor": "founder", "show_honors": true, "private": false, "privacy_chosen": true])])
    }
    var body: some View { NavigationStack { ProfileView(id: Self.id) } }
}

/// For the Edit profile screenshots only: signed out, so "me" is the empty id, given the founder's profile.
private struct EditProfileHarness: View {
    init() {
        Profiles.shared.keep([Profiles.Profile(["user_id": "", "display_name": "Dom Chivers", "username": "domchivers", "label": "Founder of Cheat Days",
                                                "bio": "Lifting, eating, building the app 💪", "honors": ["founder", "alpha", "first100"],
                                                "top_honor": "founder", "show_honors": true, "private": true, "privacy_chosen": true])])
    }
    var body: some View { EditProfileView() }
}

/// For choosing the Today tab's icon only: Apple's food and day symbols, each in a tab bar beside the others.
private struct TabIconsHarness: View {
    static let names = ["fork.knife", "fork.knife.circle.fill", "takeoutbag.and.cup.and.straw.fill", "frying.pan.fill", "carrot.fill",
                        "leaf.fill", "flame.fill", "cup.and.saucer.fill", "birthday.cake.fill", "fish.fill", "basket.fill",
                        "refrigerator.fill", "scalemass.fill", "chart.pie.fill", "list.bullet.clipboard.fill", "sun.max.fill"]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(Self.names.enumerated()), id: \.offset) { i, n in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(i + 1) · \(n)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                        HStack(spacing: 0) {
                            Image(systemName: n).font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.accent)
                                .frame(width: 54, height: 38).background(Color.white.opacity(0.14), in: Capsule())
                            Spacer()
                            Image(systemName: "dumbbell.fill").font(.system(size: 19, weight: .semibold))
                            Spacer()
                            Image(systemName: "person.2.fill").font(.system(size: 19, weight: .semibold))
                            Spacer()
                        }
                        .padding(5).background(Color(white: 0.16), in: Capsule())
                    }
                }
            }
            .padding(14)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// For the editor test only: the real story editor on a plain photo, to add, move and pinch stickers.
private struct EditorHarness: View {
    private static let photo = UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 1920)).image { c in
        let colours = [UIColor(red: 0.4, green: 0.25, blue: 0.15, alpha: 1).cgColor, UIColor(red: 0.12, green: 0.08, blue: 0.06, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
            c.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 1920), options: [])
        }
    }
    var body: some View { StoryEditor(image: Self.photo, video: nil, close: {}) }
}

/// For the sticker screenshots only: the tray as it opens, then every sticker on a story, no sign-in.
private struct StickersHarness: View {
    @State private var tray = true
    private static let all: [JSON] = [
        ["type": "food", "name": "Eggs on sourdough", "kcal": 410, "p": 33, "style": 0, "scale": 0.62, "x": 0.3, "y": 0.1],
        ["type": "food", "name": "Chicken bowl", "kcal": 520, "p": 42, "style": 1, "scale": 0.62, "x": 0.72, "y": 0.1],
        ["type": "macros", "p": 120, "c": 180, "f": 55, "kcal": 1652, "scale": 0.62, "x": 0.5, "y": 0.21],
        ["type": "ring", "eaten": 1240, "budget": 2350, "scale": 0.62, "x": 0.5, "y": 0.32],
        ["type": "left", "kcal": 1110, "scale": 0.62, "x": 0.3, "y": 0.42], ["type": "streak", "days": 54, "scale": 0.62, "x": 0.72, "y": 0.42],
        ["type": "steps", "steps": 8421, "scale": 0.62, "x": 0.3, "y": 0.5], ["type": "rank", "level": 10, "scale": 0.62, "x": 0.72, "y": 0.5],
        ["type": "cheat", "days": 4, "scale": 0.62, "x": 0.27, "y": 0.61], ["type": "workout", "name": "Push day", "minutes": 52, "detail": "6 exercises", "scale": 0.62, "x": 0.72, "y": 0.61],
        ["type": "poll", "q": "Cheat day or not?", "a": "Yes", "b": "No", "scale": 0.62, "x": 0.5, "y": 0.72],
        ["type": "question", "q": "Ask me anything", "scale": 0.62, "x": 0.5, "y": 0.84],
        ["type": "time", "text": "15:40", "scale": 0.62, "x": 0.2, "y": 0.94], ["type": "place", "text": "South Yarra", "scale": 0.62, "x": 0.5, "y": 0.94],
        ["type": "hashtag", "text": "mealprep", "scale": 0.62, "x": 0.82, "y": 0.94]]
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.4, green: 0.25, blue: 0.15), Color(red: 0.12, green: 0.08, blue: 0.06)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            StoryLayer(items: Self.all).aspectRatio(9.0 / 16.0, contentMode: .fit).accessibilityIdentifier("story")
        }
        .sheet(isPresented: $tray) { StickerSheet(pick: { _ in }, place: { _ in }).presentationDetents([.large]) }
    }
}

/// For the meal check screenshot only: toast logged for lunch, then the pop-up after it, no sign-in.
private struct MealCheckHarness: View {
    let check: MealPop?
    init() {
        let s = Store.shared
        if !s.todayItems.contains(where: { str($0["name"]) == "Toast with butter" }) {
            s.add(["name": "Toast with butter", "source": "manual", "kcalPerServing": 260, "pServ": 7, "cServ": 34, "fServ": 11], kcal: 260, meal: "Lunch")
        }
        check = s.afterPop("Lunch")
    }
    var body: some View {
        if let check { MealPopSheet(pop: check) { _ in } } else { Text("No check") }
    }
}

/// For the week review screenshot only: both kinds of card in a list like Today's, with sample weeks, no sign-in.
private struct ReviewHarness: View {
    private let good = WeekReview(status: "On track", title: "A good week", rows: [
        .init(label: "Within budget", value: "6 of 7 days", ok: true), .init(label: "Protein goal hit", value: "5 of 7 days", ok: true),
        .init(label: "Weight", value: "−0.4 kg a week", ok: true)],
        tip: "Keep doing what you're doing. Your protein brownie's earning its place: 20 g protein for 190 kcal.")
    private let short = WeekReview(status: "Nearly there", title: "Protein's short", rows: [
        .init(label: "Within budget", value: "6 of 7 days", ok: true), .init(label: "Protein goal hit", value: "3 of 7 days", ok: false),
        .init(label: "Weight", value: "−0.4 kg a week", ok: true)],
        tip: "Dinners are where it drops: about 22 g on the short days. A chicken, fish or lean beef dinner would close the gap.", plan: "Dinner")
    private let fast = WeekReview(status: "Nearly there", title: "Losing instead of gaining", rows: [
        .init(label: "Within budget", value: "7 of 7 days", ok: true), .init(label: "Protein goal hit", value: "7 of 7 days", ok: true),
        .init(label: "Weight", value: "−0.6 kg a week", ok: false, note: "Last 4 weeks · plan +0.25 kg")],
        tip: "You've lost 0.6 kg a week over the last 4 weeks, and your plan is gaining 0.25 kg a week. Losing like this can cost muscle. You're eating your budget, so it's the budget that's too low. Monday's check-in will suggest a higher one.")
    var body: some View {
        List {
            Section { WeekReviewCard(review: fast) }
            Section { WeekReviewCard(review: good) }
            Section { WeekReviewCard(review: short) }
            Section("Breakfast") { Text("Weet-Bix with milk") }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
    }
}

/// For the ranks screenshot only: every tier's badge with its steps, then the Ranks screen.
private struct RanksHarness: View {
    @State private var open = false
    @State private var goals = false
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
            // badge coins: bronze, silver and gold earned, and one on its way
            HStack(spacing: 14) {
                ForEach(["first", "streak30", "streak365"], id: \.self) { id in if let b = Badge.all.first(where: { $0.id == id }) { BadgeCoin(badge: b, size: 58) } }
                if let b = Badge.all.first(where: { $0.id == "days100" }) { BadgeCoin(badge: b, size: 58, got: false, progress: 0.53) }
            }
            Button("Open ranks") { open = true }
            Button("Open goals") { goals = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        .sheet(isPresented: $open) { RanksView() }
        .sheet(isPresented: $goals) { NavigationStack { GoalsView() } }
    }
}

/// For the recipe swap UI test only: a written recipe and one cupboard food, no sign-in or AI.
private struct RecipeHarness: View {
    let idea: JSON
    init() {
        let chicken = PantryItem(basis: ["name": "Chicken breast fillets", "brand": "Fresh Farm", "kcalPer100": 106.0, "p100": 24.0, "c100": 0.0, "f100": 1.5])
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
            TodayView().tabItem { Image(uiImage: TabGlyph.make("fork.knife")).accessibilityLabel("Today") }.tag(0)
            Color.clear.tabItem { Image(uiImage: TabGlyph.make("dumbbell.fill")).accessibilityLabel("Workouts") }.tag(1)
            Color.clear.tabItem { Image(uiImage: TabGlyph.make("person.2.fill")).accessibilityLabel("Friends") }.tag(2)
            Color.clear.tabItem { Image(uiImage: TabGlyph.make("person.crop.circle.fill")).accessibilityLabel("Me") }.tag(3)
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
    var demo = false   // the marketing record: no sync, no setup, no tour
    var startTab = 0   // the demo's tab
    @State private var tab = 0
    @State private var onboarding = false
    @State private var habits = false
    @State private var scaleSetup = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $tab) {
            // icons only, no words under them; Today is the food log, so a plate rather than a sun
            TodayView()
                .tabItem { Image(uiImage: TabGlyph.make("fork.knife")).accessibilityLabel("Today") }.tag(0)
            WorkoutsView()
                .tabItem { Image(uiImage: TabGlyph.make("dumbbell.fill")).accessibilityLabel("Workouts") }.tag(1)
            FriendsView()
                .tabItem { Image(uiImage: TabGlyph.make("person.2.fill")).accessibilityLabel("Friends") }.tag(2)
                .badge(FriendActivity.shared.unread)
            MeView()
                .tabItem {
                    // your photo, once you've added one
                    if let icon = tab == 3 ? Profiles.shared.meIconOn : Profiles.shared.meIcon { Image(uiImage: icon).renderingMode(.original).accessibilityLabel("Me") }
                    else { Image(uiImage: TabGlyph.make("person.crop.circle.fill")).accessibilityLabel("Me") }
                }.tag(3)
        }
        .sensoryFeedback(.selection, trigger: tab)
        .onChange(of: tab) { _, _ in KeyboardDone.quiet = false }   // a chat box left open in another tab can't take Done away from this one
        .onReceive(NotificationCenter.default.publisher(for: .openTab)) { n in if let t = n.object as? Int { tab = t } }
        .onOpenURL { url in
            guard url.scheme == "cheatdays" else { return }
            tab = 0
            if url.host == "add" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: .openAdd, object: nil) } }
            // cheatdays://friend/DOM-1234, from a friend's QR code
            if url.host == "friend", !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" { tab = 2; Nav.shared.addCode = url.lastPathComponent }
        }
        .task {
            if demo { tab = startTab; return }
            await Store.shared.sync()   // waits for the account to come down, even if signing in started the sync
            Task {   // once per account: food lost from past days put back, then raised budgets
                await Store.shared.repairHistory()
                await Store.shared.repairBudgets()
                Store.shared.repairCheatFlies()
            }
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
            if now == .active { Task { await Store.shared.sync(); await Store.shared.applyHelperChanges(); await Reminders.reschedule(Store.shared); await HealthSync.pull(); await Steps.shared.refresh(); await FriendActivity.shared.load(); await Profiles.shared.touch(); await Messages.shared.load() } } }
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
                            .font(.subheadline.weight(.bold)).foregroundStyle(ready ? Theme.onAccent : Theme.heroLabel)
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

/// For the check-in screenshots only: the owner's real Saturdays (and a Thursday), waiting on a water swing or,
/// two weeks later, acting with a step. No sign-in.
private struct CheckInHarness: View {
    let acting: Bool
    var body: some View {
        let sat = [("2026-10-03", 82.35), ("2026-10-10", 81.85), ("2026-10-17", 81.80), ("2026-10-24", 81.30), ("2026-10-31", 79.95)]
            + (acting ? [("2026-11-07", 79.75), ("2026-11-14", 79.20)] : [])
        let readings = sat.map { Adaptive.Reading(day: $0.0, kg: $0.1) } + [Adaptive.Reading(day: "2026-10-29", kg: 80.6)]
        let rate = Adaptive.rate(readings, weighDay: 6, end: acting ? "2026-11-15" : "2026-11-01")
        let c = CheckIn(week: acting ? "2026-11-09" : "2026-10-26", mon: acting ? "2026-11-09" : "2026-10-26", sun: acting ? "2026-11-15" : "2026-11-01", logged: 7, avg: 2500, workouts: 4, change: -0.6,
                        burn: 3080, burnDays: 21, burnWeighins: 5, needs: [], pace: rate.map(\.perWeek), want: -0.3, now: 2500,
                        suggest: acting ? 2625 : nil, rate: rate, tol: 0.12, wellLogged: 7, step: acting ? 125 : nil,
                        verdict: acting ? "Losing faster than your goal for 2 weeks in a row. A little more food protects your muscle."
                                        : "Saturday's 79.95 looks like a water swing, 1.1 kg under your trend. Not changing anything on one reading. We'll check again next week.")
        NavigationStack { CheckInView(sample: c, week: (2350, [6: 3250, 0: 2500], 6)) }
    }
}

/// For the card screenshots only: the weigh-in card both ways, and the paired buttons on the after-midnight card. No sign-in.
private struct CardsHarness: View {
    var body: some View {
        List {
            Section { WeighInConfirmCard(day: DayKey.string(Date()), kg: 79.95, at: Date()) }
            Section { WeighInConfirmCard(day: DayKey.string(Date()), kg: 79.95, at: Date(), different: true, why: ["No toilet"]) }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("It's after midnight", systemImage: "moon.stars.fill").font(.headline).foregroundStyle(Theme.accent)
                    Text("Still Thursday for you? Food you add goes on Thursday until you say, or until 5am.").font(.subheadline).foregroundStyle(.secondary)
                    ButtonPair(first: "Keep it as Thursday", second: "Start Friday", onFirst: {}, onSecond: {})
                }
                .padding(.vertical, 4)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
    }
}

/// For marketing screenshots only (-demo, -demo-tab 0…3, -demo-session, -demo-checkin, -demo-budget, -demo-weigh): the real app on a made-up four weeks.
private struct DemoRoot: View {
    let checkIn: Bool
    init(checkIn: Bool) {
        self.checkIn = checkIn
        let live = ProcessInfo.processInfo.arguments.contains("-demo-session")   // a legs session mid-rest, on Workouts
        MainActor.assumeIsolated { Store.shared.useDemo(Demo.doc(session: live)); Friends.shared.useDemo() }
    }
    var body: some View {
        let live = ProcessInfo.processInfo.arguments.contains("-demo-session")
        let args = ProcessInfo.processInfo.arguments
        if checkIn { NavigationStack { CheckInView() } }
        else if args.contains("-demo-budget") { NavigationStack { BudgetView() } }   // the week with its treat day
        else if args.contains("-demo-weigh") { WeighInSheet() }
        else { MainTabs(demo: true, startTab: live ? 1 : Int(UserDefaults.standard.string(forKey: "demo-tab") ?? "") ?? 0) }
    }
}

/// A tab icon drawn to one height, so the wide ones (the dumbbell, the two people) stand as tall as the fork and
/// knife and your photo, rather than being shrunk to fit their width.
enum TabGlyph {
    @MainActor private static var made: [String: UIImage] = [:]
    @MainActor static func make(_ name: String, height: CGFloat = 26) -> UIImage {
        if let m = made[name] { return m }
        guard let sym = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 60, weight: .semibold)) else { return UIImage() }
        let k = height / sym.size.height, size = CGSize(width: (sym.size.width * k).rounded(), height: height)
        // the fork and knife are thin lines even at the heaviest weight: drawn again a little to each side, so the
        // strokes thicken and it weighs as much as the solid dumbbell and people beside it
        let fat: CGFloat = name == "fork.knife" ? 1.3 : 0
        let out = UIGraphicsImageRenderer(size: size).image { _ in
            let tinted = sym.withTintColor(.black), box = CGRect(origin: .zero, size: size).insetBy(dx: fat, dy: fat)
            if fat > 0 {
                for a in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 8) {
                    tinted.draw(in: box.offsetBy(dx: fat * CGFloat(cos(a)), dy: fat * CGFloat(sin(a))))
                }
            }
            tinted.draw(in: box)
        }
        .withRenderingMode(.alwaysTemplate)
        made[name] = out
        return out
    }
}
