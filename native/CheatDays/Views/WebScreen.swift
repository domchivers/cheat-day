import SwiftUI
import WebKit

extension Notification.Name {
    /// The web page finished what it was opened for (food added, or it went back from its first screen).
    static let webDone = Notification.Name("cheatDaysWebDone")
}

/// A screen that is still the web app (Workouts, Friends, the pages under Me, scanning). One web view is
/// shared and moves to whichever of these is on screen, then shows the right page.
struct WebScreen: View {
    let view: String
    var opts: JSON = [:]
    var pushed = false

    var body: some View {
        WebSlotView(view: view, opts: opts, pushed: pushed)
            .background(Theme.bg.ignoresSafeArea())
    }
}

private struct WebSlotView: UIViewRepresentable {
    let view: String
    let opts: JSON
    let pushed: Bool

    func makeUIView(context: Context) -> WebSlot {
        let slot = WebSlot()
        slot.viewName = view; slot.opts = opts; slot.pushed = pushed
        slot.backgroundColor = Theme.uiBackground
        return slot
    }
    func updateUIView(_ slot: WebSlot, context: Context) {}
}

final class WebSlot: UIView {
    var viewName = ""
    var opts: JSON = [:]
    var pushed = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { Task { @MainActor in WebHost.shared.attach(to: self) } }
    }
}

/// A web screen in a sheet, for the add flows that aren't native yet.
struct WebFlowSheet: View {
    let flow: WebFlow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            WebScreen(view: flow.view, opts: flow.opts)
                .navigationTitle(flow.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onDisappear { Task { try? await Task.sleep(nanoseconds: 1_200_000_000); await Store.shared.sync() } }
    }
}

@MainActor
final class WebHost {
    static let shared = WebHost()
    let bridge = NativeBridge()
    private var web: WKWebView?
    private var loaded = false
    private weak var slot: WebSlot?

    var webView: WKWebView {
        if let web { return web }
        let w = make(); web = w; return w
    }

    func attach(to slot: WebSlot) {
        self.slot = slot
        let w = webView
        if w.superview !== slot {
            w.removeFromSuperview()
            w.frame = slot.bounds
            w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            slot.addSubview(w)
        }
        if loaded { showCurrent() }
    }

    func didLoad() { loaded = true; showCurrent() }

    private func showCurrent() {
        guard let slot else { return }
        var o = slot.opts
        if slot.pushed { o["pushed"] = true }
        let js = "if (window.nativeShow) window.nativeShow(\(Self.js(slot.viewName)), \(Self.js(o))); if (window.pull) window.pull();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Forget this account in the web part too, so the next person to sign in starts clean.
    func signOut() {
        web?.evaluateJavaScript("try { localStorage.clear(); } catch (e) {}", completionHandler: nil)
        web?.removeFromSuperview()
        web = nil
        loaded = false
    }

    private func make() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.limitsNavigationsToAppBoundDomains = true

        let controller = WKUserContentController()
        controller.add(bridge, name: "native")
        var src = "window.cheatDaysNative = { platform: 'ios', version: '\(Bundle.main.shortVersion)', tabs: true };"
        // the web part signs in with its own session, made when you signed in to the app
        if let d = Keychain.load("webSession"), let s = String(data: d, encoding: .utf8) {
            src += " try { if (!localStorage.getItem('cheatday.session.v1')) localStorage.setItem('cheatday.session.v1', \(Self.js(s))); } catch (e) {}"
        }
        controller.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller

        let w = WKWebView(frame: .zero, configuration: config)
        w.isOpaque = false
        w.backgroundColor = Theme.uiBackground
        w.scrollView.backgroundColor = Theme.uiBackground
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.allowsBackForwardNavigationGestures = false
        w.navigationDelegate = bridge
        w.uiDelegate = bridge
        if #available(iOS 16.4, *) { w.isInspectable = true }
        bridge.webView = w
        w.load(URLRequest(url: AppConfig.startURL))
        return w
    }

    /// A value written as JavaScript (via JSON).
    static func js(_ value: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [value]), var s = String(data: d, encoding: .utf8) else { return "null" }
        s.removeFirst(); s.removeLast()
        return s
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
