import SwiftUI
import WebKit

/// The web app, full screen, with a message channel ("native") the page uses for the timer and haptics.
struct WebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> NativeBridge { NativeBridge() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true                 // the barcode camera plays inline
        config.mediaTypesRequiringUserActionForPlayback = []
        config.limitsNavigationsToAppBoundDomains = true        // pairs with WKAppBoundDomains: keeps the offline cache working

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "native")
        // lets the page know it's inside the app (and which version), before any of its scripts run
        let marker = "window.cheatDaysNative = { platform: 'ios', version: '\(Bundle.main.shortVersion)' };"
        controller.addUserScript(WKUserScript(source: marker, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        let ground = UIColor(named: "LaunchBackground") ?? .black
        webView.isOpaque = false
        webView.backgroundColor = ground
        webView.scrollView.backgroundColor = ground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if #available(iOS 16.4, *) { webView.isInspectable = true }   // Safari on the Mac can debug TestFlight builds

        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
