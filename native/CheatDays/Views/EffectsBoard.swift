import AVFoundation
import SwiftUI

/// One short sound heard by itself.
final class EffectHearing {
    private var player: AVAudioPlayer?

    func play(_ name: String) {
        stop()
        guard let url = SoundEffects.url(name) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

/// The sound effects: tap one to hear it, + puts it in at the line.
struct EffectsBoard: View {
    let hearing: () -> Void
    let add: (String) -> Void
    @State private var picked: String?
    @State private var waves: [String: [Float]] = [:]
    @State private var player = EffectHearing()

    var body: some View {
        let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(SoundEffects.names, id: \.self) { (name: String) in tile(name) }
        }
        .task { await load() }
        .onDisappear { player.stop() }
    }

    private func tile(_ name: String) -> some View {
        let on: Bool = picked == name
        let colour: Color = on ? Color.white : Color(white: 0.48)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button { hear(name) } label: {
            VStack(spacing: 4) {
                ProWave(levels: waves[name] ?? [], colour: colour).frame(height: 25)
                Text(name).font(.system(size: 11)).lineLimit(1).foregroundStyle(on ? Color.white : ProInk.soft)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity).frame(height: 60)
            .background(ProInk.tile, in: shape)
            .overlay(shape.strokeBorder(on ? Color.white : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityHint("Plays it")
        .overlay(alignment: .topTrailing) {
            if on { addButton(name).offset(x: 11, y: -11) }
        }
        .zIndex(on ? 1 : 0)
    }

    private func addButton(_ name: String) -> some View {
        Button {
            player.stop()
            add(name)
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black)
                .frame(width: 22, height: 22).background(Color.white, in: Circle())
                .frame(width: 38, height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(name) at the line")
    }

    private func hear(_ name: String) {
        hearing()
        picked = name
        player.play(name)
    }

    private func load() async {
        for name in SoundEffects.names where waves[name] == nil {
            guard !Task.isCancelled else { return }
            // (made the first time they're wanted: away from the screen)
            let found: (url: URL, length: Double)? = await Task.detached(priority: .utility) { () -> (url: URL, length: Double)? in
                guard let url = SoundEffects.url(name) else { return nil }
                return (url: url, length: SoundEffects.length(name))
            }.value
            guard let found, found.length > 0.01 else { continue }
            let read = Clip(source: found.url, length: found.length, start: 0, end: found.length)
            waves[name] = await ClipJoin.levels(read, count: 24)
        }
    }
}
