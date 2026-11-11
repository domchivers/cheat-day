import SwiftUI

/// Chips that wrap onto new lines.
struct Flow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x + z.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += z.width + spacing; row = max(row, z.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x + z.width > b.maxX, x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}

struct Chip: View {
    let text: String
    let on: Bool
    var quiet = false   // grey when picked, as on the chart's chips, rather than the accent
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            Text(text).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(on ? (quiet ? Color(.systemGray3) : Theme.accent) : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? (quiet ? Color.primary : Theme.onAccent) : (quiet ? Color.secondary : Color.primary))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }
}

/// One big tappable choice with a symbol and a line under it.
struct ChoiceCard: View {
    let title: String
    let sub: String
    let symbol: String
    let on: Bool
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(on ? Theme.onAccent : Theme.accent)
                    .frame(width: 42, height: 42).background(on ? Theme.accent : Theme.track, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(sub).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(on ? Theme.accent : Color.secondary)
            }
            .padding(14)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(on ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }
}

/// Sign-up: what you're after, about you, what you love eating, a normal day, how you train, your cheat day, then the
/// plan. Laid out like Progress and Your plan; from About you on, the budget so far sits above Next.
struct OnboardingView: View {
    var firstRun = true
    var onDone: () -> Void
    @State private var step = 0
    @State private var forward = true
    @State private var loaded = false
    @State private var q = PlanInput()
    @State private var goalWeight: Double?
    @State private var age: Int?      // nothing is assumed: these start empty and Next waits for them
    @State private var height: Int?
    @State private var wheel: String?   // the row whose wheel is open
    @State private var cuisines: Set<String> = []
    @State private var loves: Set<String> = []
    @State private var avoid: Set<String> = []
    @State private var newLove = ""
    @State private var newAvoid = ""
    @State private var usual = ["", "", "", ""]
    @State private var usualKcal: Double?
    @State private var usualProtein: Double?
    @State private var usualNote = ""
    @State private var estimating = false
    @State private var gymDays = 3
    @State private var experience = "some"
    @State private var kit = "gym"
    @State private var extras: Set<String> = []
    @State private var saveRoutines = true
    @State private var ideas: [JSON] = []
    @State private var ideasState = 0   // 0 not asked, 1 asking, 2 got them, 3 couldn't
    @State private var problem: String?
    private var store: Store { Store.shared }

    private let titles = ["Goals", "About you", "Food", "Normal day", "Training", "Cheat days", "Your plan"]
    private var last: Int { titles.count - 1 }
    private let allCuisines = ["Chinese", "Thai", "Japanese", "Korean", "Vietnamese", "Indian", "Italian", "Mexican", "Middle Eastern", "Greek", "Pub classics", "Sunday roast", "Aussie BBQ", "Fish and chips"]
    private let allLoves = ["Pizza", "Burgers", "Dumplings", "Curry", "Pasta", "Sushi", "Chips", "Fried chicken", "Kebabs", "Noodles", "Chocolate", "Ice cream", "Biscuits", "Cake", "Crisps", "Cheese", "Beer", "Wine"]
    private let allAvoid = ["Vegetarian", "Vegan", "Halal", "No pork", "No beef", "No seafood", "No dairy", "Gluten free", "Nut allergy", "No eggs", "No mushrooms", "Not spicy"]
    private let allExtras = ["Walking", "Running", "Cycling", "Swimming", "Classes", "Sport", "Yoga"]
    private let meals = ["Breakfast", "Lunch", "Dinner", "Snacks and drinks"]
    private let hints = ["Flat white, 2 toast with peanut butter", "Meal deal, or leftovers", "Stir fry, takeaway on Fridays", "Biscuits at work, a few beers at the weekend"]

    var body: some View {
        VStack(spacing: 0) {
            top
            ScrollView {
                Group {
                    switch step {
                    case 0: goalsStep
                    case 1: aboutStep
                    case 2: foodStep
                    case 3: dayStep
                    case 4: trainingStep
                    case 5: cheatStep
                    default: planStep
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 30)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .scrollDismissesKeyboard(.interactively)
            live
            bottom
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { if !loaded { prefill(); loaded = true } }
        .keyboardDone()
    }

    // MARK: the frame

    /// A round button (leave on the first step, back after it), the steps as bars, and the count or Skip.
    private var top: some View {
        HStack(spacing: 12) {
            Button { if step == 0 { firstRun ? skip() : onDone() } else { go(-1) } } label: {
                Image(systemName: step == 0 ? "xmark" : "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38).background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel(step == 0 ? (firstRun ? "Skip for now" : "Cancel") : "Back")
            HStack(spacing: 5) {
                ForEach(titles.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Theme.accent : Color(.tertiarySystemFill)).frame(height: 4)
                }
            }
            if step == 2 || step == 3 {   // food and a normal day help, but the numbers don't need them
                Button("Skip") { go(1) }.font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
            } else {
                Text("\(step + 1) of \(titles.count)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
        .animation(.snappy, value: step)
    }

    private var ready: Bool { step != 1 || (age != nil && height != nil) }

    private var bottom: some View {
        Button {
            if step == last { finish() } else { go(1) }
        } label: {
            Text(!ready ? "Add your age and height" : step == last ? "Start my plan" : "Next")
                .font(.headline.weight(.heavy)).foregroundStyle(ready ? Theme.onAccent : Color.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(ready ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        }
        .buttonStyle(.plain).disabled(!ready)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .background(Theme.bg)
    }

    /// The budget so far and where it leads, above Next from About you to the cheat day: it moves as you answer.
    @ViewBuilder private var live: some View {
        if (1...5).contains(step), age != nil, height != nil {
            let r = Plan.compute(input)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.int(Double(r.everyday))).font(.headline.weight(.heavy)).monospacedDigit().contentTransition(.numericText())
                Text("kcal a day").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(liveNote(r)).font(.footnote).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 14).padding(.top, 6)
            .animation(.snappy, value: r.everyday)
            .accessibilityElement(children: .combine)
        }
    }

    private func liveNote(_ r: PlanResult) -> String {
        if step == 5, let cheat = r.cheat { return "\(Fmt.int(Double(cheat))) on \(Calendar.current.weekdaySymbols[q.cheatDay])" }
        if let g = goalWeight, let d = Plan.reach(g, from: q.weight, rate: r.rate) { return "\(Fmt.one(g)) kg by \(d.formatted(.dateTime.day().month(.abbreviated)))" }
        return ""
    }

    private func go(_ by: Int) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if step == 0 && by < 0 { onDone(); return }
        // age and height are kept as soon as they're given, so leaving part way doesn't lose them
        if step == 1, by > 0, age != nil, height != nil {
            store.perform(["type": "set", "key": "profile", "value": ["sex": q.sex, "age": Int(q.age), "height": q.height] as JSON])
        }
        forward = by > 0
        wheel = nil
        withAnimation(.snappy) { step = max(0, min(last, step + by)) }
        if step == last && ideasState == 0 { Task { await askIdeas() } }
    }

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 30, weight: .heavy))
            Text(sub).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 6)
    }

    private func label(_ t: String, _ right: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.headline.weight(.heavy)).foregroundStyle(.secondary)
            Spacer()
            if !right.isEmpty { Text(right).font(.footnote).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 4).padding(.top, 12)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 12) { content() }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Rows in one card, edge to edge: the choices of a question, or a short form.
    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    private var line: some View { Divider().padding(.leading, 14) }

    /// One choice in a group: a round symbol, a title with a line under it, and a tick when it's the one picked.
    private func option(_ title: String, _ sub: String, _ symbol: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(on ? Theme.onAccent : Theme.accent)
                    .frame(width: 38, height: 38).background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.bold))
                    Text(sub).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .sensoryFeedback(.selection, trigger: on)
    }

    private func numberRow(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(title).font(.body.weight(.semibold))
            Spacer()
            TextField(title, value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                .font(.body.weight(.heavy))
            Text(unit).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
    }

    /// A whole number set on a wheel that opens under its row; "Add" until it's been set.
    private func wheelRow(_ title: String, _ value: Int?, _ unit: String, range: ClosedRange<Int>, start: Int, set: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 0) {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                withAnimation(.snappy) { if value == nil { set(start) }; wheel = wheel == title ? nil : title }
            } label: {
                HStack {
                    Text(title).font(.body.weight(.semibold))
                    Spacer()
                    Text(value.map { "\($0)" } ?? "Add").font(.body.weight(.heavy)).monospacedDigit()
                        .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : wheel == title ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                    Text(unit).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 13).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if wheel == title {
                Picker(title, selection: Binding(get: { value ?? start }, set: set)) {
                    ForEach(Array(range), id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.wheel).frame(height: 120)
            }
        }
    }

    /// The week as bars: every day's budget, the cheat day the tall one. On the cheat day step a tap picks the day.
    private func weekBars(_ r: PlanResult, pick: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                let on = r.cheat != nil && q.cheatDay == d
                let v = Double(on ? (r.cheat ?? r.everyday) : r.everyday)
                // a real button (a tap gesture on the column didn't take taps); it only answers on the cheat day step
                Button { withAnimation(.snappy) { q.cheatDay = d } } label: {
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    Text(Fmt.int(v)).font(.system(size: 10.5, weight: .bold)).monospacedDigit().fixedSize()
                        .foregroundStyle(on ? .primary : .secondary)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.25)))
                        .frame(height: min(66, max(18, 40 * v / Double(max(r.everyday, 1)))))
                    Text(Calendar.current.veryShortWeekdaySymbols[d]).font(.caption2.weight(.semibold)).foregroundStyle(on ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain).allowsHitTesting(pick)
                .accessibilityLabel("\(Calendar.current.weekdaySymbols[d]), \(Fmt.int(v))\(on ? ", cheat day" : "")")
            }
        }
        .frame(height: 108).padding(14)
    }

    // MARK: 1 goals, 2 about you

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("What are you after?", "Everything gets built around this.")
            group {
                option("Lose fat", "Steadily, without giving up the foods you love", "flame.fill", on: q.goal == "lose") { q.goal = "lose"; q.pace = -0.5 }
                line
                option("Get leaner and stronger", "Lose fat slowly while you build muscle", "figure.strengthtraining.traditional", on: q.goal == "recomp") { q.goal = "recomp" }
                line
                option("Build muscle", "A small surplus, so it's mostly muscle", "dumbbell.fill", on: q.goal == "leanbulk") { q.goal = "leanbulk"; q.pace = 0.25 }
                line
                option("Stay where I am", "Eat well, enjoy it, keep the weight steady", "equal.circle.fill", on: q.goal == "maintain") { q.goal = "maintain" }
            }
            group {
                HStack {
                    Text("Goal weight").font(.body.weight(.semibold))
                    Spacer()
                    TextField("Optional", value: $goalWeight, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90).font(.body.weight(.heavy))
                    Text("kg").foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 13)
            }
            if let ps = Plan.paces[q.goal] {
                label("How fast?", "\(Fmt.kg(abs(q.pace))) kg a week")
                HStack(spacing: 8) {
                    ForEach(ps, id: \.1) { p in paceTile(p.0, p.1) }
                }
            }
        }
    }

    /// A pace and the date it gets you to your goal weight (the kg a week, when there's no goal to date).
    private func paceTile(_ name: String, _ pace: Double) -> some View {
        let on = q.pace == pace
        let when = Plan.reach(goalWeight, from: q.weight, rate: pace).map { "by \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? "\(Fmt.kg(abs(pace))) kg a week"
        return Button { withAnimation(.snappy) { q.pace = pace } } label: {
            VStack(spacing: 3) {
                Text(name).font(.subheadline.weight(.heavy)).foregroundStyle(on ? .primary : .secondary)
                Text(when).font(.caption.weight(.semibold)).foregroundStyle(on ? .primary : .secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(on ? AnyShapeStyle(Color(.systemGray3)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .sensoryFeedback(.selection, trigger: on)
    }

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("About you", "Your budget is worked out from these.")
            Picker("Sex", selection: $q.sex) { Text("Male").tag("m"); Text("Female").tag("f") }.pickerStyle(.segmented)
            group {
                wheelRow("Age", age, "years", range: 14...95, start: 30) { age = $0; q.age = Double($0) }
                line
                wheelRow("Height", height, "cm", range: 130...220, start: 170) { height = $0; q.height = Double($0) }
                line
                numberRow("Weight", $q.weight, "kg")
            }
            label("Your day, outside the gym")
            group {
                ForEach(Plan.activities.indices, id: \.self) { i in
                    let a = Plan.activities[i]
                    if i > 0 { line }
                    option(a.name, a.sub, a.symbol, on: q.activity == a.k) { q.activity = a.k }
                }
            }
        }
    }

    // MARK: 2 food

    private func chips(_ all: [String], _ picked: Binding<Set<String>>) -> some View {
        let extra = picked.wrappedValue.subtracting(all).sorted()
        return Flow {
            ForEach(all + extra, id: \.self) { c in
                Chip(text: c, on: picked.wrappedValue.contains(c), quiet: true) {
                    if picked.wrappedValue.contains(c) { picked.wrappedValue.remove(c) } else { picked.wrappedValue.insert(c) }
                }
            }
        }
    }

    private func addField(_ prompt: String, _ text: Binding<String>, into picked: Binding<Set<String>>) -> some View {
        HStack {
            TextField(prompt, text: text).submitLabel(.done)
                .onSubmit { let t = text.wrappedValue.trimmingCharacters(in: .whitespaces); if !t.isEmpty { picked.wrappedValue.insert(t.capitalizedFirst) }; text.wrappedValue = "" }
            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
        }
        .padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var foodStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("What do you love eating?", "Your plan gets built around these. No diet food.")
            label("Cuisines you eat most")
            chips(allCuisines, $cuisines).padding(.top, -2)
            label("Can't live without")
            chips(allLoves, $loves).padding(.top, -2)
            addField("Add another favourite", $newLove, into: $loves)
            label("Anything you don't eat?")
            chips(allAvoid, $avoid)
            addField("Add an allergy or dislike", $newAvoid, into: $avoid)
        }
    }

    // MARK: 3 a normal day

    private var dayStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("A normal day for you", "Roughly is fine. It shows where you're starting from.")
            group {
                ForEach(meals.indices, id: \.self) { i in
                    if i > 0 { line }
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: meals[i])
                        TextField(hints[i], text: $usual[i], axis: .vertical).lineLimit(1...3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
            }
            let empty = usual.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            Button { Task { await estimate() } } label: {
                group {
                    HStack(spacing: 12) {
                        Group { if estimating { ProgressView() } else { Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent) } }
                            .frame(width: 38, height: 38).background(Color(.tertiarySystemFill), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(estimating ? "Working it out…" : "Work out my calories").font(.body.weight(.bold)).foregroundStyle(.primary)
                            Text("An estimate of what you eat now").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
            }
            .buttonStyle(.plain).disabled(estimating || empty).opacity(empty ? 0.5 : 1)
            if let k = usualKcal {
                label("Where you are now")
                group {
                    HStack(spacing: 0) {
                        figure(Fmt.int(k), "kcal a day")
                        if let p = usualProtein { Divider().frame(height: 34); figure("\(Int(p)) g", "protein") }
                    }
                    .padding(.vertical, 12)
                    if !usualNote.isEmpty {
                        Text(usualNote).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.bottom, 12)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 4) }
        }
        .animation(.snappy, value: usualKcal)
    }

    private func figure(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) { Text(v).font(.title3.weight(.heavy)).monospacedDigit(); Text(l).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }

    private func estimate() async {
        estimating = true; problem = nil
        defer { estimating = false }
        let day = meals.indices.map { "\(meals[$0]): \(usual[$0].isEmpty ? "nothing said" : usual[$0])" }.joined(separator: "\n")
        let schema: JSON = ["type": "object", "properties": [
            "kcal": ["type": "number", "description": "Total kcal for the whole day"] as JSON,
            "protein": ["type": "number", "description": "Total protein in grams"] as JSON,
            "note": ["type": "string", "description": "One friendly sentence under 18 words on the easiest win, e.g. where protein could come from"] as JSON
        ] as JSON, "required": ["kcal", "protein", "note"]]
        let prompt = "Estimate the calories and protein of this normal day of eating for an adult in \(Plan.country). Use typical portions and products from there.\n\(day)\n\(Assistant.foodData(day))"
        do {
            let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true, job: "quick")
            withAnimation { usualKcal = pos(a["kcal"]); usualProtein = pos(a["protein"]); usualNote = str(a["note"]) }
        } catch { problem = error.localizedDescription }
    }

    // MARK: 4 training

    private var trainingStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("How you train", "Your plan starts from what you already do.")
            label("Weights sessions a week")
            Picker("Days", selection: $gymDays) { ForEach(0...6, id: \.self) { Text($0 == 0 ? "None" : "\($0)").tag($0) } }.pickerStyle(.segmented)
            if gymDays > 0 {
                label("How long have you been lifting?")
                Picker("Experience", selection: $experience) { Text("New to it").tag("new"); Text("A year or two").tag("some"); Text("Years").tag("lots") }.pickerStyle(.segmented)
                label("Where?")
                group {
                    option("A full gym", "Barbells, machines, cables", "building.2.fill", on: kit == "gym") { kit = "gym" }
                    line
                    option("Dumbbells at home", "A set of dumbbells and a bench", "dumbbell.fill", on: kit == "dumbbells") { kit = "dumbbells" }
                    line
                    option("No kit", "Bodyweight, anywhere", "figure.cooldown", on: kit == "none") { kit = "none" }
                }
                if !store.routines.isEmpty {
                    card {
                        HStack {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                            Text("Your routines stay as they are: \(store.routines.prefix(3).map { str($0["name"]) }.joined(separator: ", "))").font(.footnote)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            label("Anything else?")
            chips(allExtras, $extras)
        }
    }

    // MARK: 5 cheat days

    private var cheatStep: some View {
        let r = Plan.compute(input)
        return VStack(alignment: .leading, spacing: 10) {
            heading("Your cheat day", "Eat a bit less on normal days, then spend it on one day. It's the weekly total that counts.")
            group {
                option("Save up for a cheat day", "One big day a week, guilt-free", "party.popper.fill", on: q.spread == "cheat") { q.spread = "cheat" }
                line
                option("Same every day", "No cheat day, the same budget daily", "equal.circle.fill", on: q.spread == "same") { q.spread = "same" }
            }
            if q.spread == "cheat" {
                label("Which day?", "Tap a day")
                group { weekBars(r, pick: true) }
                    .sensoryFeedback(.selection, trigger: q.cheatDay)
                label("How big?")
                Picker("Size", selection: $q.cheatSize.animation(.snappy)) { Text("A bit more").tag(1.3); Text("Lots more").tag(1.5); Text("Go big").tag(1.7) }.pickerStyle(.segmented)
            }
        }
    }

    // MARK: 6 the plan

    /// The answers turned into what the maths needs.
    private var input: PlanInput {
        var i = q
        let other = extras.subtracting(["Walking"]).count   // walking counts in day-to-day activity
        i.trainDays = gymDays + min(2, other)
        i.trainType = gymDays > 0 ? (other > 0 ? "mix" : "weights") : (extras.contains("Sport") ? "sport" : "cardio")
        i.protein = gymDays >= 2 ? (q.goal == "lose" ? "high" : "lift") : (q.goal == "lose" ? "high" : "std")
        return i
    }

    private var week: [PlanSession] { builtPlan.sessions }
    private var builtPlan: WorkoutPlan {
        WorkoutPlanner.build(goal: q.goal == "maintain" ? "fitness" : "muscle", days: gymDays, experience: experience, kit: kit, minutes: 60, focus: [], keep: [], start: store.today)
    }

    private var planStep: some View {
        let r = Plan.compute(input)
        let reach = Plan.reach(goalWeight, from: q.weight, rate: r.rate)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(planTitle(r)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.int(Double(r.everyday))).font(.system(size: 48, weight: .heavy, design: .rounded)).monospacedDigit()
                    Text("kcal").font(.headline).foregroundStyle(.secondary)
                }
                if let reach { Text("\(Fmt.one(goalWeight ?? 0)) kg around \(reach.formatted(.dateTime.day().month(.wide)))").font(.subheadline).foregroundStyle(.primary.opacity(0.8)) }
            }
            .padding(.horizontal, 4).padding(.top, 6)
            label("Your week")
            group {
                weekBars(r, pick: false)
                Divider()
                HStack(spacing: 0) {
                    figure("\(r.p) g", "protein")
                    Divider().frame(height: 34)
                    figure("\(r.c) g", "carbs")
                    Divider().frame(height: 34)
                    figure("\(r.f) g", "fat")
                }
                .padding(.vertical, 12)
            }
            Group {
                if let cheat = r.cheat { Text("You bank about \(Fmt.int(Double(cheat - r.everyday) / 6)) kcal a day for \(Calendar.current.weekdaySymbols[q.cheatDay]).") }
                if let k = usualKcal {
                    Text("You eat about \(Fmt.int(k)) now\(usualProtein.map { " with \(Int($0)) g protein" } ?? ""). You burn about \(Fmt.int(Double(r.tdee))).")
                }
            }
            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            ForEach(r.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.footnote).foregroundStyle(Theme.warn)
            }
            if gymDays > 0 {
                label("Training: \(trainingName)")
                card {
                    ForEach(week.indices, id: \.self) { i in
                        let d = week[i]
                        HStack(alignment: .top) {
                            Text(Calendar.current.shortWeekdaySymbols[d.weekday]).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent).frame(width: 40, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.subheadline.weight(.bold))
                                Text(d.moves.map { "\($0.exercise) \($0.sets)×\($0.low)–\($0.high)" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Text(Training.note(experience)).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Make this my workout plan", isOn: $saveRoutines).font(.subheadline.weight(.semibold))
                }
            }
            label("Meals you'll actually want")
            switch ideasState {
            case 2:
                ForEach(ideas.indices, id: \.self) { i in
                    let m = ideas[i]
                    HStack(spacing: 12) {
                        FoodDot(name: str(m["name"]), size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(str(m["name"])).font(.subheadline.weight(.bold))
                            Text(str(m["why"])).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.int(num(m["kcal"]) ?? 0)).font(.subheadline.weight(.heavy)).monospacedDigit()
                            Text("\(Int(num(m["protein"]) ?? 0))g protein").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            case 3:
                Button("Couldn't get ideas just now. Try again") { Task { await askIdeas() } }.font(.footnote)
            default:
                HStack(spacing: 10) { ProgressView(); Text("Picking meals from the food you love…").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private func row(_ l: String, _ v: String, tint: Color = .primary) -> some View {
        HStack { Text(l).foregroundStyle(.secondary); Spacer(); Text(v).font(.headline.weight(.heavy)).foregroundStyle(tint).monospacedDigit() }
    }

    private var trainingName: String {
        switch gymDays { case 1...3: return "full body, \(gymDays) day\(gymDays == 1 ? "" : "s")"; case 4: return "upper / lower, 4 days"; case 5: return "upper / lower plus push, pull, legs"; default: return "push, pull, legs, \(gymDays) days" }
    }

    private func planTitle(_ r: PlanResult) -> String {
        let cheat = r.cheat != nil ? ", with \(Calendar.current.weekdaySymbols[q.cheatDay])s off" : ""
        switch q.goal {
        case "lose": return "Lose \(Fmt.one(abs(r.rate))) kg a week\(cheat)"
        case "recomp": return "Leaner and stronger\(cheat)"
        case "leanbulk": return "Build muscle, slowly\(cheat)"
        default: return "Keep steady\(cheat)"
        }
    }

    private func askIdeas() async {
        ideasState = 1
        let r = Plan.compute(input)
        let schema: JSON = ["type": "object", "properties": [
            "meals": ["type": "array", "items": ["type": "object", "properties": [
                "name": ["type": "string"] as JSON,
                "kcal": ["type": "number"] as JSON,
                "protein": ["type": "number"] as JSON,
                "why": ["type": "string", "description": "Under 10 words, e.g. 'Takeaway favourite, lighter sauce'"] as JSON
            ] as JSON, "required": ["name", "kcal", "protein", "why"]] as JSON] as JSON
        ] as JSON, "required": ["meals"]]
        let prompt = """
        Suggest 6 meals for someone in \(Plan.country) eating about \(r.everyday) kcal a day with a \(r.p) g protein target.
        Cuisines they eat most: \(cuisines.isEmpty ? "anything" : cuisines.sorted().joined(separator: ", ")).
        Foods they love: \(loves.isEmpty ? "not said" : loves.sorted().joined(separator: ", ")).
        Never include: \(avoid.isEmpty ? "nothing" : avoid.sorted().joined(separator: ", ")).
        Make them feel like real food they'd crave, not diet food: home-cooked or takeaway orders, 350 to 700 kcal each, high in protein, using familiar dishes and products from there.
        """
        do {
            let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true, job: "plans")
            let got = list(a["meals"])
            withAnimation { ideas = got; ideasState = got.isEmpty ? 3 : 2 }
        } catch { ideasState = 3 }
    }

    // MARK: saving

    private func prefill() {
        let prof = dict(store.doc["profile"])
        if let s = prof["sex"] as? String, !s.isEmpty { q.sex = s }
        if let a = pos(prof["age"]) { q.age = a; age = Int(a) }
        if let h = pos(prof["height"]) { q.height = h; height = Int(h.rounded()) }
        if let w = store.latestWeight?.kg ?? pos(store.doc["weightKg"]) { q.weight = w }
        goalWeight = pos(store.doc["goalWeight"])
        let plan = dict(store.doc["plan"])
        if let a = pos(plan["activity"]) { q.activity = a }
        if let g = plan["goal"] as? String, ["lose", "recomp", "maintain", "leanbulk"].contains(g) { q.goal = g }
        if let p = num(plan["rate"]), let ps = Plan.paces[q.goal], let near = ps.min(by: { abs($0.1 - p) < abs($1.1 - p) }) { q.pace = near.1 }
        if let wd = store.cheatWeekday { q.spread = "cheat"; q.cheatDay = wd } else if plan["spread"] as? String == "same" { q.spread = "same" }
        if let s = pos(plan["cheatSize"]) { q.cheatSize = s }
        let p = dict(store.doc["prefs"])
        cuisines = Set(p["cuisines"] as? [String] ?? [])
        loves = Set(p["loves"] as? [String] ?? [])
        avoid = Set(p["avoid"] as? [String] ?? [])
        extras = Set(p["extras"] as? [String] ?? [])
        if let u = p["usual"] as? [String], u.count == 4 { usual = u }
        usualKcal = pos(p["usualKcal"]); usualProtein = pos(p["usualProtein"])
        if let e = p["experience"] as? String { experience = e }
        if let k = p["kit"] as? String { kit = k }
        if let g = num(p["gymDays"]) { gymDays = Int(g) } else if let t = num(plan["trainDays"]) { gymDays = min(6, Int(t)) }
    }

    private func skip() {
        store.perform(["type": "set", "key": "onboarded", "value": true])
        onDone()
    }

    private func finish() {
        let i = input, r = Plan.compute(i)
        let plan: JSON = [
            "createdAt": ISO.now(), "goal": q.goal, "pace": q.pace, "rate": r.rate, "activity": q.activity,
            "trainDays": i.trainDays, "trainType": i.trainType, "trainMins": i.trainMins, "trainWeekdays": week.map(\.weekday),
            "spread": q.spread, "cheatDay": q.cheatDay, "cheatSize": q.cheatSize, "protein": i.protein, "paceCustom": NSNull(),
            "startWeight": q.weight, "fat": NSNull(), "tdee": r.tdee, "bmr": r.bmr, "kcal": r.kcal,
            "macros": ["p": r.p, "c": r.c, "f": r.f] as JSON, "lastCheckIn": nowMs()
        ]
        let prefs: JSON = [
            "cuisines": cuisines.sorted(), "loves": loves.sorted(), "avoid": avoid.sorted(), "extras": extras.sorted(),
            "usual": usual, "usualKcal": usualKcal.map { $0 as Any } ?? NSNull(), "usualProtein": usualProtein.map { $0 as Any } ?? NSNull(),
            "experience": experience, "kit": kit, "gymDays": gymDays,
            "training": week.map { ["weekday": $0.weekday, "name": $0.name] as JSON }, "ideas": ideas, "updatedAt": ISO.now()
        ]
        var prefsOut = prefs
        if saveRoutines && gymDays > 0 { prefsOut["workoutPlan"] = builtPlan.json }
        var days = JSON(); for (k, v) in r.days { days[String(k)] = v }
        store.perform([
            "type": "plan", "profile": ["sex": q.sex, "age": Int(q.age), "height": q.height] as JSON,
            "budget": r.everyday, "dayBudgets": days, "goals": ["p": r.p, "c": r.c, "f": r.f] as JSON,
            "plan": plan, "prefs": prefsOut, "weightKg": q.weight,
            "goalWeight": goalWeight.map { $0 as Any } ?? NSNull(), "day": store.today
        ])
        if store.latestWeight?.day != store.today { store.weighIn(q.weight) }
        onDone()
    }
}
