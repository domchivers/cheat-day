import Foundation
import HealthKit
import CoreBluetooth

/// Heart rate (26 Nov, design/heart-rate-mockup.html): after the fact from Apple Health, whatever watch put it there,
/// and live from a Bluetooth heart strap. A reading: seconds into the workout, and beats a minute.
struct HRSample: Codable, Equatable {
    let t: Double
    let bpm: Double
}

/// A strap's readings for a workout timed here, on the phone only: Application Support/heart/<workout id>.json.
enum HeartStore {
    private static var folder: URL {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir: URL = base.appendingPathComponent("heart", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func file(_ id: String) -> URL { folder.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json") }
    static func save(_ s: [HRSample], id: String) {
        guard s.count > 1, let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: file(id), options: [.atomic, .completeFileProtection])
    }
    static func load(_ id: String) -> [HRSample]? {
        guard !id.isEmpty, let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode([HRSample].self, from: data)
    }
    static func delete(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }
}

/// The standard Bluetooth Heart Rate Measurement (0x2A37): a flags byte, then the rate as one byte, or two
/// (little-endian) when the flags' lowest bit is set.
enum HeartData {
    static func bpm(from data: Data) -> Int? {
        let b: [UInt8] = [UInt8](data)
        guard let flags = b.first else { return nil }
        if flags & 0x01 == 0 {
            guard b.count >= 2 else { return nil }
            return b[1] > 0 ? Int(b[1]) : nil
        }
        guard b.count >= 3 else { return nil }
        let v: Int = Int(b[1]) | (Int(b[2]) << 8)
        return v > 0 ? v : nil
    }

    /// Average and highest, rounded.
    static func summary(_ s: [HRSample]) -> (avg: Int, max: Int)? {
        guard !s.isEmpty else { return nil }
        let avg: Double = s.reduce(0) { $0 + $1.bpm } / Double(s.count)
        return (Int(avg.rounded()), Int((s.map(\.bpm).max() ?? 0).rounded()))
    }
}

extension HealthSync {
    static var heartAsked: Bool { UserDefaults.standard.bool(forKey: "health.heartAsked") }

    /// Ask to read heart rate and active energy (Health's sheet shows only the first time).
    static func askHeart() async {
        guard available else { return }
        try? await health.requestAuthorization(toShare: [], read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
                                                                  HKObjectType.workoutType(), HKSeriesType.workoutRoute()])
        UserDefaults.standard.set(true, forKey: "health.heartAsked")
        UserDefaults.standard.set(true, forKey: "health.workoutsAsked")
    }

    /// Heart rate readings in a workout's time, as seconds into it.
    static func heartRate(from start: Date, to end: Date) async -> [HRSample] {
        guard available, heartAsked else { return [] }
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let got: [HKQuantitySample] = await withCheckedContinuation { (cont: CheckedContinuation<[HKQuantitySample], Never>) in
            let q = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, s, _ in
                cont.resume(returning: (s as? [HKQuantitySample]) ?? [])
            }
            health.execute(q)
        }
        let unit: HKUnit = .count().unitDivided(by: .minute())
        return got.map { HRSample(t: $0.startDate.timeIntervalSince(start), bpm: $0.quantity.doubleValue(for: unit)) }
    }

    /// Active energy a watch (anything but this app) saved in a workout's time; nil when there's none.
    static func watchKcal(from start: Date, to end: Date) async -> Double? {
        guard available, heartAsked else { return nil }
        let inTime = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let notOurs = NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default()))
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [inTime, notOurs])
        let k: Double? = await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(.activeEnergyBurned), quantitySamplePredicate: pred, options: .cumulativeSum) { _, s, _ in
                cont.resume(returning: s?.sumQuantity()?.doubleValue(for: .kilocalorie()))
            }
            health.execute(q)
        }
        guard let k, k >= 1 else { return nil }
        return k.rounded()
    }
}

/// A Bluetooth heart strap, through the standard Heart Rate service (0x180D): any strap that speaks it. The one they
/// connect is remembered, and found again for the next run. Only "Heart strap connected" is shown, not its name.
@MainActor
final class HeartStrap: NSObject, ObservableObject {
    static let shared = HeartStrap()
    enum State: Equatable { case off, searching, connected, unavailable }

    @Published private(set) var bpm: Int?
    @Published private(set) var state: State = .off
    private var central: CBCentralManager?
    private var strap: CBPeripheral?
    private var wantScan = false
    private static let service = CBUUID(string: "180D")
    private static let measurement = CBUUID(string: "2A37")

    /// One they've connected before.
    static var saved: String? {
        get { UserDefaults.standard.string(forKey: "strap.id") }
        set { UserDefaults.standard.set(newValue, forKey: "strap.id") }
    }

    /// Look for a strap (the first time, iOS asks about Bluetooth here).
    func connect() {
        wantScan = true
        state = .searching
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) } else { begin() }
    }

    /// Back to the one they used before, if there is one (no ask: only once they've connected one).
    func reconnect() {
        guard Self.saved != nil, state == .off else { return }
        connect()
    }

    func forget() {
        if let strap, let central { central.cancelPeripheralConnection(strap) }
        central?.stopScan()
        strap = nil; bpm = nil; state = .off; wantScan = false
        Self.saved = nil
    }

    /// For the screenshot harness: a strap without Bluetooth.
    func fake(bpm: Int) { self.bpm = bpm; state = .connected }

    private func begin() {
        guard let central, central.state == .poweredOn, wantScan else {
            if let central, central.state == .unauthorized || central.state == .unsupported { state = .unavailable }
            return
        }
        // the one from before, if it's about
        if let id = Self.saved.flatMap(UUID.init(uuidString:)), let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            take(p); return
        }
        if let p = central.retrieveConnectedPeripherals(withServices: [Self.service]).first { take(p); return }
        central.scanForPeripherals(withServices: [Self.service])
    }

    private func take(_ p: CBPeripheral) {
        central?.stopScan()
        strap = p
        p.delegate = self
        central?.connect(p)
    }

    fileprivate func got(_ data: Data) {
        if let b = HeartData.bpm(from: data) { bpm = b; state = .connected }
    }
}

extension HeartStrap: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in self.begin() }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        Task { @MainActor in if self.strap == nil { self.take(p) } }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        let id: String = p.identifier.uuidString
        Task { @MainActor in
            HeartStrap.saved = id
            p.discoverServices([HeartStrap.service])
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in self.strap = nil; self.state = .off }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // out of range or switched off: try again when it's back
        Task { @MainActor in
            self.bpm = nil
            guard self.wantScan else { self.state = .off; return }
            self.state = .searching
            c.connect(p)
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == CBUUID(string: "180D") { p.discoverCharacteristics([CBUUID(string: "2A37")], for: s) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == CBUUID(string: "2A37") { p.setNotifyValue(true, for: ch) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        Task { @MainActor in self.got(data) }
    }
}
