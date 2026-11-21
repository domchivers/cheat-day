import PhotosUI
import SwiftUI

/// Templates, from the editor (21 Nov, design/templates-mockup.html): pick one, then fill its slots with clips (the
/// edit's own, or more from Photos), the words on each from the log. Make it hands the template, the clips in slot
/// order and their slots back to the editor, which cuts them on the beat; all of it stays editable after.
struct TemplateMaker: View {
    var clips: [Clip]
    var make: (EditTemplate, [Clip], [EditTemplate.Slot], JSON?) -> Void
    var close: () -> Void

    @State private var picked: EditTemplate?
    @State private var library: [Clip] = []
    @State private var filled: [UUID?] = []          // each slot's clip, from the library
    @State private var slotOn = 0
    @State private var recipe: JSON?
    @State private var choosingRecipe = false
    @State private var adding = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var thumbs: [UUID: UIImage] = [:]

    private var store: Store { Store.shared }

    /// What the words come from: today's food and workouts, the week before, the weigh-ins.
    private var log: EditTemplate.Log {
        let since = DayKey.shift(store.today, days: -8)
        let past = list(store.doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < store.today }
            .map { (date: str($0["date"]), items: list($0["items"])) }
        let older = list(store.doc["history"]).filter { str($0["date"]) >= since && str($0["date"]) < store.today }
            .sorted { str($0["date"]) < str($1["date"]) }.flatMap { list($0["workouts"]) }
        let weights = store.bodyRows.compactMap { r in pos(r["weight"]).map { (day: str(r["day"]), kg: $0) } }.filter { $0.day <= store.today }
        return EditTemplate.Log(today: store.today, items: store.todayItems, history: past, workouts: older + store.todayWorkouts, weights: weights)
    }

    private var slots: [EditTemplate.Slot] { picked?.slots(log, recipe: recipe) ?? [] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let t = picked { filling(t) } else { gallery }
            if loading { Color.black.opacity(0.4).ignoresSafeArea(); ProgressView().tint(.white) }
        }
        .preferredColorScheme(.dark)
        .onAppear { if library.isEmpty { library = clips } }
        .task(id: library.map(\.id)) {
            for c in library where thumbs[c.id] == nil {
                if let img = await ClipJoin.frame(c, at: c.start) { thumbs[c.id] = img }
            }
        }
        .photosPicker(isPresented: $adding, selection: $picks, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: picks) { _, now in
            guard !now.isEmpty else { return }
            loading = true
            Task {
                let more = await MultiClipEditor.clips(from: now)
                picks = []; loading = false
                library += more
                for c in more { put(c.id) }
            }
        }
        .sheet(isPresented: $choosingRecipe) {
            AttachPicker(start: 1) { what in
                if str(what["kind"]) == "meal" { recipe = what; fit() }
            }
        }
    }

    // MARK: 1 · pick a template

    private var gallery: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Templates").font(.title3.weight(.heavy))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36).background(.white.opacity(0.12), in: Circle()) }
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(EditTemplate.all) { t in
                        let n = t.slots(log, recipe: nil).count
                        Button { open(t) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ZStack(alignment: .bottomLeading) {
                                    LinearGradient(colors: [EditText.colour(t.tint.0), EditText.colour(t.tint.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        .overlay { Image(systemName: t.icon).font(.system(size: 38, weight: .bold)).foregroundStyle(.white.opacity(0.9)) }
                                    Text("\(n) clip\(n == 1 ? "" : "s")").font(.caption2.weight(.heavy)).padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(8)
                                }
                                .frame(height: 130)
                                Text(t.name).font(.subheadline.weight(.bold)).padding(.horizontal, 10).padding(.top, 8)
                                Text(t.about).font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                                    .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 10)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 12)
                Text("Pick one, then drop your clips into its slots. The words on each come from what you've logged.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(16)
            }
        }
    }

    private func open(_ t: EditTemplate) {
        picked = t; recipe = nil; slotOn = 0
        filled = Array(repeating: nil, count: t.slots(log, recipe: nil).count)
        // the edit's clips into the slots, in order, to start with
        for (i, c) in library.prefix(filled.count).enumerated() { filled[i] = c.id }
        slotOn = filled.firstIndex(where: { $0 == nil }) ?? 0
        if t.id == "recipe" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { choosingRecipe = true } }
    }

    /// The slots made again (a recipe picked changes how many): clips kept in order, as far as they go.
    private func fit() {
        let n = slots.count
        if filled.count > n { filled = Array(filled.prefix(n)) } else { filled += Array(repeating: nil, count: n - filled.count) }
        slotOn = min(slotOn, max(0, n - 1))
    }

    // MARK: 2 · fill the slots

    private func filling(_ t: EditTemplate) -> some View {
        let s = slots
        return VStack(spacing: 0) {
            HStack {
                Button { picked = nil } label: { Image(systemName: "chevron.backward").font(.headline).frame(width: 36, height: 36).background(.white.opacity(0.12), in: Circle()) }
                    .accessibilityLabel("Back to the templates")
                Spacer()
                Text(t.name).font(.headline)
                Spacer()
                Text("\(s.count) slots").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(s.indices, id: \.self) { i in slotTile(i, s[i]) } }.padding(.horizontal, 16).padding(.vertical, 4)
                    }
                    if t.id == "recipe" {
                        Button { choosingRecipe = true } label: {
                            Label(recipe == nil ? "Pick a recipe" : "Recipe: " + str(recipe?["name"]), systemImage: "fork.knife")
                                .font(.subheadline.weight(.bold)).lineLimit(1).frame(maxWidth: .infinity).frame(height: 40)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 10)
                    }
                    heading("The words on each")
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(s.indices, id: \.self) { i in
                            let line = [s[i].name, s[i].detail].filter { !$0.isEmpty }.joined(separator: " · ")
                            Text(line.isEmpty ? "Slot \(i + 1)" : line).font(.subheadline.weight(i == slotOn ? .bold : .regular))
                                .foregroundStyle(i == slotOn ? .white : Color(white: 0.75)).lineLimit(2)
                                .onTapGesture { slotOn = i }
                        }
                    }
                    .padding(.horizontal, 16)
                    if s.indices.contains(slotOn), let id = filled[safe: slotOn] ?? nil, let k = library.firstIndex(where: { $0.id == id }) {
                        whichPart(k, beats: s[slotOn].beats)
                    }
                    heading("Your clips: tap one for slot \(slotOn + 1)")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3) {
                        ForEach(library) { c in clipTile(c) }
                        Button { adding = true } label: {
                            Color(white: 0.14).aspectRatio(3 / 4, contentMode: .fit)
                                .overlay { Image(systemName: "plus").font(.title3.weight(.bold)) }
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Add clips from Photos")
                    }
                    .padding(.horizontal, 16)
                    Text("Slots left empty are left out. Everything can be changed in the editor after.")
                        .font(.caption).foregroundStyle(.secondary).padding(16)
                }
                .padding(.bottom, 90)
            }
        }
        .overlay(alignment: .bottom) {
            let ready = filled.contains { $0 != nil }
            Button { finish(t) } label: {
                Text("Make it").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 50)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain).disabled(!ready).opacity(ready ? 1 : 0.4)
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    private func heading(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
    }

    private func slotTile(_ i: Int, _ s: EditTemplate.Slot) -> some View {
        let id = filled[safe: i] ?? nil
        let c = library.first { $0.id == id }
        return ZStack(alignment: .bottom) {
            if let c, let img = thumbs[c.id] {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 68, height: 110).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            } else if c != nil {
                Color(white: 0.2)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Color(white: 0.35))
            }
            VStack(spacing: 1) {
                Text(s.name.isEmpty ? "Slot \(i + 1)" : s.name).font(.system(size: 11, weight: .bold)).lineLimit(2).multilineTextAlignment(.center)
                Text("\(s.beats) beats").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 4).padding(.bottom, 6)
            .frame(maxHeight: c == nil ? .infinity : nil)
        }
        .frame(width: 68, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: i == slotOn ? 2.5 : 0))
        .overlay(alignment: .topTrailing) {
            if c != nil {
                Button { filled[i] = nil; slotOn = i } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)).frame(width: 20, height: 20).background(.black.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain).padding(4).accessibilityLabel("Empty this slot")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { slotOn = i }
    }

    private func clipTile(_ c: Clip) -> some View {
        let at = filled.enumerated().filter { $0.element == c.id }.map { $0.offset + 1 }
        return Button { put(c.id) } label: {
            ZStack(alignment: .topTrailing) {
                Color(white: 0.16).aspectRatio(3 / 4, contentMode: .fit)
                    .overlay { if let img = thumbs[c.id] { Image(uiImage: img).resizable().scaledToFill() } }
                    .clipped()
                if let n = at.first {
                    Text("\(n)").font(.system(size: 11, weight: .black)).foregroundStyle(.black).frame(width: 19, height: 19)
                        .background(Color(red: 1, green: 0.84, blue: 0.04), in: Circle()).padding(4)
                }
                if !c.still {
                    Text(EditFlow.clock(c.length)).font(.system(size: 10, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: Capsule()).padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The clip into the slot that's picked, then on to the next empty one.
    private func put(_ id: UUID) {
        guard filled.indices.contains(slotOn) else { return }
        filled[slotOn] = id
        UISelectionFeedbackGenerator().selectionChanged()
        if let next = filled.indices.first(where: { $0 > slotOn && filled[$0] == nil }) ?? filled.firstIndex(where: { $0 == nil }) { slotOn = next }
    }

    /// Which part of the slot's clip plays: where it starts (a slot lasts about half a second a beat; the editor
    /// cuts it to the song's own).
    private func whichPart(_ k: Int, beats: Int) -> some View {
        let c = library[k], need = Double(beats) * 0.5 * max(c.speed, 0.01), room = max(0, c.length - need)
        return VStack(alignment: .leading, spacing: 4) {
            heading("Which part plays")
            if c.still || room < 0.1 {
                Text(c.still ? "A photo: it shows for the whole slot." : "This clip's about as long as the slot: it all plays.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            } else {
                HStack {
                    Slider(value: Binding(get: { min(library[k].start, room) }, set: { library[k].start = $0; library[k].end = min(c.length, $0 + need) }), in: 0...room)
                        .tint(.white)
                    Text("from " + EditFlow.clock(library[k].start)).font(.caption.weight(.semibold)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                .padding(.horizontal, 16)
            }
        }
        .task(id: Int(library[k].start * 4)) {
            try? await Task.sleep(for: .milliseconds(250))
            if let img = await ClipJoin.frame(library[k], at: library[k].start) { thumbs[library[k].id] = img }
        }
    }

    /// The filled slots, in order, each with its clip (one used twice is a copy of its own).
    private func finish(_ t: EditTemplate) {
        let s = slots
        var used: [Clip] = [], kept: [EditTemplate.Slot] = [], seen = Set<UUID>()
        for i in s.indices {
            guard let id = filled[safe: i] ?? nil, var c = library.first(where: { $0.id == id }) else { continue }
            if !seen.insert(id).inserted { c.id = UUID() }
            used.append(c); kept.append(s[i])
        }
        guard !used.isEmpty else { return }
        make(t, used, kept, t.id == "recipe" ? recipe : nil)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
