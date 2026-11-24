import SwiftUI
import Charts

/// Their maximum heart rate for the zones: their own, or 220 minus their age.
enum HeartMax {
    static var own: Int {
        get { UserDefaults.standard.integer(forKey: "hr.max") }
        set { UserDefaults.standard.set(newValue, forKey: "hr.max") }
    }
    @MainActor static var fromAge: Int { HeartZones.max(age: pos(dict(Store.shared.doc["profile"])["age"]) ?? 35) }
    @MainActor static var value: Int { own > 0 ? own : fromAge }
}

/// ♥ 152 bpm, live from the strap; on a run, a word on whether it's easy.
struct LiveHeart: View {
    let bpm: Int
    let onRun: Bool

    var body: some View {
        let max: Int = HeartMax.value
        let z: Int = HeartZones.zone(bpm: Double(bpm), max: max)
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill").font(.title2).foregroundStyle(Color.pink)
                Text("\(bpm)").font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(Color.pink)
                    .contentTransition(.numericText())
                Text("bpm").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Heart rate \(bpm)")
            if onRun {
                Text(HeartZones.runLine(bpm: Double(bpm), max: max)).font(.footnote.weight(.bold))
                    .foregroundStyle(z >= 3 ? Color.pink : Color.green)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background((z >= 3 ? Color.pink : Color.green).opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

/// The strap's on: no brand, just that it's there.
struct StrapLine: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text("Heart strap connected").font(.footnote.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A workout's heart rate afterwards: from the strap when one was on, or Apple Health for its time (any watch).
/// Average and highest, the line, and time in each zone.
struct HeartPanel: View {
    let workout: JSON
    @State private var samples: [HRSample]
    @State private var source: String

    /// A strap's readings are on the phone, so they're there from the start; Health's are read once it shows.
    init(workout: JSON) {
        self.workout = workout
        let mine: [HRSample] = HeartStore.load(str(workout["id"])) ?? []
        _samples = State(initialValue: mine.count > 1 ? mine : [])
        _source = State(initialValue: mine.count > 1 ? "from your heart strap" : "")
    }

    var body: some View {
        // (not EmptyView while it reads: an empty view never appears, so its task never ran; 1.4.57's UI test)
        Group {
            if samples.count > 1 { content } else { Color.clear.frame(height: 1) }
        }
        .task { await load() }
    }

    private func load() async {
        guard samples.count < 2 else { return }
        guard let win = Overlap.window(workout) else { return }
        let h: [HRSample] = await HealthSync.heartRate(from: win.start, to: win.end)
        if h.count > 1 { samples = h; source = workout["watch"] != nil || str(workout["from"]) == "health" ? "from your watch" : "from Apple Health" }
    }

    private var content: some View {
        let s: (avg: Int, max: Int) = HeartData.summary(samples) ?? (0, 0)
        let max: Int = HeartMax.value
        let zones: [Double] = HeartZones.seconds(samples, max: max)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Heart rate", systemImage: "heart.fill").font(.headline)
                Spacer()
                Text(source).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 22) {
                number(s.avg, "average")
                number(s.max, "max")
            }
            Chart {
                ForEach(samples.indices, id: \.self) { i in
                    AreaMark(x: .value("Minute", samples[i].t / 60), y: .value("bpm", samples[i].bpm))
                        .foregroundStyle(Color.pink.opacity(0.18))
                    LineMark(x: .value("Minute", samples[i].t / 60), y: .value("bpm", samples[i].bpm))
                        .foregroundStyle(Color.pink).lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .frame(height: 110)
            zoneBar(zones)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func number(_ v: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(v)").font(.title.weight(.heavy)).monospacedDigit().foregroundStyle(Color.pink)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    static let zoneColours: [Color] = [Color.gray, Color.green, Color.yellow, Color.orange, Color.red]

    /// The five zones as one bar, each as long as the time in it, named underneath.
    private func zoneBar(_ z: [Double]) -> some View {
        let total: Double = max(1, z.reduce(0, +))
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { (i: Int) in
                        if z[i] > 0 {
                            Rectangle().fill(Self.zoneColours[i]).frame(width: max(2, (g.size.width - 8) * CGFloat(z[i] / total)))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            Text((0..<5).filter { z[$0] >= 30 }.map { "\(HeartZones.names[$0]) \(Int((z[$0] / 60).rounded()))m" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// When a watch's calories replaced the app's guess, it says so.
struct WatchKcalNote: View {
    let workout: JSON
    var body: some View {
        if str(workout["kcalFrom"]) == "watch" {
            let k: String = Fmt.int(num(workout["kcal"]) ?? 0)
            let guess: Double? = num(workout["kcalGuess"])
            Label(guess.map { "Calories are your watch's: \(k), not the \(Fmt.int($0)) guessed here." } ?? "Calories are your watch's: \(k).",
                  systemImage: "applewatch")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Settings for heart rate (26 Nov, design/heart-rate-mockup.html): reading it from Apple Health, a heart strap,
/// and their zones.
struct HeartSettingsView: View {
    @ObservedObject private var strap = HeartStrap.shared
    @State private var asked: Bool = HealthSync.heartAsked
    @State private var own: Int = HeartMax.own

    var body: some View {
        List {
            Section {
                row("Read from Apple Health", "Any watch that saves to Health: heart rate and calories for each workout") {
                    if asked { Text("On").foregroundStyle(.green).font(.body.weight(.semibold)) }
                    else { Button("Turn on") { Task { await HealthSync.askHeart(); asked = HealthSync.heartAsked } }.buttonStyle(.borderless) }
                }
                row("Heart strap", strapLine) { strapButton }
            } footer: {
                Text("A strap that uses Bluetooth's standard heart rate shows it live while you run, ride or time a workout.")
            }
            Section {
                Stepper(value: Binding(get: { own > 0 ? own : HeartMax.fromAge }, set: { own = $0; HeartMax.own = $0 }), in: 120...220) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max heart rate: \(own > 0 ? own : HeartMax.fromAge)").font(.body.weight(.semibold))
                        Text(own > 0 ? "Your own" : "From your age: max about \(HeartMax.fromAge)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if own > 0 { Button("Go back to from my age") { own = 0; HeartMax.own = 0 } }
                ForEach(0..<5, id: \.self) { (i: Int) in
                    HStack {
                        Circle().fill(HeartPanel.zoneColours[i]).frame(width: 10, height: 10)
                        Text(HeartZones.names[i])
                        Spacer()
                        Text(range(i)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } header: { Text("Your zones") }
        }
        .navigationTitle("Heart rate")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var strapLine: String {
        switch strap.state {
        case .connected: "Heart strap connected"
        case .searching: "Looking for your strap… wear it so it wakes up"
        case .unavailable: "Bluetooth is off, or not allowed for Cheat Days"
        case .off: "Bluetooth, live on the run screen"
        }
    }

    @ViewBuilder private var strapButton: some View {
        switch strap.state {
        case .connected: Button("Forget", role: .destructive) { strap.forget() }.buttonStyle(.borderless)
        case .searching: Button("Stop") { strap.forget() }.buttonStyle(.borderless)
        case .off, .unavailable: Button("Connect") { strap.connect() }.buttonStyle(.borderless)
        }
    }

    private func range(_ i: Int) -> String {
        let m: Double = Double(own > 0 ? own : HeartMax.fromAge)
        let lows: [Double] = [0, 0.6, 0.7, 0.8, 0.9]
        if i == 0 { return "under \(Int((m * 0.6).rounded()))" }
        if i == 4 { return "\(Int((m * 0.9).rounded())) and up" }
        return "\(Int((m * lows[i]).rounded()))–\(Int((m * lows[i + 1]).rounded()) - 1)"
    }

    private func row<T: View>(_ title: String, _ sub: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(sub).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

// MARK: screenshot harnesses (26 Nov)

/// A made-up ride: about 8.4 km north-east and gently up, 24 minutes, for the ride screens.
enum RideHarness {
    static let id = "uitest-ride"
    static var route: [RoutePoint] {
        (0..<300).map { (i: Int) -> RoutePoint in
            let f: Double = Double(i) / 299
            return RoutePoint(lat: -37.86 + f * 0.05 + 0.004 * sin(f * 6), lon: 144.95 + f * 0.065, t: Double(i) * 4.85, run: true,
                              alt: 20 + f * 64 + 1.5 * sin(Double(i)))
        }
    }
    /// 24 minutes of readings, every 5 s: up to the 160s with a hard middle.
    static var heart: [HRSample] {
        (0..<290).map { (i: Int) -> HRSample in
            let f: Double = Double(i) / 289
            return HRSample(t: Double(i) * 5, bpm: (112 + 50 * sin(f * .pi) + 6 * sin(Double(i) / 4)).rounded())
        }
    }
}

/// A finished ride's page, with its heart rate from a strap.
struct RideDoneHarness: View {
    init() {
        RouteStore.save(RideHarness.route, id: RideHarness.id)
        HeartStore.save(RideHarness.heart, id: RideHarness.id)
    }
    var body: some View {
        NavigationStack {
            WorkoutDetail(workout: ["id": RideHarness.id, "type": "Cycle", "name": "Ride", "minutes": 24, "kcal": 412, "kcalGuess": 380,
                                    "kcalFrom": "watch", "lifts": [Any](), "km": (RouteMath.meters(RideHarness.route) / 10).rounded() / 100, "climb": 64, "tracked": true], date: "2026-11-26")
        }
    }
}

/// The run screen with a strap on.
struct RunHeartHarness: View {
    init() { HeartStrap.shared.fake(bpm: 152) }
    var body: some View {
        MoveView(kind: .run, preview: (route: Array(RunMapHarness.sample.prefix(272)), seconds: 1361, paused: false))
    }
}
