import SwiftUI
import WatchKit

/// Add food: say it ("a flat white and a banana"), the phone's assistant counts it, Add puts it in the meal it picked
/// (or the meal it was opened from).
struct AddFoodView: View {
    let meal: String?
    @EnvironmentObject var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    @State private var said = ""
    @State private var working = false
    @State private var estimate: WatchEstimate?
    @State private var problem: String?
    @State private var added = false

    var body: some View {
        let theme = WatchTheme(c: model.today.colours)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if estimate == nil {
                    // tapping it opens the watch's own dictation (or scribble, or the keyboard)
                    TextField(meal.map { "What did you have for \($0.lowercased())?" } ?? "Say what you had", text: $said)
                        .onSubmit(count)
                        .disabled(working)
                }
                if !said.isEmpty && estimate != nil {
                    Text("\u{201C}\(said)\u{201D}").font(.footnote.weight(.semibold).italic()).foregroundStyle(.secondary)
                }
                if working { HStack(spacing: 6) { ProgressView().frame(width: 18, height: 18); Text("Counting it up…").font(.footnote).foregroundStyle(.secondary) } }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                if let e = estimate {
                    VStack(spacing: 0) {
                        ForEach(e.parts) { (f: WatchToday.Food) in
                            FoodLine(food: f)
                            Divider().opacity(0.4)
                        }
                        HStack {
                            Text(e.meal).font(.caption2.weight(.heavy))
                            Spacer()
                            Text("\(Num.int(e.kcal)) kcal · \(Num.int(e.protein)) g protein").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .padding(.horizontal, 9)
                    .background(WatchTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Button { add(e) } label: {
                        Text(added ? "Added" : "Add to \(e.meal.lowercased()) · \(Num.int(e.kcal))")
                            .font(.footnote.weight(.heavy)).foregroundStyle(theme.onAccent)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(theme.accent.opacity(added ? 0.5 : 1), in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(working || added)
                    Button("Say it again") { estimate = nil; said = ""; problem = nil }
                        .font(.footnote).buttonStyle(.plain).foregroundStyle(theme.accent).frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Add food")
    }

    private func count() {
        let text: String = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // the meal it was opened from goes to the assistant too, as on the phone ("add to lunch")
        let asked: String = meal.map { "\(text), for \($0.lowercased())" } ?? text
        working = true; problem = nil
        Task {
            let out = await model.send([WatchKey.food: asked])
            working = false
            switch out {
            case .failed(let why): problem = why
            case .reply(let r):
                if let e = WatchCoding.value(WatchEstimate.self, r[WatchKey.food]) { estimate = e } else { problem = "Couldn't tell what that was. Try again?" }
            }
        }
    }

    private func add(_ e: WatchEstimate) {
        working = true
        Task {
            let out = await model.send([WatchKey.add: e.id])
            working = false
            switch out {
            case .failed(let why): problem = why
            case .reply:
                added = true
                WKHaptic.success()
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        }
    }
}

/// Ask: talk to the assistant, as in the phone's chat. Short answers here; Add when it suggests a food.
struct AskView: View {
    @EnvironmentObject var model: WatchModel
    @State private var lines: [WatchLine] = []
    @State private var said = ""
    @State private var working = false
    @State private var problem: String?
    @State private var offer: WatchEstimate?
    @State private var added = false

    var body: some View {
        let theme = WatchTheme(c: model.today.colours)
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if lines.isEmpty {
                        Text("Ask what to eat, how you're doing, or anything you'd ask on your phone.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(lines) { (l: WatchLine) in
                        Text(l.text)
                            .font(.footnote.weight(l.me ? .bold : .semibold))
                            .foregroundStyle(l.me ? theme.onAccent : .white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(l.me ? theme.accent : theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: l.me ? .trailing : .leading)
                            .padding(l.me ? .leading : .trailing, 18)
                            .id(l.id)
                    }
                    if working { ProgressView().frame(maxWidth: .infinity) }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                    if let e = offer {
                        Button { add(e) } label: {
                            Text(added ? "Added" : "Add to \(e.meal.lowercased()) · \(Num.int(e.kcal))")
                                .font(.footnote.weight(.heavy)).foregroundStyle(theme.onAccent)
                                .frame(maxWidth: .infinity).frame(height: 38)
                                .background(theme.accent.opacity(added ? 0.5 : 1), in: Capsule())
                        }
                        .buttonStyle(.plain).disabled(working || added)
                    }
                    TextField(lines.isEmpty ? "Ask" : "Reply", text: $said)
                        .onSubmit(ask)
                        .disabled(working)
                        .id("field")
                }
            }
            .onChange(of: lines.count) { _, _ in withAnimation { reader.scrollTo("field", anchor: .bottom) } }
        }
        .navigationTitle("Ask")
    }

    private func ask() {
        let text: String = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        said = ""; problem = nil; offer = nil; added = false
        lines.append(WatchLine(me: true, text: text))
        working = true
        let chat = WatchChat(lines: Array(lines.suffix(8)))
        Task {
            let out = await model.send([WatchKey.ask: WatchCoding.data(chat) ?? Data()])
            working = false
            switch out {
            case .failed(let why): problem = why
            case .reply(let r):
                if let a = WatchCoding.value(WatchAnswer.self, r[WatchKey.ask]) {
                    lines.append(WatchLine(me: false, text: a.text))
                    offer = a.estimate
                } else {
                    problem = "No answer came back. Try again?"
                }
            }
        }
    }

    private func add(_ e: WatchEstimate) {
        working = true
        Task {
            let out = await model.send([WatchKey.add: e.id])
            working = false
            switch out {
            case .failed(let why): problem = why
            case .reply: added = true; WKHaptic.success()
            }
        }
    }
}

enum WKHaptic {
    static func success() { WKInterfaceDevice.current().play(.success) }
}
