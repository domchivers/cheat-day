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
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            Text(text).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(on ? Theme.accent : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? Color.black : Color.primary)
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
                Image(systemName: symbol).font(.title3).foregroundStyle(on ? Color.black : Theme.accent)
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

/// Sign-up: what you're after, what you love eating, a normal day, how you train, your cheat day, then the plan.
struct OnboardingView: View {
    var firstRun = true
    var onDone: () -> Void
    @State private var step = 0
    @State private var forward = true
    @State private var loaded = false
    @State private var q = PlanInput()
    @State private var goalWeight: Double?
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

    private let titles = ["Goals", "Food", "Normal day", "Training", "Cheat days", "Your plan"]
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
                    case 1: foodStep
                    case 2: dayStep
                    case 3: trainingStep
                    case 4: cheatStep
                    default: planStep
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .scrollDismissesKeyboard(.interactively)
            bottom
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { if !loaded { prefill(); loaded = true } }
    }

    // MARK: the frame

    private var top: some View {
        VStack(spacing: 10) {
            HStack {
                if step > 0 { Button("Back") { go(-1) } }
                else if !firstRun { Button("Cancel") { onDone() } }
                else { Text(" ") }
                Spacer()
                if firstRun && step < 5 { Button("Skip for now") { skip() }.foregroundStyle(.secondary) }
                else if !firstRun && step > 0 { Button("Close") { onDone() }.foregroundStyle(.secondary) }
            }
            .font(.body.weight(.semibold))
            HStack(spacing: 4) {
                ForEach(titles.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Theme.accent : Theme.track).frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
        .animation(.snappy, value: step)
    }

    private var bottom: some View {
        Button {
            if step == 5 { finish() } else { go(1) }
        } label: {
            Text(step == 5 ? "Start my plan" : step == 4 ? "Build my plan" : "Next")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18))
        .foregroundStyle(.black)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.bg)
    }

    private func go(_ by: Int) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if step == 0 && by < 0 { onDone(); return }
        forward = by > 0
        withAnimation(.snappy) { step = max(0, min(5, step + by)) }
        if step == 5 && ideasState == 0 { Task { await askIdeas() } }
    }

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: "Step \(step + 1) of 6", color: Theme.heroLabel)
            Text(title).font(.largeTitle.bold())
            Text(sub).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 12) { content() }
            .padding(16)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func numberRow(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                .font(.body.weight(.bold))
            Text(unit).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
        }
    }

    // MARK: 1 goals and body

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("What are you after?", "Everything gets built around this.")
            ChoiceCard(title: "Lose fat", sub: "Steadily, without giving up the foods you love", symbol: "flame.fill", on: q.goal == "lose") { q.goal = "lose"; q.pace = -0.5 }
            ChoiceCard(title: "Get leaner and stronger", sub: "Lose fat slowly while you build muscle", symbol: "figure.strengthtraining.traditional", on: q.goal == "recomp") { q.goal = "recomp" }
            ChoiceCard(title: "Build muscle", sub: "A small surplus, so it's mostly muscle", symbol: "dumbbell.fill", on: q.goal == "leanbulk") { q.goal = "leanbulk"; q.pace = 0.25 }
            ChoiceCard(title: "Stay where I am", sub: "Eat well, enjoy it, keep the weight steady", symbol: "equal.circle.fill", on: q.goal == "maintain") { q.goal = "maintain" }
            if let ps = Plan.paces[q.goal] {
                label("How fast?")
                Picker("How fast", selection: $q.pace) { ForEach(ps, id: \.1) { p in Text(p.0).tag(p.1) } }.pickerStyle(.segmented)
                Text("\(Fmt.one(abs(q.pace))) kg a week").font(.footnote).foregroundStyle(.secondary)
            }
            label("About you")
            card {
                Picker("Sex", selection: $q.sex) { Text("Male").tag("m"); Text("Female").tag("f") }.pickerStyle(.segmented)
                numberRow("Age", $q.age, "years")
                numberRow("Height", $q.height, "cm")
                numberRow("Weight", $q.weight, "kg")
                HStack {
                    Text("Goal weight")
                    Spacer()
                    TextField("Optional", value: $goalWeight, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90).font(.body.weight(.bold))
                    Text("kg").foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                }
            }
            label("Your day, outside the gym")
            ForEach(Plan.activities, id: \.k) { a in
                ChoiceCard(title: a.name, sub: a.sub, symbol: a.symbol, on: q.activity == a.k) { q.activity = a.k }
            }
        }
    }

    // MARK: 2 food

    private func chips(_ all: [String], _ picked: Binding<Set<String>>) -> some View {
        let extra = picked.wrappedValue.subtracting(all).sorted()
        return Flow {
            ForEach(all + extra, id: \.self) { c in
                Chip(text: c, on: picked.wrappedValue.contains(c)) {
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
        .padding(12).background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var foodStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("What do you love eating?", "Your plan gets built around these. No diet food.")
            label("Cuisines you eat most")
            chips(allCuisines, $cuisines)
            label("Can't live without")
            chips(allLoves, $loves)
            addField("Add another favourite", $newLove, into: $loves)
            label("Anything you don't eat?")
            chips(allAvoid, $avoid)
            addField("Add an allergy or dislike", $newAvoid, into: $avoid)
        }
    }

    // MARK: 3 a normal day

    private var dayStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("A normal day for you", "Roughly is fine. It shows where you're starting from. You can skip it.")
            ForEach(meals.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: meals[i])
                    TextField(hints[i], text: $usual[i], axis: .vertical).lineLimit(1...3)
                }
                .padding(14).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Button { Task { await estimate() } } label: {
                Label(estimating ? "Working it out…" : "Work out my calories", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(estimating || usual.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            if let k = usualKcal {
                card {
                    HStack { Text("That's about").foregroundStyle(.secondary); Spacer(); Text("\(Fmt.int(k)) kcal").font(.title2.weight(.heavy)) }
                    if let p = usualProtein { HStack { Text("Protein").foregroundStyle(.secondary); Spacer(); Text("\(Int(p)) g").font(.headline) } }
                    if !usualNote.isEmpty { Text(usualNote).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
        }
        .animation(.snappy, value: usualKcal)
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
        let prompt = "Estimate the calories and protein of this normal day of eating for an adult in \(Plan.country). Use typical portions and products from there.\n\(day)"
        do {
            let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true)
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
                ChoiceCard(title: "A full gym", sub: "Barbells, machines, cables", symbol: "building.2.fill", on: kit == "gym") { kit = "gym" }
                ChoiceCard(title: "Dumbbells at home", sub: "A set of dumbbells and a bench", symbol: "dumbbell.fill", on: kit == "dumbbells") { kit = "dumbbells" }
                ChoiceCard(title: "No kit", sub: "Bodyweight, anywhere", symbol: "figure.cooldown", on: kit == "none") { kit = "none" }
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
        let order = [1, 2, 3, 4, 5, 6, 0]
        return VStack(alignment: .leading, spacing: 10) {
            heading("Your cheat day", "Eat a bit less on normal days, then spend it all on one day. It's the weekly total that counts.")
            ChoiceCard(title: "Save up for a cheat day", sub: "One big day a week, guilt-free", symbol: "party.popper.fill", on: q.spread == "cheat") { q.spread = "cheat" }
            ChoiceCard(title: "Same every day", sub: "No cheat day, the same budget daily", symbol: "equal.circle.fill", on: q.spread == "same") { q.spread = "same" }
            if q.spread == "cheat" {
                label("Which day?")
                HStack(spacing: 6) {
                    ForEach(order, id: \.self) { d in
                        Button { q.cheatDay = d } label: {
                            Text(Calendar.current.shortWeekdaySymbols[d].prefix(2)).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(q.cheatDay == d ? Theme.warn : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .foregroundStyle(q.cheatDay == d ? Color.black : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                label("How big?")
                Picker("Size", selection: $q.cheatSize) { Text("A bit more").tag(1.3); Text("Lots more").tag(1.5); Text("Go big").tag(1.7) }.pickerStyle(.segmented)
                card {
                    HStack { Text("\(Calendar.current.weekdaySymbols[q.cheatDay])").foregroundStyle(.secondary); Spacer(); Text("\(Fmt.int(Double(r.cheat ?? 0))) kcal").font(.title3.weight(.heavy)).foregroundStyle(Theme.warn) }
                    HStack { Text("Other days").foregroundStyle(.secondary); Spacer(); Text("\(Fmt.int(Double(r.everyday))) kcal").font(.title3.weight(.heavy)) }
                }
                .contentTransition(.numericText())
                .animation(.snappy, value: q.cheatSize)
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

    private var week: [Training.Day] { Training.week(days: gymDays, experience: experience, kit: kit) }

    private var planStep: some View {
        let r = Plan.compute(input)
        let reach = Plan.reach(goalWeight, from: q.weight, rate: r.rate)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Your plan", color: Theme.heroLabel)
                Text(planTitle(r)).font(.largeTitle.bold())
                if let reach { Text("\(Fmt.one(goalWeight ?? 0)) kg around \(reach.formatted(.dateTime.month(.wide).year()))").foregroundStyle(.secondary) }
            }
            .padding(.bottom, 6)
            card {
                if let cheat = r.cheat {
                    row("Normal days", "\(Fmt.int(Double(r.everyday))) kcal")
                    row("\(Calendar.current.weekdaySymbols[q.cheatDay]), cheat day", "\(Fmt.int(Double(cheat))) kcal", tint: Theme.warn)
                    Text("You bank about \(Fmt.int(Double(cheat - r.everyday) / 6)) kcal a day for it.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    row("Every day", "\(Fmt.int(Double(r.kcal))) kcal")
                }
                Divider()
                row("Protein", "\(r.p) g a day")
                row("Carbs · fat", "\(r.c) g · \(r.f) g")
                if let k = usualKcal {
                    Text("You eat about \(Fmt.int(k)) now\(usualProtein.map { " with \(Int($0)) g protein" } ?? ""). You burn about \(Fmt.int(Double(r.tdee))).")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
                                Text(d.moves.map { "\($0.name) \($0.sets)×\($0.reps)" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Text(Training.note(experience)).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Save these as routines", isOn: $saveRoutines).font(.subheadline.weight(.semibold))
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
                    .padding(12).background(Theme.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            let a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: true)
            let got = list(a["meals"])
            withAnimation { ideas = got; ideasState = got.isEmpty ? 3 : 2 }
        } catch { ideasState = 3 }
    }

    // MARK: saving

    private func prefill() {
        let prof = dict(store.doc["profile"])
        if let s = prof["sex"] as? String, !s.isEmpty { q.sex = s }
        if let a = pos(prof["age"]) { q.age = a }
        if let h = pos(prof["height"]) { q.height = h }
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
        var days = JSON(); for (k, v) in r.days { days[String(k)] = v }
        store.perform([
            "type": "plan", "profile": ["sex": q.sex, "age": Int(q.age), "height": q.height] as JSON,
            "budget": r.everyday, "dayBudgets": days, "goals": ["p": r.p, "c": r.c, "f": r.f] as JSON,
            "plan": plan, "prefs": prefs, "weightKg": q.weight,
            "goalWeight": goalWeight.map { $0 as Any } ?? NSNull(), "day": store.today
        ])
        if store.latestWeight?.day != store.today { store.weighIn(q.weight) }
        if saveRoutines && gymDays > 0 {
            var saved = Set<String>()
            for d in week where saved.insert(d.name).inserted {
                let name = "Plan: \(d.name)"
                guard !store.routines.contains(where: { str($0["name"]) == name }) else { continue }
                store.saveRoutine(name: name, exercises: d.moves.map { ["exercise": $0.name, "sets": $0.sets, "reps": $0.reps, "kg": 0] as JSON })
            }
        }
        onDone()
    }
}
