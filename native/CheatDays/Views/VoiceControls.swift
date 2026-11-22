import SwiftUI

/// The record button, its presses told as they happen.
struct RecordButton: View {
    let recording: Bool
    let count: Int?
    let pressed: () -> Void
    let released: () -> Void
    @State private var down = false
    @GestureState private var touching = false

    var body: some View {
        let inner: CGFloat = recording ? 24 : 42
        let corner: CGFloat = recording ? 5 : 21
        return ZStack {
            Circle().stroke(Color.white, lineWidth: 3).frame(width: 56, height: 56)
            if let count {
                Text("\(count)").font(.system(size: 26, weight: .bold)).monospacedDigit()
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color(red: 1, green: 0.3, blue: 0.3))
                    .frame(width: inner, height: inner)
            }
        }
        .frame(width: 88, height: 64)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, on, _ in on = true }
            .onChanged { _ in touched() }
            .onEnded { _ in lifted() })
        .onChange(of: touching) { (_: Bool, on: Bool) in
            if !on { lifted() }
        }
        .onDisappear { lifted() }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(recording ? "Recording: tap to stop" : "Tap to record a voiceover, or hold to talk")
        .accessibilityAction {
            pressed()
            released()
        }
    }

    private func touched() {
        guard !down else { return }
        down = true
        pressed()
    }

    private func lifted() {
        guard down else { return }
        down = false
        released()
    }
}

/// The level as it records.
struct LiveMeter: View {
    let meter: VoiceMeter

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
            ProWave(levels: meter.snapshot(), colour: Color(red: 1, green: 0.3, blue: 0.3))
        }
        .frame(height: 24)
    }
}

/// How long it's been recording.
struct RecordTimer: View {
    let began: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            Text(MultiClipEditor.tenths(max(0, context.date.timeIntervalSince(began))))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}
