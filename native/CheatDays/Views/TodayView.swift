import SwiftUI

/// What the amount screen works on: a food, maybe a starting amount, maybe the line being changed.
struct EditTarget: Identifiable, Hashable {
    let id = UUID()
    let basis: JSON
    let kcal: Double?
    let editId: String?
    let meal: String
    /// Where the numbers came from, when it's worth saying (a photo estimate, found online...).
    var note: String? = nil
    static func == (a: EditTarget, b: EditTarget) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A web screen opened in a sheet (scanning, typing numbers, the assistant) until those are native too.
struct WebFlow: Identifiable {
    let id = UUID()
    let view: String
    let opts: JSON
    let title: String
}

private struct MealChoice: Identifiable { let id: String }
private struct Line: Identifiable { let id: String; let item: JSON }

struct TodayView: View {
    @State private var offset = 0
    @State private var addChoice: MealChoice?
    @State private var editing: EditTarget?
    @State private var flow: WebFlow?
    @State private var pastItem: JSON?
    @State private var showPast = false
    @State private var showCheckIn = false
    @State private var showCheat = false
    @State private var showPlanner = false
    @State private var plannerMeal: String?   // the meal to open the planner on (a reminder, or "Ideas for dinner")
    @State private var rankUp: Rank?
    @State private var badgeNote: String?
    @AppStorage("today.more") private var moreOpen = false
    @AppStorage("nudge.hidden") private var nudgeHidden = ""   // "day|meal" of the card you closed
    @AppStorage("dailyTips") private var dailyTipsOn = true
    @AppStorage("dailyTips.seen") private var dailyTipsSeen = ""
    @State private var daily: DailyReview?
    @State private var mealCheck: MealCheck?
    /// How long after the last food added to a meal before it's looked at: time to add the rest of it.
    static let mealSettles: Double = 15 * 60
    @Environment(\.scenePhase) private var phase
    @AppStorage("mealCheck.seen") private var mealCheckSeen = ""   // "date|Lunch|Dinner": each shown once a day
    @State private var openIdea: IdeaRef?
    @State private var sendingItem: JSON?
    @State private var savingMeal: String?   // the meal whose foods are being saved as one
    private var store: Store { Store.shared }

    private var date: String { DayKey.shift(store.today, days: offset) }
    private var items: [JSON] { offset == 0 ? store.todayItems : (store.pastDay(date)?.items ?? []) }
    private var budget: Double { offset == 0 ? store.budgetToday : (store.pastDay(date)?.budget ?? store.baseBudget(date)) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                header
                    .id("top")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
                if offset == 0 { LateNightCard() }
                if let n = store.notice {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "person.2.fill").foregroundStyle(Theme.accent)
                            Text(n).font(.subheadline)
                            Spacer()
                            Button { withAnimation { store.notice = nil } } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }.buttonStyle(.borderless)
                        }
                    }
                }
                if offset == 0 {
                    ForEach(Family.shared.asks) { l in
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    FluentIcon(emoji: "👨‍👩‍👧", size: 30)
                                    Text("\(Family.shared.name(l.helper)) wants to help with your budget").font(.subheadline.weight(.bold))
                                }
                                Text("They'd be able to set your daily budget and fix foods on your day. You can stop it any time in Settings.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Button { Task { await Family.shared.answer(l, yes: true) } } label: { Text("Allow").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity) }
                                        .buttonStyle(.borderedProminent).foregroundStyle(.black)
                                    Button { Task { await Family.shared.answer(l, yes: false) } } label: { Text("No thanks").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity) }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    // by each send's id, not its position: adding one removes it, and a row drawn by position
                    // then read past the end of the list and crashed the app
                    ForEach(Inbox.shared.items.map { Line(id: str($0["id"]), item: $0) }) { line in
                        let x = line.item
                        Section {
                            HStack(spacing: 12) {
                                let recipe = Inbox.shared.meal(x)
                                Image(systemName: recipe == nil ? "paperplane.fill" : "book.closed.fill").foregroundStyle(Theme.accent).frame(width: 34, height: 34).background(Theme.hero, in: Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(Inbox.shared.name(str(x["from_user"]))) sent you \(recipe == nil ? "" : "a recipe")").font(.caption).foregroundStyle(.secondary)
                                    Text(str(x["name"])).font(.subheadline.weight(.bold))
                                    Text(recipe.map { "\(list($0["items"]).count) ingredients · \(Int(num(x["kcal"]) ?? 0)) kcal a portion" } ?? "\(Int(num(x["kcal"]) ?? 0)) kcal").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if recipe != nil {
                                    Menu {
                                        Button { withAnimation { Inbox.shared.save(x) }; note("Saved to your meals") } label: { Label("Save to my meals", systemImage: "book.closed") }
                                        Button { withAnimation { Inbox.shared.add(x) } } label: { Label("Have a portion today", systemImage: "plus.circle") }
                                    } label: { Text("Save").font(.subheadline.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 6).background(Theme.accent, in: Capsule()).foregroundStyle(.black) }
                                } else {
                                    Button("Add") { withAnimation { Inbox.shared.add(x) } }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(.black)
                                }
                                Button { withAnimation { Inbox.shared.settle(x, "dismissed") } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section { hero }
                    .listRowBackground(Color.clear)   // the panel draws its own card, so the trim and badge can sit on its top edge
                    .listRowInsets(EdgeInsets())
                if offset == 0, let n = store.nudge, nudgeHidden != store.today + "|" + n.meal { nudgeCard(n) }
                if offset == 0 && store.checkInDue {
                    let c = store.checkIn
                    Section {
                        Button { showCheckIn = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "calendar.badge.checkmark").font(.title3).foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Your weekly check-in").font(.headline)
                                    Text("\(c.avg.map { "\(Fmt.int($0)) a day" } ?? "Nothing logged") · \(c.logged) of 7 days\(c.suggest != nil ? " · a new budget to look at" : "")")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    if let focus = store.habitFocus { Text("This week, try: \(focus)").font(.footnote.weight(.semibold)).foregroundStyle(Theme.heroLabel) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(Meals.all, id: \.self) { meal in mealSection(meal) }
                if let e = store.syncError {
                    Section { Label("Not synced: \(e)", systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.secondary) }
                }
                Color.clear.frame(height: 70).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .onReceive(NotificationCenter.default.publisher(for: .tourScrollTop)) { _ in
                offset = 0
                withAnimation { proxy.scrollTo("top", anchor: .top) }   // the tour points at the top of today
            }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .refreshable { await store.sync() }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) { if offset == 0 { addButton } }
            .overlay(alignment: .bottom) { if let u = store.undo { undoBanner(u) } }
            .task(id: store.undo) {
                guard let u = store.undo else { return }
                try? await Task.sleep(for: .seconds(6))
                if store.undo == u { withAnimation(.snappy) { store.undo = nil } }
            }
            .sensoryFeedback(.success, trigger: store.todayItems.count)
            .sheet(item: $addChoice) { c in
                AddSheet(meal: c.id) { f in
                    addChoice = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { flow = f }
                }
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $editing) { t in
                NavigationStack { AmountView(target: t) { editing = nil } }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $flow) { f in
                if f.view == "ask" { AssistantView(meal: str(f.opts["meal"]).isEmpty ? Meals.now : str(f.opts["meal"]), firstQuestion: str(f.opts["q"])) }
                else { WebFlowSheet(flow: f) }
            }
            .sheet(isPresented: $showCheckIn) { NavigationStack { CheckInView() } }
            .sheet(isPresented: Binding(get: { daily != nil }, set: { if !$0 { daily = nil } })) {
                if let r = daily {
                    DailyTipsSheet(review: r) { meal, q in
                        daily = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { flow = WebFlow(view: "ask", opts: ["meal": meal, "q": q], title: "Assistant") }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .sheet(item: $openIdea) { r in RecipeSheet(idea: r.idea) }
            .task(id: store.lastSynced) {
                // once a day, after the first sync, unless it's turned off
                guard dailyTipsOn, dailyTipsSeen != store.today, store.lastSynced != nil, !store.needsOnboarding, !store.needsHabits,
                      !Tour.shared.pending, !Tour.shared.active, !showPlanner, !showCheat, openIdea == nil, addChoice == nil, flow == nil,
                      let r = store.dailyReview else { return }
                try? await Task.sleep(for: .seconds(0.8))
                dailyTipsSeen = store.today
                daily = r
            }
            .sheet(item: $mealCheck) { c in
                MealCheckSheet(check: c) {
                    mealCheck = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showPlanner = true }
                }
                .presentationDetents([.medium, .large])
            }
            .task(id: "\(store.todayItems.count)|\(addChoice == nil)|\(editing == nil)|\(flow == nil)|\(daily == nil)|\(openIdea == nil)|\(showPlanner)|\(phase == .active)") {
                // lunch or dinner logged and every other sheet closed: a word about it, once, if it needs one
                guard dailyTipsOn, phase == .active, offset == 0, addChoice == nil, editing == nil, flow == nil, daily == nil, mealCheck == nil, openIdea == nil,
                      !showPlanner, !showCheat, !showCheckIn, !Tour.shared.active else { return }
                try? await Task.sleep(for: .seconds(1))
                while !Task.isCancelled {
                    let seen = mealCheckSeen.hasPrefix(store.today + "|") ? mealCheckSeen : store.today
                    let now = Meals.byTime(Calendar.current.component(.hour, from: Date()))
                    var wait: Double?
                    for meal in [now, "Lunch", "Dinner"] where !seen.contains("|" + meal) {
                        guard let last = store.todayItems.filter({ Meals.of($0) == meal }).compactMap({ ISO.date(str($0["addedAt"])) }).max() else { continue }
                        let age = Date().timeIntervalSince(last)
                        // only a meal logged in the last few hours: not lunch brought up when the app's opened at night
                        guard age < 3 * 3600 else { continue }
                        // and once it's finished: a slice of toast with the eggs still to add isn't the meal yet
                        if age < Self.mealSettles { wait = min(wait ?? .infinity, Self.mealSettles - age); continue }
                        if let c = store.mealCheck(meal) { mealCheckSeen = seen + "|" + meal; mealCheck = c; return }
                    }
                    guard let w = wait else { return }
                    try? await Task.sleep(for: .seconds(w + 1))   // anything added meanwhile starts this over
                }
            }
            .sheet(isPresented: $showCheat) { CheatDayView().presentationDragIndicator(.visible) }
            .sheet(isPresented: $showPlanner, onDismiss: { plannerMeal = nil }) { MealPlannerView(meal: plannerMeal).presentationDragIndicator(.visible) }
            .onChange(of: Nav.shared.planMeal) { _, m in
                // a meal reminder tapped: the planner on that meal, once whatever's open has closed
                guard let m else { return }
                Nav.shared.planMeal = nil
                withAnimation { offset = 0 }
                addChoice = nil; editing = nil; flow = nil; daily = nil; mealCheck = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { plannerMeal = m; showPlanner = true }
            }
            .fullScreenCover(isPresented: Binding(get: { rankUp != nil }, set: { if !$0 { rankUp = nil } })) {
                if let r = rankUp { RankUpView(rank: r) { rankUp = nil } }
            }
            .modifier(SendFoodDialog(item: $sendingItem) { note($0) })
            .sheet(isPresented: Binding(get: { savingMeal != nil }, set: { if !$0 { savingMeal = nil } })) {
                if let m = savingMeal {
                    SaveMealSheet(name: "My \(m.lowercased())", foods: items.filter { Meals.of($0) == m }) { name, picked in
                        saveAsMeal(m, name: name, picked: picked)
                    }
                }
            }
            .onAppear { checkRank(); checkBadges() }
            .task { await Steps.shared.refresh() }
            .onChange(of: store.rank.level) { _, _ in checkRank() }
            .onChange(of: store.lastSynced) { _, _ in checkBadges(); Task { await Inbox.shared.refresh() } }
            .task { await Inbox.shared.refresh(force: true); await Family.shared.load() }
            .onChange(of: store.todayItems.count) { _, _ in checkBadges() }
            .overlay(alignment: .top) {
                if let badgeNote {
                    Text(badgeNote).font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openAdd)) { _ in withAnimation { offset = 0 }; addChoice = MealChoice(id: Meals.now) }
            .onReceive(NotificationCenter.default.publisher(for: .webDone)) { _ in
                guard flow != nil else { return }
                flow = nil
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await store.sync() }
            }
            .confirmationDialog(str(pastItem?["name"]), isPresented: $showPast, titleVisibility: .visible) {
                Button("Add to today") {
                    if let it = pastItem { store.add(FoodMath.basisOf(it), kcal: num(it["kcal"]) ?? 0, meal: Meals.now) }
                    withAnimation(.snappy) { offset = 0 }
                }
            } message: { Text("\(Fmt.int(num(pastItem?["kcal"]) ?? 0)) kcal, the same amount as that day") }
        }
    }

    // MARK: header and hero

    private var header: some View {
        HStack {
            Button { withAnimation(.snappy) { offset -= 1 } } label: {
                Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 40).background(Color(.secondarySystemBackground), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.title.bold()).contentTransition(.opacity)
                Text(DayKey.date(date).formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
            }
            Spacer()
            Button { withAnimation(.snappy) { offset = min(0, offset + 1) } } label: {
                Image(systemName: "chevron.right").font(.headline).frame(width: 40, height: 40).background(Color(.secondarySystemBackground), in: Circle())
            }
            .opacity(offset == 0 ? 0.3 : 1).disabled(offset == 0)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch offset {
        case 0: return "Today"
        case -1: return "Yesterday"
        default: return DayKey.date(date).formatted(.dateTime.weekday(.wide))
        }
    }

    private func hideButton(_ meal: String) -> some View {
        Button { withAnimation { nudgeHidden = store.today + "|" + meal } } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless).foregroundStyle(.secondary).font(.footnote.weight(.bold))
            .accessibilityLabel("Hide")
    }

    /// A piece of advice in the weekly check-in's style: icon, headline, a line under it, and a link to plan the next
    /// meal when there's something to do.
    private func adviceRow(_ a: Advice, hide meal: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FluentIcon(emoji: a.icon, size: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.headline)
                Text(a.detail).font(.footnote).foregroundStyle(.secondary)
                if let meal = a.plan {
                    Button { plannerMeal = meal; showPlanner = true } label: { Text("Ideas for \(meal.lowercased()) ›").font(.footnote.weight(.semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.accent).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if let meal { hideButton(meal) }
        }
    }

    private func nudgeCard(_ n: Nudge) -> some View {
        Section {
            if n.ideas.isEmpty, let a = n.advice {
                adviceRow(a, hide: n.meal).padding(.vertical, 2)
            } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(n.meal == "Snacks" ? "Snack time" : n.meal + " time"). Fancy one of these?").font(.headline)
                    Spacer()
                    hideButton(n.meal)
                }
                ForEach(n.ideas) { e in
                    HStack(spacing: 12) {
                        FoodDot(name: e.name, size: 32)
                        Button {
                            if let m = store.habitIdeas.first(where: { str($0["name"]).lowercased() == e.name.lowercased() }) { openIdea = IdeaRef(id: e.name, idea: m) }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(e.detail.isEmpty ? "See the recipe" : "\(e.detail) · recipe").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .multilineTextAlignment(.leading)   // a button label centres wrapped lines otherwise
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless).foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Text(Fmt.int(e.kcal)).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(Theme.accent)
                        Button { withAnimation { _ = store.add(e.basis, kcal: e.kcal, meal: n.meal) } } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add \(e.name)")
                    }
                }
                if let a = n.advice {
                    Divider()
                    adviceRow(a, hide: nil)
                }
            }
            .padding(.vertical, 4)
            }
        }
    }

    private var hero: some View {
        let eaten = items.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        let left = budget - eaten
        let m = store.macros(items), protein = m.p
        let scale = max(budget, eaten, 1)
        let byMeal = Meals.all.map { m in (m, items.filter { Meals.of($0) == m }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }) }.filter { $0.1 > 0 }
        return VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: left >= 0 ? "Left to eat" : "Over today", color: Theme.heroLabel)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.int(abs(left)))
                    .font(.system(size: 62, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: abs(left)))
                Text("kcal").font(.headline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Theme.track
                        HStack(spacing: 2) {
                            ForEach(byMeal, id: \.0) { part in
                                Theme.meal(part.0).frame(width: max(4, g.size.width * part.1 / scale - 2))
                            }
                        }
                        if eaten > budget, budget > 0 {
                            Rectangle().fill(.white).frame(width: 2).offset(x: g.size.width * budget / scale - 1)
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())
                if !byMeal.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(byMeal, id: \.0) { part in
                            HStack(spacing: 4) {
                                Circle().fill(Theme.meal(part.0)).frame(width: 7, height: 7)
                                Text(part.0).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                stat(Fmt.int(eaten), "eaten")
                Spacer()
                stat(store.proteinGoal.map { "\(Int(protein.rounded())) / \(Int($0))g" } ?? "\(Int(protein.rounded()))g", "protein")
                Spacer()
                stat(Fmt.int(budget), "budget")
            }
            if moreOpen {
                VStack(alignment: .leading, spacing: 12) {
                    macroBars(protein: protein, carbs: m.c, fat: m.f)
                    if offset == 0, let st = Steps.shared.today {
                        Label(st.formatted() + " steps today", systemImage: "figure.walk").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // carbs, fat and steps fold away under this arrow
            Button { withAnimation(.snappy) { moreOpen.toggle() } } label: {
                Image(systemName: "chevron.down").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(moreOpen ? 180 : 0))
                    .frame(maxWidth: .infinity).frame(height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -6).padding(.bottom, -8)
            .accessibilityLabel(moreOpen ? "Hide details" : "Show carbs, fat and steps")
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .tourSpot(.hero)
        .overlay(alignment: .topTrailing) { if offset == 0 { cheatButton.padding(.top, 10).padding(.trailing, 12) } }
        .animation(.snappy, value: eaten)
        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            withAnimation(.snappy) { offset = v.translation.width > 0 ? offset - 1 : min(0, offset + 1) }
        })
    }

    /// Protein, carbs and fat so far, each against its goal when one's set (Plan and budget).
    private func macroBars(protein: Double, carbs: Double, fat: Double) -> some View {
        let goals = dict(store.doc["goals"])
        let rows: [(String, Double, Double?, Color)] = [
            ("Protein", protein, store.proteinGoal, Color(red: 0.36, green: 0.82, blue: 0.62)),
            ("Carbs", carbs, pos(goals["c"]), Color(red: 0.98, green: 0.78, blue: 0.40)),
            ("Fat", fat, pos(goals["f"]), Color(red: 0.93, green: 0.55, blue: 0.70))
        ]
        return HStack(spacing: 12) {
            ForEach(rows, id: \.0) { r in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 0) {
                        Text("\(Int(r.1.rounded()))").font(.subheadline.weight(.heavy)).monospacedDigit()
                        Text(r.2.map { " / \(Int($0))g" } ?? "g").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Theme.track
                            r.3.frame(width: g.size.width * min(1, r.2.map { r.1 / max($0, 1) } ?? min(1, r.1 / 100)))
                        }
                    }
                    .frame(height: 5).clipShape(Capsule())
                    Text(r.0).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The logo in the panel's corner: plan your next meal, or on the cheat day itself, plan the day (cheekily).
    private var cheatButton: some View {
        let isToday = store.nextCheat?.date == store.today
        return Button { if isToday { showCheat = true } else { showPlanner = true } } label: {
            // the same blue pill as Same as yesterday and Save as meal; orange on the cheat day
            HStack(spacing: 8) {
                LogoMark().fill(isToday ? Theme.warn : Theme.accent).frame(width: 28, height: 15)
                Text("Plan").font(.subheadline.weight(.bold))
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
        .tint(isToday ? Theme.warn : Theme.accent)
        .tourSpot(.plan)
        .accessibilityLabel(isToday ? "Plan your cheat day" : "Plan a meal")
    }

    private func note(_ text: String) {
        withAnimation(.snappy) { badgeNote = text }
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); withAnimation { if badgeNote == text { badgeNote = nil } } }
    }

    /// New achievements (and finished weekly goals) get banked, with a note at the top.
    private func checkBadges() {
        let fresh = store.checkBadges()
        guard let first = fresh.first else { return }
        let xp = fresh.reduce(0) { $0 + $1.xp }
        let text = "\(first.icon) \(fresh.count > 1 ? "\(fresh.count) achievements" : first.name) · +\(xp) XP"
        withAnimation(.snappy) { badgeNote = text }
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); withAnimation { if badgeNote == text { badgeNote = nil } } }
    }

    /// A new rank since last time: celebrate it once. The first time, just remember where they are.
    private func checkRank() {
        guard store.lastSynced != nil else { return }   // not before the record has loaded
        let now = store.rank, seen = UserDefaults.standard.integer(forKey: "rank.seen")
        if seen == 0 { UserDefaults.standard.set(now.level, forKey: "rank.seen"); return }
        if now.level > seen {
            UserDefaults.standard.set(now.level, forKey: "rank.seen")
            rankUp = now
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.weight(.heavy)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: meals

    @ViewBuilder
    private func mealSection(_ meal: String) -> some View {
        let lines = items.filter { Meals.of($0) == meal }.map { Line(id: str($0["id"]).isEmpty ? UUID().uuidString : str($0["id"]), item: $0) }
        let total = lines.reduce(0) { $0 + (num($1.item["kcal"]) ?? 0) }
        let again = offset == 0 && lines.isEmpty ? (store.pastDay(DayKey.shift(store.today, days: -1))?.items.filter { Meals.of($0) == meal } ?? []) : []
        if offset == 0 || !lines.isEmpty {
            Section {
                ForEach(lines) { line in
                    Button { tap(line.item, meal: meal) } label: { FoodRow(item: line.item, hint: offset == 0 ? .open : .add) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if offset == 0 {
                                Button(role: .destructive) { withAnimation { store.delete(line.id) } } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { sendingItem = line.item } label: { Label("Send", systemImage: "paperplane.fill") }.tint(Theme.accent)
                        }
                        .contextMenu {
                            Button { sendingItem = line.item } label: { Label("Send to a friend", systemImage: "paperplane") }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if offset == 0 {
                    Button { addChoice = MealChoice(id: meal) } label: {
                        Label("Add \(meal.lowercased())", systemImage: "plus.circle.fill").foregroundStyle(Theme.accent)
                    }
                    // the tour outlines the whole row, so it's measured on the row's background, not the label
                    .listRowBackground(Color(.secondarySystemGroupedBackground).modifier(TourSpotIf(spot: .meal, on: meal == Meals.all.first)))
                }
            } header: {
                HStack {
                    Text(meal).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                    Spacer()
                    if offset == 0 && lines.count >= 2 {
                        // where Same as yesterday sits on an empty meal
                        Button { savingMeal = meal } label: {
                            HStack(spacing: 5) { Image(systemName: "bookmark"); Text("Save as meal") }.font(.caption.weight(.bold)).lineLimit(1).fixedSize()   // never squeezed to "Save as m…"
                        }
                        .accessibilityLabel("Save this \(meal.lowercased()) as a meal")
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).textCase(nil)
                    }
                    if total > 0 {
                        Text("\(Fmt.int(total)) kcal").font(.subheadline.weight(.bold)).foregroundStyle(.secondary).textCase(nil)
                    } else if !again.isEmpty {
                        let kcal = again.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
                        Button {
                            withAnimation(.snappy) { store.addAll(again, meal: meal, label: "Added yesterday's \(meal.lowercased())") }
                        } label: {
                            HStack(spacing: 5) { Image(systemName: "arrow.counterclockwise"); Text("Same as yesterday · \(Fmt.int(kcal))") }.font(.caption.weight(.bold)).lineLimit(1)
                        }
                        .accessibilityLabel("Add yesterday's \(meal.lowercased()) again: \(again.map { str($0["name"]) }.joined(separator: ", "))")
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).textCase(nil)
                    }
                }
            } footer: {
                // the tip sits under the card, so the card keeps its rounded corners
                if !lines.isEmpty && meal == Meals.all.first(where: { m in items.contains { Meals.of($0) == m } }) {
                    Text(offset == 0 ? "Tap a food to change the amount. Swipe left to delete." : "Tap a food to add it to today.")
                }
            }
        }
    }

    /// The foods you ticked from this meal as one saved meal, at today's amounts, so it can be added again in one go.
    private func saveAsMeal(_ meal: String, name: String, picked: Set<String>) {
        let its = items.filter { Meals.of($0) == meal && picked.contains(str($0["id"])) }.map { it -> JSON in
            var c = it; c["id"] = uid(); c.removeValue(forKey: "meal"); c.removeValue(forKey: "addedAt"); return c
        }
        guard !its.isEmpty else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        store.perform(["type": "saveMeal", "meal": ["id": uid(), "name": name.isEmpty ? "My \(meal.lowercased())" : name, "portions": 1,
                                                     "items": its, "saved": true, "updatedAt": ISO.now()] as JSON])
        note("Saved: find it in Add, under your meals")
    }

    private func tap(_ item: JSON, meal: String) {
        if offset == 0 {
            editing = EditTarget(basis: FoodMath.basisOf(item), kcal: num(item["kcal"]), editId: str(item["id"]), meal: meal)
        } else {
            pastItem = item; showPast = true
        }
    }

    private func undoBanner(_ u: Store.Undo) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(u.label).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo") { withAnimation(.snappy) { store.undoLast() } }.font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .padding(.leading, 16).padding(.trailing, 96).padding(.bottom, 22)   // clear of the + button
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var addButton: some View {
        Button { addChoice = MealChoice(id: Meals.now) } label: {
            Image(systemName: "plus").font(.title2.weight(.bold)).foregroundStyle(.black)
                .frame(width: 62, height: 62).background(Theme.accent, in: Circle())
                .tourSpot(.add)
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        }
        .padding(.trailing, 22).padding(.bottom, 16)
        .accessibilityLabel("Add food")
    }
}

struct FoodRow: View {
    enum Hint { case none, open, add }
    let item: JSON
    var hint: Hint = .none
    var body: some View {
        let kcal = num(item["kcal"]) ?? 0
        HStack(spacing: 12) {
            FoodDot(name: str(item["name"]))
            VStack(alignment: .leading, spacing: 2) {
                Text(str(item["name"])).font(.body.weight(.semibold)).lineLimit(2)
                let detail = FoodMath.amountText(item, kcal: kcal)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Text(Fmt.int(kcal)).font(.body.weight(.bold)).monospacedDigit()
            switch hint {
            case .open: Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            case .add: Image(systemName: "plus.circle").font(.title3).foregroundStyle(Theme.accent)
            case .none: EmptyView()
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// Save as meal: a name, and tick which of the meal's foods go in (all of them to start).
private struct SaveMealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let foods: [JSON]
    var save: (String, Set<String>) -> Void
    @State private var picked: Set<String>

    init(name: String, foods: [JSON], save: @escaping (String, Set<String>) -> Void) {
        _name = State(initialValue: name)
        self.foods = foods
        self.save = save
        _picked = State(initialValue: Set(foods.map { str($0["id"]) }))
    }

    var body: some View {
        let total = foods.filter { picked.contains(str($0["id"])) }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        NavigationStack {
            List {
                Section { TextField("Name", text: $name) } header: { Text("Name") }
                Section {
                    ForEach(foods.indices, id: \.self) { i in
                        let id = str(foods[i]["id"]), on = picked.contains(id)
                        Button {
                            if on { picked.remove(id) } else { picked.insert(id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title2)
                                    .foregroundStyle(on ? Theme.accent : Color.secondary)
                                FoodRow(item: foods[i])
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("What's in it") } footer: { Text("Next time it's one tap: it shows in Add with your saved meals.") }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Save as a meal")
            .keyboardDone()
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: picked)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { save(name, picked); dismiss() } label: {
                    Text(picked.isEmpty ? "Tick at least one food" : "Save \(picked.count) food\(picked.count == 1 ? "" : "s") · \(Fmt.int(total)) kcal")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 16)).tint(Theme.accent).foregroundStyle(.black)
                .disabled(picked.isEmpty)
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// How much: count, weigh or calories, with the meal, then add (or save a change).
/// After midnight: still yesterday, or a new day? Food stays on yesterday until you say, or until 5am.
private struct LateNightCard: View {
    private var store: Store { Store.shared }
    private func name(_ d: String) -> String { DayKey.date(d).formatted(.dateTime.weekday(.wide)) }

    var body: some View {
        let todayName = Date().formatted(.dateTime.weekday(.wide))
        switch store.lateNight {
        case .stillYesterday(let d):
            card("It's after midnight", "Still \(name(d)) for you? Food you add goes on \(name(d)) until you say, or until 5am.",
                 keep: "Keep it as \(name(d))", { store.keepYesterday(d) }, new: "Start \(todayName)", { store.startNewDay() })
        case .keptYesterday(let d):
            Section {
                HStack {
                    Image(systemName: "moon.stars.fill").foregroundStyle(Theme.accent)
                    Text("Still \(name(d)) until 5am").font(.subheadline)
                    Spacer()
                    Button("Start \(todayName)") { withAnimation { store.startNewDay() } }.font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                }
            }
        case .canBringBack(let d):
            card("Still up?", "Midnight started \(todayName). Still \(name(d)) for you? Bring it back and keep logging on it until 5am.",
                 keep: "Bring \(name(d)) back", { store.bringBackYesterday(d) }, new: "No, it's \(todayName)", { store.perform(["type": "set", "key": "dayRolled", "value": DayKey.string(Date())]) })
        case .none:
            EmptyView()
        }
    }

    private func card(_ title: String, _ body: String, keep: String, _ onKeep: @escaping () -> Void, new: String, _ onNew: @escaping () -> Void) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "moon.stars.fill").font(.headline).foregroundStyle(Theme.accent)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { withAnimation { onKeep() } } label: { Text(keep).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.borderedProminent).foregroundStyle(.black)
                    Button { withAnimation { onNew() } } label: { Text(new).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.bordered)
                }
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }
            .padding(.vertical, 4)
        }
    }
}

/// Pick a friend to send one of your foods to (kept out of TodayView's long modifier chain).
private struct SendFoodDialog: ViewModifier {
    @Binding var item: JSON?
    var note: (String) -> Void
    func body(content: Content) -> some View {
        content
            .confirmationDialog("Send \(str(item?["name"])) to…", isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }), titleVisibility: .visible) {
                ForEach(Friends.shared.people) { p in
                    Button(p.name) {
                        guard let it = item else { return }
                        Task {
                            do { try await Friends.shared.send(it, to: p); note("Sent \(str(it["name"])) to \(p.name)") }
                            catch { note("Couldn't send: \(error.localizedDescription)") }
                        }
                    }
                }
            } message: { Text(Friends.shared.people.isEmpty ? "Add a friend first, in the Friends tab." : "It'll wait on their Today, ready to add in one tap.") }
            .task { if Friends.shared.people.isEmpty { await Friends.shared.load() } }
    }
}

struct AmountView: View {
    enum Mode: String, CaseIterable, Identifiable { case count = "Count", grams = "Weigh", kcal = "Calories"; var id: String { rawValue } }

    let target: EditTarget
    let finish: () -> Void
    @State private var meal: String
    @State private var mode: Mode
    @State private var kcal: Double
    @State private var gramsText = ""
    @State private var kcalText = ""
    @State private var nameText = ""
    @State private var change = ""
    @State private var tweaking = false
    @State private var tweakNote: String?
    private var store: Store { Store.shared }
    private let conv: FoodMath.Conv
    private var asksName: Bool { target.basis["askName"] as? Bool == true }

    init(target: EditTarget, finish: @escaping () -> Void) {
        self.target = target
        self.finish = finish
        let c = FoodMath.conv(target.basis)
        conv = c
        _meal = State(initialValue: target.meal)
        // meat and fish start on Weigh: "1 thigh" is 100 g in one country and 180 g in another
        let kind = FoodKind.of(str(target.basis["name"])), byWeight = [.meat, .poultry, .fish].contains(kind) && c.kcalPer100 != nil
        let start: Mode = byWeight ? .grams
            : c.countKcal != nil && (c.countLabel != "serving" || c.kcalPer100 == nil) ? .count : (c.kcalPer100 != nil ? .grams : .kcal)
        _mode = State(initialValue: start)
        let fallback = c.countKcal ?? c.kcalPer100.map { k in k * (pos(target.basis["servingSize"]) ?? 100) / 100 } ?? 0
        _kcal = State(initialValue: target.kcal ?? fallback)
    }

    private var name: String { str(target.basis["name"]) }

    private func macro(_ label: String, _ grams: Double, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(Fmt.one(grams))g").font(.headline.weight(.heavy)).monospacedDigit().contentTransition(.numericText(value: grams))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.4), lineWidth: 1))
    }
    private func macroDot(_ label: String, _ grams: Double, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text("\(Fmt.one(grams))g").font(.subheadline.weight(.bold)).monospacedDigit().contentTransition(.numericText(value: grams))
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var modes: [Mode] { [conv.countKcal != nil ? Mode.count : nil, conv.kcalPer100 != nil ? Mode.grams : nil, Mode.kcal].compactMap { $0 } }
    private var unit: String { str(target.basis["unit"]).isEmpty ? "g" : str(target.basis["unit"]) }
    private var leftAfter: Double { leftBefore - kcal }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        FoodDot(name: name, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            if asksName { TextField("What is it?", text: $nameText).font(.title3.bold()) }
                            else { Text(name).font(.title3.bold()).lineLimit(2) }
                            if let per = perText { Text(per).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    Text(Fmt.int(kcal))
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText(value: kcal))
                        .padding(.top, 10)
                    Text(leftAfter >= 0 ? "kcal · \(Fmt.int(leftAfter)) left after this" : "kcal · \(Fmt.int(-leftAfter)) over your day")
                        .font(.footnote.weight(.semibold)).foregroundStyle(leftAfter >= 0 ? Color.secondary : Theme.warn)
                    if let m = FoodMath.macros(target.basis, kcal: kcal) {
                        HStack(spacing: 14) {
                            macroDot("protein", m.p, Color(red: 0.36, green: 0.82, blue: 0.62))
                            macroDot("carbs", m.c, Color(red: 0.98, green: 0.78, blue: 0.40))
                            macroDot("fat", m.f, Color(red: 0.93, green: 0.55, blue: 0.70))
                        }
                        .padding(.top, 8)
                        .animation(.snappy, value: kcal)
                    } else {
                        Text("No protein, carbs or fat on this one").font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
                    }
                    if let note = target.note, !note.isEmpty {
                        Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    if let vary = brandsVary {
                        Label("Brands vary a lot for \(vary). This is a typical one: scan your pack's barcode or label for exact numbers.", systemImage: "barcode.viewfinder")
                            .font(.footnote).foregroundStyle(Theme.heroLabel)
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                Picker("Meal", selection: $meal) { ForEach(Meals.all, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            }
            if target.editId == nil, let s = Swaps.pick(for: name, kcal: kcal) {
                Section {
                    HStack(spacing: 12) {
                        FoodDot(name: s.name, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.weight(.bold))
                            Text("\(s.why) · saves \(Fmt.int(s.saves)) kcal").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Have this") { store.add(s.basis, kcal: s.kcal, meal: meal); finish() }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    }
                } header: { Text("Healthier pick") } footer: { Text("Or add yours as normal below. No judgement.") }
            }
            Section {
                if modes.count > 1 {
                    Picker("How", selection: $mode) { ForEach(modes) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                }
                switch mode {
                case .count: countControls
                case .grams: gramControls
                case .kcal: kcalControls
                }
            }
            .onChange(of: mode) { _, _ in syncTexts() }   // whichever way it was set, the others show the same amount
            if let id = target.editId {
                Section {
                    HStack {
                        TextField("It was a large one, no sauce…", text: $change).submitLabel(.done).onSubmit { tweak(id) }
                        if tweaking { ProgressView() }
                        else if !change.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button { tweak(id) } label: { Image(systemName: "sparkles") }.buttonStyle(.borderless)
                        }
                    }
                    if let tweakNote { Text(tweakNote).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Something different?") } footer: { Text("Say what changed and the AI updates the food: its name, calories and macros.") }
                FixNumbers(id: id) { finish() }
            }
            Section {
                Button { save() } label: {
                    Text(target.editId == nil ? "Add to \(meal)" : "Save").font(.headline).frame(maxWidth: .infinity)
                }
                .disabled(kcal <= 0)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }   // centred text would start the line halfway
                if let id = target.editId {
                    Button(role: .destructive) { store.delete(id); finish() } label: { Text("Remove from today").frame(maxWidth: .infinity) }
                }
            }
        }
        .keyboardDone()
        .navigationTitle(target.editId == nil ? "How much?" : "Change amount")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: kcal)
        .sensoryFeedback(.selection, trigger: kcal)
        .onAppear { syncTexts() }
    }

    /// A generic food whose brands differ a lot (cocoa from 228 to 423 kcal per 100 g): worth scanning yours.
    private var brandsVary: String? {
        guard str(target.basis["brand"]).isEmpty, !["barcode", "label", "manual", "meal"].contains(str(target.basis["source"])) else { return nil }
        let n = name.lowercased()
        let kinds: [(String, [String])] = [("cocoa", ["cocoa", "cacao"]), ("protein powder", ["protein powder", "whey", "protein shake"]),
                                           ("cheese", ["cheese"]), ("yoghurt", ["yoghurt", "yogurt"]), ("granola", ["granola", "muesli"]),
                                           ("bread", ["bread", "wrap"]), ("sausages", ["sausage"])]
        return kinds.first { $0.1.contains(where: { n.contains($0) }) }?.0
    }

    private var perText: String? {
        if let c = conv.countKcal, let label = conv.countLabel { return "\(Fmt.int(c)) kcal per \(label)" }
        if let k = conv.kcalPer100 { return "\(Fmt.int(k)) kcal per 100 \(unit)" }
        return nil
    }

    /// What's left today before this food.
    private var leftBefore: Double {
        let others = store.todayItems.filter { str($0["id"]) != (target.editId ?? "") }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }
        return store.budgetToday - others
    }

    /// Four big tap targets with their calories: 1, 2, 3, 4 of it, or the usual weights.
    private func tiles(_ items: [(amount: String, label: String, kcal: Double)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                let t = items[i], on = abs(kcal - t.kcal) < 0.5
                Button { kcal = t.kcal; syncTexts() } label: {
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(t.amount).font(.title3.weight(.heavy)).monospacedDigit()
                            Text(t.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text("\(Fmt.int(t.kcal)) kcal").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(on ? Theme.accent.opacity(0.18) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? Theme.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(t.amount) \(t.label), \(Fmt.int(t.kcal)) calories")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var fitsNote: some View {
        if let fit = fitsLine {
            Text(fit).font(.footnote.weight(.semibold)).foregroundStyle(leftBefore > 0 ? Color.secondary : Theme.warn)
        }
    }

    /// "You could have up to 6 biscuits today" (or grams), from what's left.
    private var fitsLine: String? {
        let left = leftBefore
        guard left > 0 else { return "Today's budget is used up, so any of this goes over." }
        if let each = conv.countKcal, each > 0 {
            let n = floor(left / each)
            let word = conv.countLabel ?? "piece"
            return n >= 1 ? "Up to \(Fmt.int(n)) \(FoodMath.plural(n, word)) fit in the \(Fmt.int(left)) kcal you have left" : "Even 1 \(word) is more than the \(Fmt.int(left)) kcal you have left"
        }
        if let k100 = conv.kcalPer100, k100 > 0 {
            let g = floor(left / k100 * 100 / 5) * 5
            return "Up to \(Fmt.int(g)) \(unit) fits in the \(Fmt.int(left)) kcal you have left"
        }
        return nil
    }

    @ViewBuilder private var countControls: some View {
        if let each = conv.countKcal, each > 0 {
            let count = kcal / each
            let label = conv.countLabel ?? "piece"
            tiles([1.0, 2, 3, 4].map { n in (Fmt.one(n), FoodMath.plural(n, label), n * each) })
            Stepper("\(Fmt.one(count)) \(FoodMath.plural(count, label))", onIncrement: { kcal = (count + 0.5) * each; syncTexts() },
                    onDecrement: { kcal = max(0.5, count - 0.5) * each; syncTexts() })
            // the weight behind a count, so a bigger or smaller one can be weighed instead
            if let k100 = conv.kcalPer100, k100 > 0 {
                Text("1 \(label) ≈ \(Fmt.int(each / k100 * 100)) \(unit)\(Region.current == .uk ? "" : " (yours may differ: Weigh is exact)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            fitsNote
        }
    }

    @ViewBuilder private var gramControls: some View {
        if let k100 = conv.kcalPer100, k100 > 0 {
            let grams = kcal / k100 * 100
            let serving = pos(target.basis["servingSize"])
            let options: [Double] = serving.map { s in [s / 2, s, s * 1.5, s * 2].map { nice($0) } } ?? (unit == "ml" ? [100, 250, 330, 500] : [50, 100, 150, 200])
            tiles(Array(Array(Set(options)).sorted().prefix(4)).map { g in (Fmt.one(g), unit, g * k100 / 100) })
            HStack {
                TextField("Amount", text: $gramsText).keyboardType(.decimalPad)
                    .onChange(of: gramsText) { _, t in if let g = Double(t.replacingOccurrences(of: ",", with: ".")), abs(g - grams) > 0.05 { kcal = g * k100 / 100 } }
                Text(unit).foregroundStyle(.secondary)
            }
            fitsNote
        }
    }

    private var kcalControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Calories", text: $kcalText).keyboardType(.numberPad)
                    .onChange(of: kcalText) { _, t in if let k = Double(t), abs(k - kcal) > 0.5 { kcal = k; syncGrams() } }
                Text("kcal").foregroundStyle(.secondary)
            }
            let eq = [conv.kcalPer100.flatMap { k in k > 0 ? "\(Fmt.int(kcal / k * 100)) \(unit)" : nil },
                      conv.countKcal.flatMap { e in e > 0 ? "\(Fmt.one(kcal / e)) \(FoodMath.plural(kcal / e, conv.countLabel ?? "piece"))" : nil }].compactMap { $0 }
            if !eq.isEmpty { Text("That's about " + eq.joined(separator: " or ")).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.subheadline.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 9)
                .background(on ? Theme.accent : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func nice(_ g: Double) -> Double { g < 50 ? (g / 5).rounded() * 5 : g < 200 ? (g / 10).rounded() * 10 : (g / 25).rounded() * 25 }

    /// Only the grams box (so typing calories isn't interrupted).
    private func syncGrams() {
        if let k100 = conv.kcalPer100, k100 > 0 { gramsText = Fmt.one(kcal / k100 * 100) }
    }

    private func syncTexts() {
        if let k100 = conv.kcalPer100, k100 > 0 { gramsText = Fmt.one(kcal / k100 * 100) }
        kcalText = String(Int(kcal.rounded()))
    }

    /// "It was a large one": the AI updates this entry, then the sheet closes.
    private func tweak(_ id: String) {
        let said = change.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty, !tweaking else { return }
        var item = target.basis; item["kcal"] = kcal; item["id"] = id
        tweaking = true; tweakNote = nil
        Task {
            defer { tweaking = false }
            do {
                let r = try await Tweak.ask(item, change: said)
                store.perform(["type": "tweak", "id": id, "item": r.item])
                tweakNote = r.reply.isEmpty ? "Updated." : r.reply
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                finish()
            } catch { tweakNote = error.localizedDescription }
        }
    }

    private func save() {
        var basis = target.basis
        if asksName {   // read off a table, which doesn't say what the food is
            let n = nameText.trimmingCharacters(in: .whitespaces)
            basis["name"] = n.isEmpty ? "Scanned food" : n
        }
        basis.removeValue(forKey: "askName")
        if let id = target.editId { store.edit(id, kcal: kcal, meal: meal) } else { store.add(basis, kcal: kcal, meal: meal) }
        finish()
    }
}

/// Type the right numbers into a logged food (when a scan or the AI got it wrong). It keeps its place, meal and time.
struct FixNumbers: View {
    let id: String
    let done: () -> Void
    @State private var open = false
    @State private var name = ""
    @State private var kcal = ""
    @State private var p = ""
    @State private var c = ""
    @State private var f = ""
    private var store: Store { Store.shared }
    private var item: JSON? { store.todayItems.first { str($0["id"]) == id } }

    var body: some View {
        Section {
            DisclosureGroup("Fix the numbers", isExpanded: $open) {
                TextField("Name", text: $name)
                row("Calories", $kcal, "kcal")
                row("Protein", $p, "g")
                row("Carbs", $c, "g")
                row("Fat", $f, "g")
                Button("Save these numbers") { save() }.fontWeight(.bold).disabled((Self.d(kcal) ?? 0) <= 0)
            }
            .onChange(of: open) { _, o in if o { fill() } }
        } footer: { Text("For when the label, scan or AI got it wrong. Leave a macro empty if you don't know it.") }
    }

    private func row(_ label: String, _ text: Binding<String>, _ unit: String) -> some View {
        HStack {
            Text(label)
            TextField("–", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
        }
    }

    private static func d(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }

    private func fill() {
        guard let it = item else { return }
        let k = num(it["kcal"]) ?? 0
        name = str(it["name"]); kcal = Fmt.int(k)
        if let m = FoodMath.macros(it, kcal: k) { p = Fmt.one(m.p); c = Fmt.one(m.c); f = Fmt.one(m.f) }
    }

    private func save() {
        guard let it = item, let k = Self.d(kcal), k > 0 else { return }
        let oldK = num(it["kcal"]) ?? 0
        let grams = num(it["grams"]) ?? FoodMath.amounts(it, kcal: oldK).grams
        let hasMacros = !(p.isEmpty && c.isEmpty && f.isEmpty)
        let pv = Self.d(p) ?? 0, cv = Self.d(c) ?? 0, fv = Self.d(f) ?? 0
        var b = FoodMath.basisOf(it)
        for key in ["kcalPer100", "p100", "c100", "f100", "pServ", "cServ", "fServ", "servingSize", "grams", "countKcal", "pieceKcal"] { b.removeValue(forKey: key) }
        b["name"] = name.trimmingCharacters(in: .whitespaces).isEmpty ? str(it["name"]) : name.trimmingCharacters(in: .whitespaces)
        b["unitLabel"] = "portion"; b["kcalPerServing"] = k.rounded()
        if hasMacros { b["pServ"] = pv; b["cServ"] = cv; b["fServ"] = fv }
        if let g = grams, g > 0 {
            b["servingSize"] = g.rounded(); b["grams"] = g.rounded(); b["kcalPer100"] = (k / g * 1000).rounded() / 10
            if hasMacros { b["p100"] = pv / g * 100; b["c100"] = cv / g * 100; b["f100"] = fv / g * 100 }
        }
        b["kcal"] = Int(k.rounded())
        store.perform(["type": "tweak", "id": id, "item": b])
        done()
    }
}
