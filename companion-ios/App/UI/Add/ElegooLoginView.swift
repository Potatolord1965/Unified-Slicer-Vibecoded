import SwiftUI
import UIKit
import UnifiedCore
import WebKit

/// One stable id per installation: Elegoo binds the tokens its sign-in page issues to it.
private var elegooDeviceId: String {
    let defaults = UserDefaults.standard
    if let id = defaults.string(forKey: "elegoo_device_id") { return id }
    let id = UUID().uuidString.lowercased()
    defaults.set(id, forKey: "elegoo_device_id")
    return id
}

/// The page posts JSON requests the way ElegooSlicer's pages do (window.chrome.webview.postMessage
/// under WebView2, the wx handler under WebKit) and reads replies through window.HandleStudio.
private let bridgeShim = """
(function () {
  if (window.__unifiedBridge) return;
  window.__unifiedBridge = true;
  var post = function (m) { window.webkit.messageHandlers.wx.postMessage(typeof m === 'string' ? m : JSON.stringify(m)); };
  window.chrome = window.chrome || {};
  window.chrome.webview = window.chrome.webview || { postMessage: post, addEventListener: function () {}, removeEventListener: function () {} };
  window.wx = window.wx || { postMessage: post };
})();
"""

/// Elegoo's own sign-in page; it hands the app an account once the person has signed in.
struct ElegooLoginView: View {
    let replaceId: String?
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) var scheme
    @State var error: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            ElegooPage(dark: scheme == .dark, replaceId: replaceId, onDone: { model.saveAccount(.elegoo($0)) }, onError: { error = $0 })
                .ignoresSafeArea(edges: .bottom)
            if let error {
                Text(error).font(.subheadline).foregroundColor(Studio.bad).padding(16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Studio.panel))
                    .padding(16)
            }
        }
        .navigationTitle("Elegoo")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ElegooPage: UIViewRepresentable {
    let dark: Bool
    let replaceId: String?
    let onDone: (ElegooAccount) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(WeakHandler(context.coordinator), name: "wx")
        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = ElegooCloudSource.loginUserAgent
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        context.coordinator.load()
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "wx")
        uiView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let page: ElegooPage
        weak var webView: WKWebView?
        private var done = false

        init(_ page: ElegooPage) { self.page = page }

        func load() {
            guard let url = URL(string: ElegooCloudSource.loginURL(deviceId: elegooDeviceId, dark: page.dark)) else { return }
            webView?.load(URLRequest(url: url))
        }

        private func run(_ message: JSON) {
            webView?.evaluateJavaScript("window.HandleStudio && window.HandleStudio(\(message.serialized))", completionHandler: nil)
        }

        private func reply(_ id: String, _ method: String, ok: Bool, _ message: String = "") {
            run(.object([
                "id": .string(id), "method": .string(method), "type": "response",
                "code": .integer(ok ? 0 : -1), "message": .string(ok ? "success" : message), "data": .object([:]),
            ]))
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only Elegoo's own pages may sign the app in.
            guard message.frameInfo.isMainFrame, ElegooCloudSource.isElegooPage(webView?.url?.absoluteString) else { return }
            let raw: String
            if let s = message.body as? String {
                raw = s
            } else if JSONSerialization.isValidJSONObject(message.body), let d = try? JSONSerialization.data(withJSONObject: message.body) {
                raw = String(decoding: d, as: UTF8.self)
            } else {
                return
            }
            guard let msg = JSON.parse(raw), (msg.str("type") ?? "request") == "request" else { return }
            let method = msg.str("method") ?? ""
            let id = msg.str("id") ?? ""
            switch method {
            case "report.userInfo":
                let account = ElegooCloudSource.accountFromLogin(msg.el("params"), id: page.replaceId ?? "elegoo-" + UUID().uuidString.lowercased())
                reply(id, method, ok: account != nil, "No account was returned")
                if let account {
                    if !done {
                        done = true
                        page.onDone(account)
                    }
                } else {
                    page.onError("The Elegoo sign-in page did not return an account.")
                }
            case "report.ready":
                reply(id, method, ok: true)
                run(.object(["method": "client.setDeviceId", "type": "event", "data": .object(["deviceId": .string(elegooDeviceId)])]))
            case "report.websiteOpen":
                reply(id, method, ok: true)
                if let s = msg.el("params").str("url"), s.hasPrefix("https://"), let url = URL(string: s) {
                    UIApplication.shared.open(url)
                }
            case "reload":
                reply(id, method, ok: true)
                load()
            default:
                reply(id, method, ok: true)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            // Links to other sites (terms, help) open in the browser.
            let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            guard mainFrame, let url = navigationAction.request.url, !ElegooCloudSource.isElegooPage(url.absoluteString),
                  url.scheme != "about" else {
                decisionHandler(.allow, preferences)
                return
            }
            decisionHandler(.cancel, preferences)
            UIApplication.shared.open(url)
        }
    }
}

/// WKUserContentController keeps its handlers strongly; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
