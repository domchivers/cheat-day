import SwiftUI
import MapKit
import HealthKit

/// Workouts' Start (26 Nov, design/start-anything-mockup.html): what are you doing? A run, ride, walk or hike, each
/// tracked on the map, or Just time it for anything else. The last pick is remembered.
struct StartPicker: View {
    /// "run", "ride", "walk", "hike" or "time".
    var pick: (String) -> Void
    /// For the Start sheet test only: where the title and the last line are on screen.
    var mark: ((String, CGRect) -> Void)? = nil
    /// Space under the last line (the Start panel's is above the home indicator, which adds its own).
    var foot: CGFloat = 26
    @AppStorage("start.last") private var last = "run"

    var body: some View {
        VStack(spacing: 12) {
            Text("What are you doing?").font(.title3.weight(.heavy))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mark?("title", $0) }
                .padding(.top, 24)
            // (a plain grid, not a lazy one: 1.4.62's lazy tiles were made once the panel was already sliding, and
            // popped up in their final place ahead of it, "coming up weirdly")
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { tile(.run); tile(.ride) }
                GridRow { tile(.walk); tile(.hike) }
            }
            Button { choose("time") } label: {
                HStack(spacing: 12) {
                    Image(systemName: "stopwatch").font(.title3.weight(.bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Just time it").font(.headline)
                        Text("Yoga, HIIT, a class, a swim, anything").font(.caption).opacity(0.75)
                    }
                    Spacer()
                }
                .foregroundStyle(last == "time" ? Theme.onAccent : Color.primary)
                .padding(14).frame(maxWidth: .infinity)
                .background(last == "time" ? Theme.accent : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain).accessibilityLabel("Just time it")
            Text("Remembers what you picked last").font(.caption).foregroundStyle(.secondary)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mark?("last line", $0) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, foot)
    }

    private func tile(_ k: MoveKind) -> some View {
        let on: Bool = last == k.rawValue
        return Button { choose(k.rawValue) } label: {
            VStack(spacing: 6) {
                Image(systemName: k.symbol).font(.system(size: 24, weight: .bold)).frame(height: 30)
                Text(k.title).font(.headline)
                Text(k.shows).font(.caption).opacity(0.75)
            }
            .foregroundStyle(on ? Theme.onAccent : Color.primary)
            .frame(maxWidth: .infinity).frame(height: 104)
            .background(on ? Theme.accent : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityLabel(k.title)
    }

    private func choose(_ p: String) { last = p; pick(p) }
}

/// Start as Workouts presents it: our own panel, full width and down to the bottom of the screen, the page dimmed
/// behind (25 Nov, design/start-panel-mockup.html). Apple's sheet at this height floats in from the screen's sides
/// and foot, and the page showed round and under it: the gap 1.4.58-1.4.61 chased inside the sheet (whose own
/// numbers were right all along). Drag it down or tap above it to close. It's shown in a full-screen cover with no
/// animation of its own (StartPanel.present), so it's over the tab bar, and slides itself up and down.
struct StartPanel: View {
    /// Done: what they picked ("run", "ride", "walk", "hike" or "time"), or nil if they closed it. Called once it's
    /// slid away.
    var done: (String?) -> Void
    @State private var shown = false
    @State private var drag: CGFloat = 0
    @State private var tall: CGFloat = 520
    @State private var leaving = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.45 : 0).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { leave(nil) }
                .accessibilityLabel("Close").accessibilityAddTraits(.isButton)
            VStack(spacing: 0) {
                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 36, height: 5).padding(.top, 7)
                StartPicker(pick: { p in leave(p) }, foot: 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -10)   // (the grabber takes some of the title's 24 above it)
            }
            .frame(maxWidth: .infinity)
            .background {
                // down past the home indicator to the screen's foot; the screen's own corners round it there
                UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32, style: .continuous)
                    .fill(Theme.bg).ignoresSafeArea(edges: .bottom)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall = $0 }
            .offset(y: shown ? max(0, drag) : tall + 60)
            .gesture(DragGesture()
                .onChanged { v in drag = v.translation.height > 0 ? v.translation.height : v.translation.height / 6 }
                .onEnded { v in
                    if v.translation.height > 90 || v.predictedEndTranslation.height > 240 { leave(nil) }
                    else { withAnimation(.snappy(duration: 0.25)) { drag = 0 } }
                })
        }
        .presentationBackground(.clear)
        .onAppear { withAnimation(.snappy(duration: 0.32)) { shown = true } }
    }

    private func leave(_ p: String?) {
        guard !leaving else { return }
        leaving = true
        withAnimation(.snappy(duration: 0.24)) { shown = false; drag = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { done(p) }
    }

    /// The cover put up or taken down with no slide of its own: the panel's is the only movement.
    static func present(_ on: Bool, _ flag: Binding<Bool>) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { flag.wrappedValue = on }
    }
}

/// A run, ride, walk or hike: the map with them on it, moving time (it pauses itself when they stop), distance,
/// pace or speed, the climb and kcal, and heart rate when a strap's connected. Stop saves it to Workouts and Apple
/// Health with its route. On a run, with Start running in their plan, a line offers that run's interval timer.
struct MoveView: View {
    let kind: MoveKind
    var following: (week: Int, run: Int)?
    var openIntervals: () -> Void
    /// For the screenshot harness: part way through, on a made-up route, and stopped at the lights or not.
    var preview: (route: [RoutePoint], seconds: Double, paused: Bool)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var strap = HeartStrap.shared
    @State private var started: Date?
    @State private var pausedAt: Date?
    @State private var pausedFor: TimeInterval = 0
    /// Paused by itself, at the lights.
    @State private var autoAt: Date?
    @State private var auto: AutoPause
    @State private var now = Date()
    @State private var tracker = RunTracker()
    @State private var workout: RunSession
    @State private var gps = false
    @State private var askMap = false
    @State private var confirmStop = false
    @State private var spokenKm = 0
    @State private var heart: [HRSample] = []
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var result: (seconds: Double, meters: Double, climb: Double, kcal: Double, route: [RoutePoint], health: Bool)?
    /// New bests it set, and second bests (26 Nov, design/bests-weekgoal-mockup.html).
    @State private var news: [BestNews] = []
    /// The route it's on when it's been done before, and the saved workout's id (26 Nov, matched routes).
    @State private var onRoute: RouteGroup?
    @State private var savedId: String = ""
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private var testing: Bool { preview != nil || RunTimerView.uiTest }
    private var store: Store { Store.shared }

    init(kind: MoveKind, following: (week: Int, run: Int)? = nil, openIntervals: @escaping () -> Void = {},
         preview: (route: [RoutePoint], seconds: Double, paused: Bool)? = nil) {
        self.kind = kind; self.following = following; self.openIntervals = openIntervals; self.preview = preview
        _auto = State(initialValue: AutoPause(stopBelow: kind.stopBelow))
        _workout = State(initialValue: RunSession(activity: kind.hk, outdoor: true, distanceType: kind.distance))
    }

    /// Moving time: pauses, theirs and the lights', left out.
    private var elapsed: Double {
        guard let started else { return 0 }
        return max(0, (pausedAt ?? autoAt ?? now).timeIntervalSince(started) - pausedFor)
    }
    private var climb: Double { RouteMath.climb(tracker.points) }
    private var kcalSoFar: Double { kind.kcal(seconds: elapsed, meters: tracker.meters, climb: climb, kg: store.weightKg) }

    var body: some View {
        Group {
            if let result { doneView(result) } else { moveView }
        }
        .background(Theme.bg.ignoresSafeArea())
        .interactiveDismissDisabled(started != nil && result == nil)
        .onReceive(tick) { d in ticked(d) }
        .onAppear(perform: appeared)
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            tracker.stop()
            Cues.quiet()
            if started != nil && result == nil { workout.discard() }
        }
        .sheet(isPresented: $askMap) {
            MapAsk { (yes: Bool) in
                RunTracker.asked = true; RunTracker.wanted = yes; askMap = false
                if yes { Task { gps = await tracker.warm() } }
            }
            .presentationDetents([.medium, .large]).interactiveDismissDisabled()
        }
        .confirmationDialog("Finish this \(kind.title.lowercased())?", isPresented: $confirmStop, titleVisibility: .visible) {
            if elapsed >= 60 { Button("Save it") { finish() } }
            Button("Throw it away", role: .destructive) { workout.discard(); tracker.stop(); started = nil; dismiss() }
        } message: {
            Text(elapsed >= 60 ? "It goes in Workouts and Apple Health." : "Under a minute isn't saved.")
        }
    }

    private func appeared() {
        UIApplication.shared.isIdleTimerDisabled = true
        if let p = preview {
            started = Date().addingTimeInterval(-p.seconds); now = Date()
            tracker.running = true
            tracker.preview(p.route, speed: p.paused ? 0 : 3.2)
            if p.paused { autoAt = Date() }
            gps = true
            camera = .automatic
            return
        }
        strap.reconnect()
        if testing {
            // the UI test's ready screen: Albert Park, as before (it showed all of Australia in 1.4.57)
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: -37.8455, longitude: 144.9715),
                                                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
            return
        }
        if RunTracker.wanted { Task { gps = await tracker.warm() } }   // a fix by Start
        else if !RunTracker.asked { askMap = true }
    }

    // MARK: ready and going

    private var moveView: some View {
        VStack(spacing: 14) {
            HStack {
                Text(started == nil ? kind.title : pausedAt != nil ? "Paused" : kind.doing).font(.title2.weight(.heavy))
                Spacer()
                if started == nil {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Close")
                }
            }
            liveMap.frame(maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if autoAt != nil && pausedAt == nil {
                Label("Paused, you've stopped. Carries on when you move", systemImage: "pause.fill")
                    .font(.footnote.weight(.bold)).foregroundStyle(Color.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Color.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            stats
            if strap.state == .connected, let b = strap.bpm { LiveHeart(bpm: b, onRun: kind == .run) }
            if started == nil { readyButtons } else { goingButtons }
            if strap.state == .connected { StrapLine() }
        }
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 18)
    }

    /// Two rows of three: time, distance and pace or speed; then the other one of those, the climb, and kcal.
    private var stats: some View {
        let t: Double = elapsed, m: Double = tracker.meters
        let avg: Double? = m >= 20 && t > 0 ? t / m * 1000 : nil
        let kmhAvg: String = m >= 20 && t > 0 ? String(format: "%.1f", m / t * 3.6) : "0.0"
        let kmhNow: String = String(format: "%.1f", max(0, (tracker.speedNow ?? 0) * 3.6))
        let paceNow: String = RouteMath.pace(started == nil ? nil : tracker.pace)
        return VStack(spacing: 12) {
            HStack(spacing: 0) {
                MoveStat(value: RunStart.mmss(Int(t)), label: "moving time")
                MoveStat(value: RouteMath.km(m), label: "km")
                if kind.speed { MoveStat(value: kmhAvg, label: "km/h avg") } else { MoveStat(value: paceNow, label: "pace /km") }
            }
            HStack(spacing: 0) {
                if kind.speed { MoveStat(value: kmhNow, label: "km/h now") } else { MoveStat(value: RouteMath.pace(avg), label: "avg /km") }
                MoveStat(value: Fmt.int(climb), label: "m climbed")
                MoveStat(value: Fmt.int(kcalSoFar), label: "kcal")
            }
        }
    }

    private var readyButtons: some View {
        VStack(spacing: 10) {
            Button(action: start) {
                Label("Start \(kind.title.lowercased())", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            statusLine
            if let f = following {
                Button(action: openIntervals) {
                    Text("Following Start running? Week \(f.week), run \(f.run) is in your plan")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent).multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var goingButtons: some View {
        HStack(spacing: 12) {
            Button { confirmStop = true } label: { Text("Stop").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.bordered)
            Button { pausedAt == nil ? pause() : resume() } label: {
                Text(pausedAt == nil ? "Pause" : "Carry on").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
        }
    }

    /// Them on the map, and the route so far.
    private var liveMap: some View {
        let lines: [(run: Bool, points: [CLLocationCoordinate2D])] = RouteMath.stretches(tracker.points)
        let colour: Color = kind == .run ? Color.green : Theme.accent
        return Map(position: $camera, interactionModes: started == nil ? .all : [.zoom]) {
            UserAnnotation()
            // the quiet map and a glow under the line (26 Nov, design/map-style-mockup.html, A); paced colours once saved
            ForEach(lines.indices, id: \.self) { i in
                MapPolyline(coordinates: lines[i].points)
                    .stroke(colour.opacity(0.35), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
            }
            ForEach(lines.indices, id: \.self) { i in
                MapPolyline(coordinates: lines[i].points)
                    .stroke(colour, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.quiet)
        .overlay(alignment: .topTrailing) {
            Button { withAnimation { camera = .userLocation(fallback: .automatic) } } label: {
                Image(systemName: "location.fill").font(.subheadline.weight(.bold)).padding(9).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain).padding(10).accessibilityLabel("Back to where you are")
        }
    }

    /// Under Start: whether GPS has them, or that it won't be mapped (and a way to map it).
    @ViewBuilder private var statusLine: some View {
        if gps {
            HStack(spacing: 6) {
                Circle().fill(tracker.ready ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(tracker.rough ? "Precise location is off, so this won't be mapped" : tracker.ready ? "GPS ready" : "Finding GPS…")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        } else if RunTracker.asked && !RunTracker.wanted && !testing {
            Button {
                RunTracker.wanted = true
                Task { gps = await tracker.warm() }
            } label: {
                Text("Mapping is off, so it times you only. **Map my runs**").font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: done

    private func doneView(_ r: (seconds: Double, meters: Double, climb: Double, kcal: Double, route: [RoutePoint], health: Bool)) -> some View {
        VStack(spacing: 14) {
            // (scrolls, with bests and a route's card under a 260 pt map; Done stays put)
            ScrollView {
                VStack(spacing: 14) {
                    if r.route.count > 1 && r.meters >= 50 {
                        RunMap(points: r.route, interactive: false).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        Image(systemName: kind.symbol).font(.system(size: 48, weight: .heavy)).foregroundStyle(.green)
                            .frame(width: 110, height: 110).background(Color.green.opacity(0.18), in: Circle()).padding(.top, 30)
                    }
                    Text("\(kind.title) saved").font(.title.weight(.heavy))
                    HStack(spacing: 0) {
                        MoveStat(value: RunStart.mmss(Int(r.seconds.rounded())), label: "moving time")
                        if r.meters >= 50 {
                            MoveStat(value: RouteMath.km(r.meters), label: "km")
                            if kind.speed { MoveStat(value: String(format: "%.1f", r.meters / r.seconds * 3.6), label: "km/h") }
                            else { MoveStat(value: RouteMath.pace(r.seconds / r.meters * 1000), label: "pace /km") }
                        }
                        MoveStat(value: Fmt.int(r.kcal), label: "kcal")
                    }
                    if r.climb >= 1 { Text("\(Fmt.int(r.climb)) m climbed").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                    // a route done before (26 Nov, design/matched-routes-mockup.html)
                    if let g = onRoute { RouteNewsCard(group: g, id: savedId) }
                    // new bests first, then a second best; three at most
                    ForEach(Array(news.prefix(3))) { (n: BestNews) in BestNewsCard(news: n) }
                    Text(r.health ? "It's in Workouts and Apple Health." : "It's in Workouts.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Button { dismiss() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).buttonBorderShape(.roundedRectangle(radius: 14))
        }
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 18)
    }

    // MARK: the clock

    private func start() {
        started = Date(); now = Date(); spokenKm = 0; heart = []
        auto = AutoPause(stopBelow: kind.stopBelow)
        tracker.running = true
        if gps { tracker.start() }
        if !testing { camera = .userLocation(followsHeading: false, fallback: .automatic) }
        Cues.prepare()
        Cues.say("\(kind.title) started.", run: true)
        Task {
            _ = await workout.start()
            tracker.healthRoute = workout.routeBuilder
        }
    }

    private func ticked(_ d: Date) {
        guard result == nil, pausedAt == nil else { return }
        now = d
        guard started != nil, preview == nil else { return }
        // the lights: stopped for a few seconds pauses the clock, moving again carries on
        let stopped: Bool = auto.update(speed: gps ? tracker.speedNow : nil, at: d)
        if stopped && autoAt == nil {
            autoAt = d
            if tracker.recording { tracker.pause() }
            workout.pause()
        } else if !stopped, let a = autoAt {
            pausedFor += d.timeIntervalSince(a); autoAt = nil
            if !tracker.recording { tracker.resume() }
            workout.resume()
        }
        // the strap's reading every five seconds, while moving
        if autoAt == nil, let b = strap.bpm, strap.state == .connected, elapsed - (heart.last?.t ?? -10) >= 5 {
            heart.append(HRSample(t: elapsed, bpm: Double(b)))
        }
        sayDistance()
    }

    private func pause() {
        // paused at the lights already: that time counts as paused up to now
        if let a = autoAt { pausedFor += Date().timeIntervalSince(a); autoAt = nil }
        pausedAt = Date()
        workout.pause()
        if tracker.recording { tracker.pause() }
    }

    private func resume() {
        guard let p = pausedAt else { return }
        pausedFor += Date().timeIntervalSince(p); pausedAt = nil; now = Date()
        auto = AutoPause(stopBelow: kind.stopBelow)
        workout.resume()
        if !tracker.recording { tracker.resume() }
    }

    /// A word every kilometre (five on a ride): how far, and the pace or speed so far.
    private func sayDistance() {
        let m: Double = tracker.meters
        let k: Int = Int(m / 1000) / kind.sayEvery * kind.sayEvery
        guard k > spokenKm, m > 0, elapsed > 0 else { return }
        spokenKm = k
        let how: String = kind.speed ? "Average \(Int((m / elapsed * 3.6).rounded())) kilometres an hour." : "Average pace \(RouteMath.pace(elapsed / m * 1000))."
        Cues.say("\(k) kilometre\(k == 1 ? "" : "s"). \(how)", run: false)
    }

    private func finish() {
        let t: Double = elapsed
        let route: [RoutePoint] = tracker.points
        tracker.stop()
        let meters: Double = RouteMath.meters(route), up: Double = RouteMath.climb(route)
        let kcal: Double = kind.kcal(seconds: t, meters: meters, climb: up, kg: store.weightKg)
        let health: Bool = !testing && HealthSync.available
            && HealthSync.health.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        workout.finish(meters: meters, kcal: kcal)
        let id: String = store.logMove(kind, start: started ?? Date(), end: Date(), seconds: t, route: route, kcal: kcal, heart: heart)
        let found: [BestNews] = store.bestNews(for: id)
        // a new best beating one they had is worth saying; a first time isn't news yet
        let beat: Bool = found.contains { (n: BestNews) -> Bool in n.place == 1 && n.other != nil }
        Cues.say("\(kind.title) saved. " + (beat ? "That's a new best." : "Nice work."), run: false)
        let group: RouteGroup? = store.routeGroup(for: id)
        withAnimation { news = found; savedId = id; onRoute = group; result = (t, meters, up, kcal, route, health) }
    }
}

/// Just time it (26 Nov, design/start-anything-mockup.html): pick the kind, Start, and the minutes log themselves,
/// with a running kcal guess from the effort. Saved to Workouts and Apple Health.
struct TimeItView: View {
    /// For the screenshot harness: this chip, so many seconds in.
    var preview: (chip: String, seconds: Double)?

    static let chips: [(label: String, type: String, hk: HKWorkoutActivityType)] = [
        ("Yoga", "Yoga / stretch", .yoga), ("HIIT", "HIIT", .highIntensityIntervalTraining), ("Swim", "Swim", .swimming),
        ("Sport", "Team sport", .other), ("Tennis", "Tennis / padel", .tennis), ("Rowing", "Rowing", .rowing), ("Other", "Other", .other),
    ]

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var strap = HeartStrap.shared
    @AppStorage("timeit.last") private var chip = "Yoga"
    @AppStorage("timeit.effort") private var effort = "moderate"
    @State private var started: Date?
    @State private var pausedAt: Date?
    @State private var pausedFor: TimeInterval = 0
    @State private var now = Date()
    @State private var workout = RunSession(activity: .yoga, outdoor: false, distanceType: nil)
    @State private var heart: [HRSample] = []
    @State private var confirmStop = false
    @State private var done: (seconds: Double, kcal: Double)?
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private var store: Store { Store.shared }

    private var picked: (label: String, type: String, hk: HKWorkoutActivityType) {
        Self.chips.first { $0.label == chip } ?? Self.chips[0]
    }
    private var elapsed: Double {
        guard let started else { return 0 }
        return max(0, (pausedAt ?? now).timeIntervalSince(started) - pausedFor)
    }
    private var kcalSoFar: Double { store.burn(picked.type, minutes: elapsed / 60, effort: effort) }

    var body: some View {
        Group {
            if let done { doneView(done) } else { timingView }
        }
        .background(Theme.bg.ignoresSafeArea())
        .interactiveDismissDisabled(started != nil && done == nil)
        .onReceive(tick) { d in
            guard done == nil, pausedAt == nil else { return }
            now = d
            guard started != nil, preview == nil else { return }
            if let b = strap.bpm, strap.state == .connected, elapsed - (heart.last?.t ?? -10) >= 5 {
                heart.append(HRSample(t: elapsed, bpm: Double(b)))
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if let p = preview { chip = p.chip; started = Date().addingTimeInterval(-p.seconds); now = Date() }
            else { strap.reconnect() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if started != nil && done == nil { workout.discard() }
        }
        .confirmationDialog("Save this \(picked.label.lowercased())?", isPresented: $confirmStop, titleVisibility: .visible) {
            if elapsed >= 60 { Button("Save it") { finish() } }
            Button("Throw it away", role: .destructive) { workout.discard(); started = nil; dismiss() }
        } message: {
            Text(elapsed >= 60 ? "It goes in Workouts and Apple Health." : "Under a minute isn't saved.")
        }
    }

    private var timingView: some View {
        VStack(spacing: 16) {
            HStack {
                Text(started == nil ? "Just time it" : pausedAt == nil ? "Timing" : "Paused").font(.title2.weight(.heavy))
                Spacer()
                if started == nil {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Close")
                }
            }
            chipGrid.disabled(started != nil)
            Spacer()
            Text(RunStart.mmss(Int(elapsed))).font(.system(size: 88, weight: .heavy, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text("about \(Fmt.int(kcalSoFar)) kcal so far").font(.subheadline).foregroundStyle(.secondary)
            Picker("Effort", selection: $effort) {
                Text("Easy").tag("easy"); Text("Moderate").tag("moderate"); Text("Hard").tag("hard")
            }
            .pickerStyle(.segmented).padding(.horizontal, 30)
            if strap.state == .connected, let b = strap.bpm { LiveHeart(bpm: b, onRun: false) }
            Spacer()
            if started == nil {
                Button(action: start) { Label("Start", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            } else {
                HStack(spacing: 12) {
                    Button { confirmStop = true } label: { Text("Stop and save").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(.bordered)
                    Button { pausedAt == nil ? pause() : resume() } label: {
                        Text(pausedAt == nil ? "Pause" : "Carry on").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                }
            }
            Text("Saves to Workouts and Apple Health").font(.caption).foregroundStyle(.secondary)
            if strap.state == .connected { StrapLine() }
        }
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 18)
    }

    private var chipGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 8)], spacing: 8) {
            ForEach(Self.chips.indices, id: \.self) { (i: Int) in
                let c: (label: String, type: String, hk: HKWorkoutActivityType) = Self.chips[i]
                let on: Bool = c.label == chip
                Button { chip = c.label } label: {
                    Label(c.label, systemImage: Activities.symbol(c.type)).font(.subheadline.weight(.bold))
                        .foregroundStyle(on ? Theme.onAccent : Color.primary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(on ? Theme.accent : Color(.secondarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func doneView(_ r: (seconds: Double, kcal: Double)) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: Activities.symbol(picked.type)).font(.system(size: 48, weight: .heavy)).foregroundStyle(.green)
                .frame(width: 110, height: 110).background(Color.green.opacity(0.18), in: Circle())
            Text("\(picked.label) saved").font(.title.weight(.heavy))
            Text("\(Int((r.seconds / 60).rounded())) minutes, about \(Fmt.int(r.kcal)) kcal.").font(.headline).foregroundStyle(.secondary)
            Spacer()
            Button { dismiss() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).buttonBorderShape(.roundedRectangle(radius: 14))
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
    }

    private func start() {
        started = Date(); now = Date(); heart = []
        workout.activity = picked.hk
        Task { _ = await workout.start() }
    }
    private func pause() { pausedAt = Date(); workout.pause() }
    private func resume() {
        guard let p = pausedAt else { return }
        pausedFor += Date().timeIntervalSince(p); pausedAt = nil; now = Date()
        workout.resume()
    }

    private func finish() {
        let t: Double = elapsed, k: Double = kcalSoFar
        workout.finish(meters: 0, kcal: k)
        store.logTimed(type: picked.type, name: picked.label == "Other" ? "Workout" : picked.label, start: started ?? Date(), end: Date(),
                       seconds: t, effort: effort, kcal: k, heart: heart)
        withAnimation { done = (t, k) }
    }
}

/// One number over its label, a third of the row.
struct MoveStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
