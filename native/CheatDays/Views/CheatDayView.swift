import SwiftUI

/// Plan your cheat day: what kind of day, what's on, keep protein or not, then a timeline that makes the most of it.
struct CheatDayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "smart"
    @State private var whats: Set<String> = []
    @State private var newWhat = ""
    @State private var keepProtein = true
    @State private var training = true
    @State private var busy = false
    @State private var problem: String?
    @State private var replan = false
    @State private var setupDay = 6
    @State private var setupSize = 1.3
    private var store: Store { Store.shared }
    private let ideas = ["Yum cha", "Pizza night", "Sunday roast", "Curry night", "Burgers", "BBQ", "Brunch out", "Fish and chips", "Drinks out", "Dessert", "Takeaway", "Movie snacks"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let next = store.nextCheat {
                        if let saved = store.cheatPlan(next.date), !replan { planView(saved, next: next) }
                        else { form(next) }
                    } else {
                        setup
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
                .animation(.snappy, value: replan)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Cheat day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.bold) } }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    }

    private func when(_ date: String) -> String {
        date == store.today ? "Today" : DayKey.shift(store.today, days: 1) == date ? "Tomorrow" : DayKey.date(date).formatted(.dateTime.weekday(.wide))
    }

    private func top(_ next: (date: String, kcal: Double, extra: Double)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                PizzaIcon(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: when(next.date), color: Theme.warn)
                    Text("\(Fmt.int(next.kcal)) kcal to play with").font(.title2.weight(.heavy))
                }
            }
            if next.extra > 0 { Text("That's \(Fmt.int(next.extra)) more than a normal day, banked through the week.").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, 8)
    }

    // MARK: choosing

    private func form(_ next: (date: String, kcal: Double, extra: Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            top(next)
            label("What kind of day?")
            ChoiceCard(title: "Smart cheat", sub: "Eat what you want, with the day planned around it", symbol: "brain.head.profile", on: kind == "smart") { kind = "smart" }
            ChoiceCard(title: "One big meal", sub: "Light and high protein all day, then go all out", symbol: "fork.knife", on: kind == "big") { kind = "big" }
            ChoiceCard(title: "Full send", sub: "No counting. Just a few tips so Monday's easy", symbol: "party.popper.fill", on: kind == "full") { kind = "full" }
            label("What's on?")
            Flow {
                ForEach(ideas + whats.subtracting(ideas).sorted(), id: \.self) { w in
                    Chip(text: w, on: whats.contains(w)) { if whats.contains(w) { whats.remove(w) } else { whats.insert(w) } }
                }
            }
            HStack {
                TextField("Something else, like a birthday dinner", text: $newWhat).submitLabel(.done)
                    .onSubmit { let t = newWhat.trimmingCharacters(in: .whitespaces); if !t.isEmpty { whats.insert(t.capitalizedFirst) }; newWhat = "" }
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
            }
            .padding(12).background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(spacing: 0) {
                Toggle(isOn: $keepProtein) { VStack(alignment: .leading, spacing: 1) { Text("Still hit my protein"); Text("\(Int(store.proteinGoal ?? 0)) g").font(.caption).foregroundStyle(.secondary) } }
                    .padding(.vertical, 10)
                Divider()
                Toggle("Fit a workout in", isOn: $training).padding(.vertical, 10)
            }
            .padding(.horizontal, 16)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 6)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.warn) }
            Button { Task { await make(next) } } label: {
                Label(busy ? "Planning your day…" : "Plan my day", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).foregroundStyle(.black)
            .disabled(busy).padding(.top, 8)
        }
    }

    // MARK: the plan

    private func planView(_ plan: JSON, next: (date: String, kcal: Double, extra: Double)) -> some View {
        let slots = list(plan["slots"])
        let kcal = slots.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, protein = slots.reduce(0) { $0 + (num($1["protein"]) ?? 0) }
        return VStack(alignment: .leading, spacing: 10) {
            top(next)
            Text(str(plan["title"])).font(.title.bold()).padding(.top, 6)
            ForEach(slots.indices, id: \.self) { i in
                let s = slots[i], big = (num(s["kcal"]) ?? 0) >= next.kcal * 0.35
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 4) {
                        Text(str(s["time"])).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: s["workout"] as? Bool == true ? "dumbbell.fill" : big ? "star.fill" : "fork.knife")
                            .font(.caption).foregroundStyle(big ? Theme.warn : Theme.accent)
                    }
                    .frame(width: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(str(s["title"])).font(.headline)
                            Spacer()
                            if (num(s["kcal"]) ?? 0) > 0 { Text(Fmt.int(num(s["kcal"]) ?? 0)).font(.subheadline.weight(.heavy)).monospacedDigit() }
                        }
                        Text(str(s["detail"])).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(big ? Color(red: 0.16, green: 0.13, blue: 0.07) : Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            HStack {
                Text("About \(Fmt.int(kcal)) kcal").font(.subheadline.weight(.bold))
                Spacer()
                if let goal = store.proteinGoal, protein > 0 {
                    Label("\(Int(protein)) / \(Int(goal)) g protein", systemImage: protein >= goal * 0.95 ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.bold)).foregroundStyle(protein >= goal * 0.95 ? Color.green : .secondary)
                }
            }
            .padding(.horizontal, 4)
            let tips = plan["tips"] as? [String] ?? []
            if !tips.isEmpty {
                label("Make the most of it")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tips, id: \.self) { t in Label(t, systemImage: "lightbulb.fill").font(.footnote) }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Button { replan = true } label: { Label("Plan it differently", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)).padding(.top, 6)
        }
    }

    private func make(_ next: (date: String, kcal: Double, extra: Double)) async {
        busy = true; problem = nil
        defer { busy = false }
        let prefs = dict(store.doc["prefs"])
        let loves = (prefs["loves"] as? [String] ?? []).joined(separator: ", ")
        let cuisines = (prefs["cuisines"] as? [String] ?? []).joined(separator: ", ")
        let avoid = (prefs["avoid"] as? [String] ?? []).joined(separator: ", ")
        let workout = list(prefs["training"]).first { Int(num($0["weekday"]) ?? -1) == DayKey.weekday(next.date) }.map { str($0["name"]) }
        let style: String
        switch kind {
        case "big": style = "One big meal: keep the rest of the day light and high in protein so the main event gets most of the calories."
        case "full": style = "Full send: they won't count today. Don't police it. Make it feel great, give rough kcal anyway, and a few tips so getting back to normal tomorrow is easy."
        default: style = "Smart cheat: they eat what they want, planned so the treats get the calories and nothing is wasted on food they don't care about."
        }
        let schema: JSON = ["type": "object", "properties": [
            "title": ["type": "string", "description": "A short fun title for the day, e.g. 'Yum cha and drinks'"] as JSON,
            "slots": ["type": "array", "items": ["type": "object", "properties": [
                "time": ["type": "string", "description": "24-hour time like 09:00"] as JSON,
                "title": ["type": "string"] as JSON,
                "detail": ["type": "string", "description": "Under 22 words: what to have, or the move that makes it better"] as JSON,
                "kcal": ["type": "number"] as JSON,
                "protein": ["type": "number"] as JSON,
                "workout": ["type": "boolean"] as JSON
            ] as JSON, "required": ["time", "title", "detail", "kcal", "protein", "workout"]] as JSON] as JSON,
            "tips": ["type": "array", "items": ["type": "string"] as JSON, "description": "3 short tips, under 16 words each"] as JSON
        ] as JSON, "required": ["title", "slots", "tips"]]
        let prompt = """
        Plan a cheat day for someone in \(Plan.country). It should feel like a treat, not a diet.
        Budget for the day: about \(Int(next.kcal)) kcal\(kind == "full" ? " (a guide only)" : ""). \(keepProtein ? "Hit at least \(Int(store.proteinGoal ?? 120)) g protein across the day without it feeling like diet food." : "Protein doesn't matter today.")
        \(style)
        What's on: \(whats.isEmpty ? "nothing fixed, suggest a great day around the foods they love" : whats.sorted().joined(separator: ", ")).
        Foods they love: \(loves.isEmpty ? "not said" : loves). Cuisines: \(cuisines.isEmpty ? "anything" : cuisines). Never include: \(avoid.isEmpty ? "nothing" : avoid).
        \(training ? "Include one workout slot (workout true, kcal 0) before the biggest meal\(workout.map { ": their plan has \($0) that day" } ?? ", ideally legs or full body"). The big meal after training helps recovery." : "No workout today.")
        4 to 6 slots. Name real dishes and orders from those places, with smart choices that keep the fun (e.g. which yum cha dishes give most for the calories, spirits with soda over pints).
        Tips: hydration, sleep, and getting straight back to normal tomorrow. Never suggest skipping meals the next day or making up for it.
        """
        do {
            var a = try await Gemini.ask(schema: schema, parts: [["text": prompt]], quick: false)
            a["kind"] = kind; a["whats"] = whats.sorted(); a["at"] = ISO.now()
            store.perform(["type": "cheatPlan", "date": next.date, "plan": a])
            withAnimation(.snappy) { replan = false }
        } catch { problem = error.localizedDescription }
    }

    // MARK: no cheat day yet

    private var setup: some View {
        let base = store.baseBudget(store.today)
        let cheat = Plan.r10(base * setupSize), everyday = Plan.r10((base * 7 - Double(cheat)) / 6)
        return VStack(alignment: .leading, spacing: 10) {
            PizzaIcon(size: 54).padding(.top, 10)
            Text("Pick a cheat day").font(.largeTitle.bold())
            Text("Eat a little less on normal days and spend it on one day. Same weekly total, so you stay on track.").foregroundStyle(.secondary)
            label("Which day?")
            HStack(spacing: 6) {
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                    Button { setupDay = d } label: {
                        Text(Calendar.current.shortWeekdaySymbols[d].prefix(2)).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(setupDay == d ? Theme.warn : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(setupDay == d ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            label("How big?")
            Picker("Size", selection: $setupSize) { Text("A bit more").tag(1.3); Text("Lots more").tag(1.5); Text("Go big").tag(1.7) }.pickerStyle(.segmented)
            VStack(spacing: 10) {
                HStack { Text(Calendar.current.weekdaySymbols[setupDay]).foregroundStyle(.secondary); Spacer(); Text("\(Fmt.int(Double(cheat))) kcal").font(.title3.weight(.heavy)).foregroundStyle(Theme.warn) }
                HStack { Text("Other days").foregroundStyle(.secondary); Spacer(); Text("\(Fmt.int(Double(everyday))) kcal").font(.title3.weight(.heavy)) }
            }
            .padding(16).background(Theme.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !dict(store.doc["dayBudgets"]).isEmpty {
                Text("This replaces the different budgets you have on some days.").font(.footnote).foregroundStyle(Theme.warn)
            }
            Button {
                store.perform(["type": "cheatSpread", "day": setupDay, "cheat": cheat, "everyday": everyday])
            } label: {
                Text("Set my cheat day").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).foregroundStyle(.black).padding(.top, 8)
        }
    }
}
