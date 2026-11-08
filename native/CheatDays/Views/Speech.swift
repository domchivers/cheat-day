import AVFoundation
import Speech
import SwiftUI

/// Speaking into a chat box: the iPhone's own speech recognition (on the phone where it can be, so nothing is sent
/// anywhere for it), the words arriving in the box as they're said, the box's own words kept in front of them.
@Observable @MainActor
final class Speech {
    private(set) var listening = false
    /// How loud it is now, 0 to 1, for the bars while listening.
    private(set) var level: Float = 0
    var problem: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Starts listening; `heard` gets everything said so far each time it changes.
    func start(_ heard: @escaping (String) -> Void) async {
        guard !listening else { return }
        problem = nil
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { problem = "Speaking needs Speech Recognition: turn it on in Settings › Cheat Days."; return }
        guard await AVAudioApplication.requestRecordPermission() else { problem = "Speaking needs the microphone: turn it on in Settings › Cheat Days."; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            problem = "Speech isn't available right now."; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                req.append(buffer)
                let n = Int(buffer.frameLength)
                guard n > 0, let ch = buffer.floatChannelData?[0] else { return }
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let loud = min(1, sqrt(sum / Float(n)) * 12)
                Task { @MainActor in self?.level = loud }
            }
            engine.prepare()
            try engine.start()
            listening = true
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let words = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor in
                    if let words { heard(words) }
                    if error != nil || final { self?.stop() }
                }
            }
        } catch {
            problem = "Couldn't start listening."
            stop()
        }
    }

    func stop() {
        guard listening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        listening = false; level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The bars that move with the voice while listening.
struct SpeechBars: View {
    let level: Float
    @State private var tick = 0
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<16, id: \.self) { i in
                let wobble = 0.35 + 0.65 * abs(sin(Double(i * 7 + tick) * 0.9))
                Capsule().fill(Theme.accent).frame(width: 3, height: max(4, 30 * CGFloat(level) * wobble))
            }
        }
        .frame(height: 32)
        .animation(.easeOut(duration: 0.12), value: tick)
        .onReceive(timer) { _ in tick += 1 }
        .accessibilityLabel("Listening")
    }
}
