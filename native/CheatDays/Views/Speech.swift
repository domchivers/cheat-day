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
    /// Which listen the words coming in belong to: once it's done (stopped and its last words in, or sent), any words
    /// still on their way are let go.
    private var generation = 0
    /// What was heard before the recognizer began again from nothing, and what it has heard since.
    private var kept = "", last = ""

    /// Starts listening; `heard` gets everything said so far each time it changes.
    func start(_ heard: @escaping (String) -> Void) async {
        guard !listening else { return }
        problem = nil
        task?.cancel(); task = nil   // (the last listen's words, if they hadn't all come in yet)
        generation += 1
        let g = generation
        kept = ""; last = ""
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
                    guard let self, self.generation == g else { return }   // (a listen that's over)
                    // never an empty result over what's been heard (21 Nov: stopping put a shorter one in)
                    if let words, !words.isEmpty { heard(self.joined(words)) }
                    if error != nil || final { self.finish() }
                }
            }
        } catch {
            problem = "Couldn't start listening."
            finish()
        }
    }

    /// Everything heard in this listen: what came before a fresh start, and the words since. On the phone, after a
    /// pause the recognizer can begin again from nothing, and what was said before fell out of the box.
    private func joined(_ words: String) -> String {
        if !last.isEmpty, Self.beganAgain(words, after: last) { kept = kept.isEmpty ? last : kept + " " + last }
        last = words
        return kept.isEmpty ? words : kept + " " + words
    }

    /// Whether the words heard now are a fresh start rather than the same words heard better: much shorter, and not
    /// starting as before.
    static func beganAgain(_ now: String, after before: String) -> Bool {
        let a = now.lowercased().split(separator: " "), b = before.lowercased().split(separator: " ")
        guard let first = a.first, b.count >= 3 else { return false }
        return a.count * 2 < b.count && first != b.first
    }

    /// Stops listening, keeping what was said: the last words, which come in a moment after, still go in (21 Nov:
    /// stopping cancelled straight away, and what came back last wrote over what had been said). Let go once they're
    /// in, or after a second and a half.
    func stop() {
        guard listening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        listening = false; level = 0
        let g = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let self, self.generation == g { self.finish() }
        }
    }

    /// Stops listening and lets go of anything still coming (the box is being sent, or left).
    func cancel() {
        guard listening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        finish()
    }

    private func finish() {
        generation += 1
        if listening { engine.stop(); engine.inputNode.removeTap(onBus: 0) }   // (ended by the recognizer itself)
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
