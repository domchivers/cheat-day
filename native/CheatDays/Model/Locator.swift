import CoreLocation

/// The suburb they're in, for "places near me": approximate location (Precise off), asked for the first time they ask
/// for places without saying where, turned into a suburb's name by Apple's lookup. Only that name goes in the search.
@MainActor final class Locator: NSObject, CLLocationManagerDelegate {
    static let shared = Locator()
    private let manager = CLLocationManager()
    private var asked: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Said no, or location's off for the app: nothing to ask, so "near me" goes straight to the last area or "Whereabouts?".
    var refused: Bool { [.denied, .restricted].contains(manager.authorizationStatus) }

    /// "South Yarra", or nil when they said no, location is off, or it takes more than 8 seconds.
    func suburb() async -> String? {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { c in asked = c; manager.requestWhenInUseAuthorization() }
        }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return nil }
        let here: CLLocation? = await withCheckedContinuation { c in
            waiting.append(c)
            if waiting.count == 1 { manager.requestLocation() }
            Task { try? await Task.sleep(for: .seconds(8)); self.answer(nil) }
        }
        guard let here, let p = try? await CLGeocoder().reverseGeocodeLocation(here).first else { return nil }
        return p.subLocality ?? p.locality
    }

    private func answer(_ l: CLLocation?) {
        let w = waiting; waiting = []
        for c in w { c.resume(returning: l) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in if s != .notDetermined, let c = self.asked { self.asked = nil; c.resume() } }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations ls: [CLLocation]) {
        let l = ls.last
        Task { @MainActor in self.answer(l) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.answer(nil) }
    }
}
