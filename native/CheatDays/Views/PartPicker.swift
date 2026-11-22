import AVFoundation
import SwiftUI

/// Which part of an edit longer than a post can be to keep (21 Nov): a window as long as a post, slid along the
/// video's frames, the part in it playing round as it's moved.
struct PartPicker: View {
    let url: URL
    let length: Double
    var shape: CGFloat = VideoShape.tall
    let done: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var from = 0.0
    @State private var grabbed: Double?
    @State private var player = AVPlayer()
    @State private var frames: [UIImage] = []

    private var keep: Double { min(Stories.longest, length) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.white)
                Spacer()
                Text("Choose \(Int(Stories.longest)) seconds").font(.headline)
                Spacer()
                Button("Cancel") {}.hidden()
            }
            .padding(.horizontal, 16).padding(.top, 14)
            PlayerLayerView(player: player).aspectRatio(shape, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("\(EditFlow.clock(from)) – \(EditFlow.clock(from + keep)) of \(EditFlow.clock(length))")
                .font(.caption.weight(.heavy)).monospacedDigit()
            window.padding(.horizontal, 16)
            Button { player.pause(); done(from) } label: {
                Text("Use this part").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
            frames = await Self.frames(url, length: length)
        }
        // the part playing round: back to its start once it's played through
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let at = player.currentTime().seconds
                if grabbed == nil, at > from + keep - 0.05 || at < from - 0.3 { seek(from) }
            }
        }
        .onDisappear { player.pause() }
    }

    /// The frames along the whole video, dim outside the window, the window white-edged: drag it along.
    private var window: some View {
        GeometryReader { g in
            let w = g.size.width, k = w / CGFloat(max(length, 0.01))
            let x = CGFloat(from) * k, win = CGFloat(keep) * k
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(uiImage: frames[i]).resizable().scaledToFill()
                            .frame(width: w / CGFloat(max(frames.count, 1)), height: 56).clipped()
                    }
                }
                .frame(width: w, height: 56, alignment: .leading)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Color.black.opacity(0.55).frame(width: max(0, x), height: 56)
                Color.black.opacity(0.55).frame(width: max(0, w - x - win), height: 56).offset(x: x + win)
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white, lineWidth: 3)
                    .frame(width: win, height: 60).offset(x: x)
            }
            .frame(width: w, height: 60)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if grabbed == nil { grabbed = from; player.pause(); UISelectionFeedbackGenerator().selectionChanged() }
                    from = min(max(0, (grabbed ?? 0) + Double(v.translation.width / max(k, 0.001))), max(0, length - keep))
                    let near = CMTime(seconds: 0.04, preferredTimescale: 600)
                    player.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: near, toleranceAfter: near)
                }
                .onEnded { _ in grabbed = nil; seek(from); player.play() })
            .accessibilityElement()
            .accessibilityLabel("The part kept")
            .accessibilityValue("\(EditFlow.clock(from)) to \(EditFlow.clock(from + keep))")
            .accessibilityAdjustableAction { dir in
                from = min(max(0, from + (dir == .increment ? 5 : -5)), max(0, length - keep)); seek(from)
            }
        }
        .frame(height: 60)
    }

    private func seek(_ s: Double) { player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }

    /// Ten small frames along it.
    private static func frames(_ url: URL, length: Double) async -> [UIImage] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 120, height: 120)
        var out: [UIImage] = []
        for i in 0..<10 {
            let t = CMTime(seconds: length * (Double(i) + 0.5) / 10, preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image { out.append(UIImage(cgImage: img)) }
        }
        return out
    }
}
