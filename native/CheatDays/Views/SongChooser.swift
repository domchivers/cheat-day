import SwiftUI

/// Choosing a song in the editor's sheet (design/editor-panels-mockup.html, 3): looked for or by mood, heard as
/// it's picked, and the part of it dragged along its wave.
struct SongChooser: View {
    @Binding var picked: Song?
    let hearing: () -> Void
    @State private var words = ""
    @State private var mood = SongSearch.all

    private var player: SongPlayer { SongPlayer.shared }

    var body: some View {
        VStack(spacing: 0) {
            search
            moods
            list
        }
        .onDisappear { leave() }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(ProInk.quiet)
            TextField("Search songs", text: $words).font(.system(size: 14)).autocorrectionDisabled()
            if !words.isEmpty {
                Button { words = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ProInk.quiet).frame(width: 30, height: 36)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear the search")
            }
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(ProInk.rule).frame(height: 0.5) }
        .padding(.horizontal, 16)
    }

    private var moods: some View {
        let names: [String] = [SongSearch.all] + Music.moods
        let searching: Bool = !words.trimmingCharacters(in: .whitespaces).isEmpty
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(names, id: \.self) { (name: String) in moodTab(name, on: name == mood && !searching) }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 34)
    }

    private func moodTab(_ name: String, on: Bool) -> some View {
        Button {
            words = ""
            mood = name
        } label: {
            Text(name).font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : ProInk.quiet)
                .frame(height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        let found: [Song] = SongSearch.find(Music.all, mood: mood, words: words)
        return ScrollView {
            LazyVStack(spacing: 0) {
                if found.isEmpty { ProHint(words: "No songs found.").frame(height: 40) }
                ForEach(found, id: \.id) { (song: Song) in row(song) }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private func row(_ song: Song) -> some View {
        let chosen: Song? = picked?.id == song.id ? picked : nil
        titleRow(song, chosen: chosen)
        if let chosen { partRow(chosen) }
    }

    private func titleRow(_ song: Song, chosen: Song?) -> some View {
        let on: Bool = chosen != nil
        let sounding: Bool = player.playing == Self.key(song)
        var part = ""
        if let chosen {
            let from: Double = Music.long[chosen.id] == nil ? 0 : chosen.from
            part = "\(MultiClipEditor.clock(from)) – \(MultiClipEditor.clock(from + Song.part))"
        }
        return Button { tapped(song) } label: {
            HStack(spacing: 12) {
                Image(systemName: sounding ? "pause.fill" : "play.fill").font(.system(size: 11)).frame(width: 14)
                Text(song.title).font(.system(size: 14)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(part).font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(on ? Color.white : ProInk.quiet)
            .frame(height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func partRow(_ song: Song) -> some View {
        if let long = Music.long[song.id], long.len > Song.part + 2 {
            PartWindow(levels: SongSearch.levels(long.wave), length: long.len, start: song.from,
                       moved: { (at: Double) in movePart(at, length: long.len) },
                       ended: { hearPart() })
                .padding(.bottom, 4)
        } else {
            ProHint(words: "This one has the one part, 30 seconds. It goes round to the end of your video.")
                .frame(height: 42)
        }
    }

    private static func key(_ song: Song) -> String { "edit:" + song.id }

    private func tapped(_ song: Song) {
        hearing()
        if let chosen = picked, chosen.id == song.id {
            if player.playing == Self.key(chosen) {
                player.stop()
                Sound.on(.moviePlayback)   // (a song stopped switches the phone's sound off: the editor still wants it)
            } else {
                player.play(chosen, key: Self.key(chosen), loop: true)
            }
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
        picked = song
        player.play(song, key: Self.key(song), loop: true)
    }

    private func movePart(_ at: Double, length: Double) {
        guard var song = picked else { return }
        song.start = SongSearch.start(at, length: length)
        picked = song
    }

    private func hearPart() {
        guard let song = picked else { return }
        hearing()
        player.play(song, key: Self.key(song), loop: true)
    }

    private func leave() {
        if player.playing?.hasPrefix("edit:") == true { player.stop() }
        // (a song stopped switches the phone's sound off: the editor still wants it)
        Sound.on(.moviePlayback)
    }
}

/// The 30 seconds of a song that'll play, dragged along its wave.
private struct PartWindow: View {
    let levels: [Float]
    let length: Double
    let start: Double
    let moved: (Double) -> Void
    let ended: () -> Void
    @State private var from: Double?
    @GestureState private var touching = false

    private static let pink = Color(red: 1, green: 0.56, blue: 0.74)

    var body: some View {
        GeometryReader { g in
            window(g.size)
        }
        .frame(height: 42)
        .accessibilityElement()
        .accessibilityLabel("The part of the song")
        .accessibilityValue("From \(MultiClipEditor.clock(start))")
        .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
            moved(direction == .increment ? start + 5 : start - 5)
            ended()
        }
    }

    private func window(_ size: CGSize) -> some View {
        let w: CGFloat = max(size.width, 1), h: CGFloat = size.height
        let wide: CGFloat = w * CGFloat(min(1, Song.part / max(length, 1)))
        let x: CGFloat = w * CGFloat(start / max(length, 1))
        return ZStack(alignment: .topLeading) {
            ProWave(levels: levels, colour: Color(white: 0.23))
            ProWave(levels: levels, colour: Self.pink)
                .mask(alignment: .leading) { Rectangle().frame(width: wide).offset(x: x) }
            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white, lineWidth: 2)
                .frame(width: wide, height: h).offset(x: x)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, on, _ in on = true }
            .onChanged { (v: DragGesture.Value) in dragged(v, width: w, x: x, wide: wide) }
            .onEnded { _ in letGo() })
        .onChange(of: touching) { (_: Bool, on: Bool) in
            if !on { letGo() }
        }
    }

    private func dragged(_ v: DragGesture.Value, width: CGFloat, x: CGFloat, wide: CGFloat) {
        if from == nil {
            let inside: Bool = v.startLocation.x >= x - 8 && v.startLocation.x <= x + wide + 8
            // (outside the window: it comes to the finger)
            from = inside ? start : Double((v.startLocation.x - wide / 2) / width) * length
        }
        moved((from ?? start) + Double(v.translation.width / width) * length)
    }

    private func letGo() {
        guard from != nil else { return }
        from = nil
        ended()
    }
}
