import SwiftUI
import MapKit
import HealthKit

/// A run of their own, from Workouts' Run (26 Nov, design/start-run-mockup.html): the map with them on it, time, km
/// and pace, and Start run. It times and maps them (when they map their runs), and Stop saves it to Workouts and
/// Apple Health with its route. With Start running in their plan, a line offers that run's interval timer instead.
struct FreeRunView: View {
    /// Start running's next run, when it's in their plan.
    var following: (week: Int, run: Int)?
    /// Hand over to Start running's timer.
    var openIntervals: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var started: Date?
    @State private var pausedAt: Date?
    @State private var pausedFor: TimeInterval = 0
    @State private var now = Date()
    @State private var tracker = RunTracker()
    @State private var workout = RunSession()
    @State private var gps = false
    @State private var askMap = false
    @State private var confirmStop = false
    @State private var spokenKm = 0
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var result: (seconds: Double, meters: Double, kcal: Double, route: [RoutePoint], health: Bool)?
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private var testing: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-freerun") }
    private var store: Store { Store.shared }

    /// Seconds in, not counting pauses.
    private var elapsed: Double {
        guard let started else { return 0 }
        return max(0, (pausedAt ?? now).timeIntervalSince(started) - pausedFor)
    }

    var body: some View {
        Group {
            if let result { doneView(result) } else { runView }
        }
        .background(Theme.bg.ignoresSafeArea())
        .interactiveDismissDisabled(started != nil && result == nil)
        .onReceive(tick) { d in
            guard result == nil, pausedAt == nil else { return }
            now = d
            if started != nil { sayKilometres() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if testing {
                camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: -37.8455, longitude: 144.9715),
                                                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
            } else if RunTracker.wanted {
                // GPS on now, so there's a fix by Start
                Task { gps = await tracker.warm() }
            } else if !RunTracker.asked {
                askMap = true
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            tracker.stop()
            if started != nil && result == nil { workout.discard() }
        }
        .sheet(isPresented: $askMap) {
            MapAsk { (yes: Bool) in
                RunTracker.asked = true; RunTracker.wanted = yes; askMap = false
                if yes { Task { gps = await tracker.warm() } }
            }
            .presentationDetents([.medium, .large]).interactiveDismissDisabled()
        }
        .confirmationDialog("Finish this run?", isPresented: $confirmStop, titleVisibility: .visible) {
            if elapsed >= 60 { Button("Save run") { finish() } }
            Button("Throw it away", role: .destructive) { workout.discard(); tracker.stop(); started = nil; dismiss() }
        } message: {
            Text(elapsed >= 60 ? "It goes in Workouts and Apple Health." : "Runs under a minute aren't saved.")
        }
    }

    // MARK: ready and running

    private var runView: some View {
        let t: Double = elapsed
        return VStack(spacing: 18) {
            HStack {
                Text(started == nil ? "Run" : pausedAt == nil ? "Running" : "Paused").font(.title2.weight(.heavy))
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
            HStack(spacing: 0) {
                stat(RunStart.mmss(Int(t)), "time")
                stat(RouteMath.km(tracker.meters), "km")
                stat(RouteMath.pace(started == nil ? nil : tracker.pace), "pace /km")
            }
            if started == nil {
                Button(action: start) {
                    Label("Start run", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
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
            } else {
                HStack(spacing: 12) {
                    Button { confirmStop = true } label: { Text("Stop").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(.bordered)
                    Button { pausedAt == nil ? pause() : resume() } label: {
                        Text(pausedAt == nil ? "Pause" : "Carry on").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                }
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 18)
    }

    /// Them on the map, and the route so far.
    private var liveMap: some View {
        let lines: [(run: Bool, points: [CLLocationCoordinate2D])] = RouteMath.stretches(tracker.points)
        return Map(position: $camera, interactionModes: started == nil ? .all : [.zoom]) {
            UserAnnotation()
            ForEach(lines.indices, id: \.self) { i in
                MapPolyline(coordinates: lines[i].points)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topTrailing) {
            Button { withAnimation { camera = .userLocation(fallback: .automatic) } } label: {
                Image(systemName: "location.fill").font(.subheadline.weight(.bold)).padding(9).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain).padding(10).accessibilityLabel("Back to where you are")
        }
    }

    /// Under Start: whether GPS has them, or that the run won't be mapped (and a way to map it).
    @ViewBuilder private var statusLine: some View {
        if gps {
            HStack(spacing: 6) {
                Circle().fill(tracker.ready ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(tracker.rough ? "Precise location is off, so this run won't be mapped" : tracker.ready ? "GPS ready" : "Finding GPS…")
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

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: done

    private func doneView(_ r: (seconds: Double, meters: Double, kcal: Double, route: [RoutePoint], health: Bool)) -> some View {
        VStack(spacing: 14) {
            if r.route.count > 1 && r.meters >= 50 {
                RunMap(points: r.route, interactive: false).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                Image(systemName: "figure.run").font(.system(size: 48, weight: .heavy)).foregroundStyle(.green)
                    .frame(width: 110, height: 110).background(Color.green.opacity(0.18), in: Circle()).padding(.top, 30)
            }
            Text("Run saved").font(.title.weight(.heavy))
            HStack(spacing: 0) {
                stat(RunStart.mmss(Int(r.seconds.rounded())), "time")
                if r.meters >= 50 {
                    stat(RouteMath.km(r.meters), "km")
                    stat(RouteMath.pace(r.seconds / r.meters * 1000), "pace /km")
                }
                stat(Fmt.int(r.kcal), "kcal")
            }
            Text(r.health ? "It's in Workouts and Apple Health." : "It's in Workouts.").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button { dismiss() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).buttonBorderShape(.roundedRectangle(radius: 14))
        }
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 18)
    }

    // MARK: the clock

    private func start() {
        started = Date(); now = Date(); spokenKm = 0
        tracker.running = true
        if gps { tracker.start() }
        camera = .userLocation(followsHeading: false, fallback: .automatic)
        Cues.prepare()
        Cues.say("Run started.", run: true)
        Task {
            _ = await workout.start()
            tracker.healthRoute = workout.routeBuilder
        }
    }

    private func pause() {
        pausedAt = Date()
        workout.pause(); tracker.pause()
    }

    private func resume() {
        guard let p = pausedAt else { return }
        pausedFor += Date().timeIntervalSince(p); pausedAt = nil; now = Date()
        workout.resume(); tracker.resume()
    }

    /// A word at each whole kilometre: how far, and the pace so far.
    private func sayKilometres() {
        let k: Int = Int(tracker.meters / 1000)
        guard k > spokenKm, tracker.meters > 0 else { return }
        spokenKm = k
        let pace: String = RouteMath.pace(elapsed / tracker.meters * 1000)
        Cues.say("\(k) kilometre\(k == 1 ? "" : "s"). Average pace \(pace).", run: false)
    }

    private func finish() {
        let t: Double = elapsed
        let route: [RoutePoint] = tracker.points
        tracker.stop()
        let meters: Double = RouteMath.meters(route)
        let kcal: Double = RunStart.freeKcal(seconds: t, meters: meters, kg: store.weightKg)
        let health: Bool = !testing && HealthSync.available
            && HealthSync.health.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        workout.finish(meters: meters, kcal: kcal)
        store.logFreeRun(seconds: t, route: route, kcal: kcal)
        Cues.say("Run saved. Nice work.", run: false)
        withAnimation { result = (t, meters, kcal, route, health) }
    }
}
