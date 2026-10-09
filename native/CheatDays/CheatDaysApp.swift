import SwiftUI

/// Where the web app lives. Loading it from GitHub Pages means every web change reaches the app
/// straight away; only native changes (the timer, haptics) need a new TestFlight build.
enum AppConfig {
    static let host = "domchivers.github.io"
    static let startURL = URL(string: "https://domchivers.github.io/cheat-day/?app=ios")!
}

@main
struct CheatDaysApp: App {
    var body: some Scene {
        WindowGroup {
            WebView(url: AppConfig.startURL)
                .ignoresSafeArea()   // the page handles the notch and home bar itself (viewport-fit=cover)
                .background(Color("LaunchBackground"))
                .preferredColorScheme(.dark)
        }
    }
}
