import SwiftUI
import AVFoundation
import UserNotifications

/// Start running's timer (25 Nov, design/start-running-mockup.html): green to run, blue to walk, the time left in this
/// part big, what's next, the whole run as a bar. A voice and a buzz at every switch, over their music; the screen
/// stays on, and locked, a notification says when to switch. Finished (or ended after a minute) it's logged as a run.
struct RunTimerView: View {
    let week: Int
    let run: Int
    @Environment(\.dismiss) private var dismiss
    @State private var started: Date?
    @State private var pausedAt: Date?
    @State private var pausedFor: TimeInterval = 0
    @State private var now = Date()
    @State private var part = -1
    @State private var result: (minutes: Int, kcal: Double, complete: Bool)?
    @State private var confirmEnd = false
    /// The run as an Apple Health workout, so it carries on locked and is saved there (25 Nov).
    @State private var workout = RunSession()
    /// The route, with GPS, when they map their runs (25 Nov, design/run-route-mockup.html).
    @State private var tracker = RunTracker()
    @State private var gps = false
    @State private var askMap = false
    @State private var mapped: [RoutePoint] = []
    private var testing: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-runtimer") }
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private var store: Store { Store.shared }

    private var parts: [RunStart.Part] { RunStart.parts(week: week) }
    private var total: Int { RunStart.seconds(week: week) }

    /// Seconds in, not counting pauses.
    private var elapsed: Double {
        guard let started else { return 0 }
        let end: Date = pausedAt ?? now
        return max(0, end.timeIntervalSince(started) - pausedFor)
    }

    /// The part they're in, and how far into it.
    private func position(_ t: Double) -> (index: Int, left: Double) {
        var edge: Double = 0
        for (i, p) in parts.enumerated() {
            edge += Double(p.seconds)
            if t < edge { return (i, edge - t) }
        }
        return (parts.count, 0)
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            if let result { doneView(result) } else { timerView }
        }
        .onReceive(tick) { d in
            guard result == nil, pausedAt == nil, started != nil else { return }
            now = d
            let p: Int = position(elapsed).index
            if p != part { switched(to: p) }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // GPS on early, so it has a fix by Start
            if RunTracker.wanted && !testing { Task { gps = await tracker.warm() } }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; Cues.cancelNotes(); tracker.stop() }
        .sheet(isPresented: $askMap) {
            MapAsk { (yes: Bool) in
                RunTracker.asked = true; RunTracker.wanted = yes; askMap = false
                Task { if yes { gps = await tracker.warm() }; begin() }
            }
            .presentationDetents([.medium, .large]).interactiveDismissDisabled()
        }
        .confirmationDialog("End this run?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End and log what I did") { finish(complete: false) }
            Button("Throw it away", role: .destructive) { Cues.cancelNotes(); workout.discard(); tracker.stop(); dismiss() }
        } message: { Text("A week moves on after three runs done to the end, so this one won't count towards it.") }
    }

    private var background: Color {
        guard result == nil, started != nil else { return Theme.bg }
        let i: Int = position(elapsed).index
        guard i < parts.count else { return Theme.bg }
        return parts[i].run ? Color(red: 0.05, green: 0.14, blue: 0.08) : Color(red: 0.06, green: 0.07, blue: 0.16)
    }

    // MARK: running

    private var timerView: some View {
        let t: Double = elapsed
        let pos: (index: Int, left: Double) = position(t)
        let cur: RunStart.Part? = pos.index < parts.count ? parts[pos.index] : nil
        let runs: [Int] = parts.indices.filter { parts[$0].run }
        let runNo: Int = (runs.firstIndex { $0 >= pos.index } ?? runs.count) + (cur?.run == true ? 1 : 0)
        return VStack(spacing: 0) {
            HStack {
                Text("Week \(week) · run \(run)")
                Spacer()
                Text("\(RunStart.mmss(Int(t))) in")
            }
            .font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            Spacer()
            if started == nil {
                VStack(spacing: 10) {
                    Text("Start running").font(.title.weight(.heavy))
                    Text("\(RunStart.middle(week: week)), with a 5-minute walk either side. \(RunStart.minutes(week: week)) minutes in all.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Lock your phone and put it away if you like: it keeps timing, and tells you when to switch.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if gps { gpsLine.padding(.top, 6) }
                }
            } else if let cur {
                Text(phaseName(pos.index)).font(.title2.weight(.black)).tracking(3).foregroundStyle(cur.run ? Color.green : Theme.accent)
                Text(RunStart.mmss(Int(pos.left.rounded(.up)))).font(.system(size: 104, weight: .heavy, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText()).padding(.top, 4)
                if pos.index + 1 < parts.count {
                    Text("Then \(parts[pos.index + 1].run ? "run" : "walk") \(RunStart.mmss(parts[pos.index + 1].seconds))").font(.headline).foregroundStyle(.secondary).padding(.top, 10)
                }
                if gps { liveStats(t).padding(.top, 34) }
            }
            Spacer()
            bar(t)
            HStack {
                Text(runs.isEmpty ? "" : "Run \(min(max(1, runNo), runs.count)) of \(runs.count)")
                Spacer()
                Text("\(RunStart.mmss(total - Int(t))) to go")
            }
            .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            HStack(spacing: 12) {
                if started == nil {
                    Button("Not now") { dismiss() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    Button { if RunTracker.asked || testing { begin() } else { askMap = true } } label: { Text("Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                } else {
                    Button { confirmEnd = true } label: { Text("End").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.bordered)
                    Button { pausedAt == nil ? pause() : resume() } label: {
                        Text(pausedAt == nil ? "Pause" : "Carry on").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                }
            }
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .padding(.top, 28)
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 24)
    }

    private func phaseName(_ i: Int) -> String {
        if i == 0 { return "WARM-UP WALK" }
        if i == parts.count - 1 && !parts[i].run { return "COOL-DOWN WALK" }
        return parts[i].run ? "RUN" : "WALK"
    }

    /// The whole run as bars, as long as each part, the done ones faded.
    private func bar(_ t: Double) -> some View {
        GeometryReader { g in
            let gaps: CGFloat = CGFloat(max(0, parts.count - 1)) * 3
            let per: CGFloat = (g.size.width - gaps) / CGFloat(max(1, total))
            HStack(spacing: 3) {
                ForEach(parts.indices, id: \.self) { i in
                    let before: Double = parts.prefix(i).reduce(0) { $0 + Double($1.seconds) }
                    Capsule().fill(parts[i].run ? Color.green : Theme.accent.opacity(0.55))
                        .opacity(t >= before + Double(parts[i].seconds) ? 0.3 : 1)
                        .frame(width: max(2, CGFloat(parts[i].seconds) * per))
                }
            }
        }
        .frame(height: 8)
    }

    // MARK: done

    private func doneView(_ r: (minutes: Int, kcal: Double, complete: Bool)) -> some View {
        VStack(spacing: 14) {
            Spacer()
            if mapped.count > 1 {
                RunMap(points: mapped, interactive: false).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(alignment: .bottomLeading) { routeBadge.padding(10) }
            } else {
                Image(systemName: r.complete ? "checkmark" : "figure.run").font(.system(size: 48, weight: .heavy)).foregroundStyle(.green)
                    .frame(width: 110, height: 110).background(Color.green.opacity(0.18), in: Circle())
            }
            Text(r.complete ? "Run \(run) of week \(week) done" : "Logged what you did").font(.title.weight(.heavy)).multilineTextAlignment(.center)
            Text("\(r.minutes) minutes, about \(Fmt.int(r.kcal)) kcal. Logged.").font(.headline).foregroundStyle(.secondary)
            Text(nextLine(r.complete)).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 10)
            Spacer()
            Button { dismiss() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).buttonBorderShape(.roundedRectangle(radius: 14))
        }
        .padding(.horizontal, 22).padding(.bottom, 24)
    }

    /// "3.92 km · 7:56 /km" over the done screen's map.
    private var routeBadge: some View {
        let m: Double = RouteMath.meters(mapped), secs: Double = mapped.last?.t ?? 0
        return Text("\(RouteMath.km(m)) km · \(RouteMath.pace(m > 0 ? secs / m * 1000 : nil)) /km")
            .font(.subheadline.weight(.heavy)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
    }

    /// Before Start: whether GPS has them yet.
    private var gpsLine: some View {
        let ok: Bool = tracker.ready
        return HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(tracker.rough ? "Precise location is off, so this run won't be mapped" : ok ? "GPS ready" : "Finding GPS…")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    /// Distance, pace over the last half minute, and time, under the countdown.
    private func liveStats(_ t: Double) -> some View {
        HStack(spacing: 0) {
            stat(RouteMath.km(tracker.meters), "km")
            stat(RouteMath.pace(tracker.pace), "pace /km")
            stat(RunStart.mmss(Int(t)), "time")
        }
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title2.weight(.heavy)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func nextLine(_ complete: Bool) -> String {
        let p: (week: Int, run: Int, finished: Bool) = store.startRun
        if p.finished { return "That's all 8 weeks: 30 minutes without stopping. Keep it up!" }
        let what: String = p.week > week ? "Week \(p.week) starts: \(RunStart.middle(week: p.week).lowercased())." : "Week \(p.week), run \(p.run): the same again."
        guard let n = store.workoutPlan?.activities.first(where: { $0.startRunning }) else { return what }
        let today: Int = DayKey.weekday(store.today)
        let next: Int? = (1...7).map { (today + $0) % 7 }.first { n.days.contains($0) }
        return next.map { "Next: \(Calendar.current.weekdaySymbols[$0]). " + what } ?? what
    }

    // MARK: the clock

    private func begin() {
        started = Date(); now = Date(); part = -1
        if gps { tracker.start() }
        Cues.prepare()
        Cues.scheduleNotes(parts: parts, from: 0)
        // as a workout it stays awake locked, so the voice is enough; without one, the notifications stay
        Task {
            if await workout.start() { Cues.cancelNotes() }
            tracker.healthRoute = workout.routeBuilder
        }
    }

    private func pause() {
        pausedAt = Date()
        Cues.cancelNotes()
        workout.pause(); tracker.pause()
    }

    private func resume() {
        guard let p = pausedAt else { return }
        pausedFor += Date().timeIntervalSince(p); pausedAt = nil; now = Date()
        workout.resume(); tracker.resume()
        if !workout.live { Cues.scheduleNotes(parts: parts, from: elapsed) }
    }

    /// Into a new part: say it, buzz, and at the end, log it.
    private func switched(to p: Int) {
        let first: Bool = part < 0
        part = p
        if p >= parts.count { finish(complete: true); return }
        let cur: RunStart.Part = parts[p]
        let words: String
        tracker.running = cur.run
        if first { words = "Warm-up walk. \(cur.seconds / 60) minutes." }
        else if p == parts.count - 1 && !cur.run { words = "Last bit. Walk and cool down." }
        else { words = cur.run ? "Run now. \(RunStart.clock(cur.seconds).replacingOccurrences(of: "½", with: " and a half")) minutes." : "Walk now." }
        Cues.say(words, run: cur.run)
    }

    private func finish(complete: Bool) {
        Cues.cancelNotes()
        let t: Double = elapsed
        var run: Double = 0, walk: Double = 0, edge: Double = 0
        for p in parts {
            let take: Double = max(0, min(Double(p.seconds), t - edge))
            if p.run { run += take } else { walk += take }
            edge += Double(p.seconds)
        }
        let route: [RoutePoint] = tracker.points
        tracker.stop()
        guard complete || t >= 60 else { workout.discard(); dismiss(); return }
        // to Health with its distance (mapped runs only) and active energy, the same kcal the app logs
        workout.finish(meters: RouteMath.meters(route), kcal: RunStart.kcal(runSeconds: run, walkSeconds: walk, kg: store.weightKg))
        store.logStartRun(week: week, run: self.run, runSeconds: run, walkSeconds: walk, complete: complete, route: route)
        mapped = RouteMath.meters(route) >= 50 ? route : []
        if complete { Cues.say("Done. Nice work.", run: false) }
        withAnimation { result = (Int(((run + walk) / 60).rounded()), RunStart.kcal(runSeconds: run, walkSeconds: walk, kg: store.weightKg), complete) }
    }
}

/// Before the first timed run (25 Nov, design/run-route-mockup.html): why it would like their location, and where the
/// route goes. Only a yes brings iOS's own ask. Either way the run starts.
private struct MapAsk: View {
    var answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "map.fill").font(.title2).foregroundStyle(Theme.accent)
                .frame(width: 54, height: 54).background(Theme.hero, in: Circle())
            Text("Map your runs?").font(.title2.weight(.heavy))
            Text("While the app times a run, it can follow your route with GPS: you'll see it on a map with your distance, pace and each kilometre.")
                .font(.subheadline)
            Text("Your routes stay on your phone and in Apple Health. They're never shared, and never sent to Cheat Days. Only runs you start here are tracked, and only while they're running.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { answer(true) } label: { Text("Map my runs").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            Button { answer(false) } label: { Text("Not now").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.bordered)
        }
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .padding(22)
    }
}

/// The voice, the buzz and the lock-screen notes.
@MainActor
enum Cues {
    static let voice = AVSpeechSynthesizer()

    static func prepare() {
        // over their music, which goes quieter while it speaks
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
        // (not in the UI test, where the ask would sit over the timer)
        guard !ProcessInfo.processInfo.arguments.contains("-uitest-runtimer") else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func say(_ words: String, run: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(run ? .warning : .success)
        try? AVAudioSession.sharedInstance().setActive(true)
        voice.speak(AVSpeechUtterance(string: words))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if !voice.isSpeaking { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }

    /// A notification at each switch still to come, for when the phone's locked.
    static func scheduleNotes(parts: [RunStart.Part], from t: Double) {
        cancelNotes()
        var edge: Double = 0
        for (i, p) in parts.enumerated() {
            edge += Double(p.seconds)
            guard edge > t + 1 else { continue }
            let c = UNMutableNotificationContent()
            if i + 1 < parts.count {
                let next: RunStart.Part = parts[i + 1]
                c.title = next.run ? "Run now" : "Walk now"
                c.body = "\(next.run ? "Run" : "Walk") for \(RunStart.mmss(next.seconds))."
            } else {
                c.title = "Run done"
                c.body = "Open Cheat Days to log it."
            }
            c.sound = .default
            let req = UNNotificationRequest(identifier: "run.switch.\(i)", content: c,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: edge - t, repeats: false))
            UNUserNotificationCenter.current().add(req)
        }
    }

    static func cancelNotes() {
        let ids: [String] = (0..<40).map { "run.switch.\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}
