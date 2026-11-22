import SwiftUI
import UIKit
import UnifiedCore
import WebKit

/// What the browser shows around the page.
@MainActor
final class BrowserState: ObservableObject {
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var download: String?
    @Published var message: String?
    weak var webView: WKWebView?

    func say(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if message == text { message = nil }
        }
    }
}

/// An in-app browser for one model site. A downloaded printer-ready file goes to the send screen.
struct BrowserView: View {
    let site: ModelSite
    @EnvironmentObject var model: AppModel
    @StateObject var state = BrowserState()

    var body: some View {
        ZStack(alignment: .top) {
            WebPage(site: site, state: state) { job in model.offer(job) }
                .ignoresSafeArea(edges: .bottom)
            if state.progress > 0 && state.progress < 1 {
                ProgressView(value: state.progress).tint(site.brand.color)
            }
            VStack {
                Spacer()
                if let text = state.message ?? state.download.map({ "Downloading \($0)…" }) {
                    Text(text)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85)))
                        .padding(16)
                }
            }
        }
        .navigationTitle(site.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { state.webView?.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!state.canGoBack)
                    .accessibilityLabel("Back")
                Button { state.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload")
            }
        }
    }
}

private struct WebPage: UIViewRepresentable {
    let site: ModelSite
    let state: BrowserState
    let onFile: (PrintJob) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(state: state, onFile: onFile) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Sites treat an embedded web view as second-class; present as the browser it is.
        config.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(web)
        state.webView = web
        web.load(URLRequest(url: site.url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        coordinator.observations.removeAll()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let state: BrowserState
        let onFile: (PrintJob) -> Void
        var observations: [NSKeyValueObservation] = []
        private var targets: [ObjectIdentifier: (url: URL, name: String)] = [:]

        init(state: BrowserState, onFile: @escaping (PrintJob) -> Void) {
            self.state = state
            self.onFile = onFile
        }

        func observe(_ web: WKWebView) {
            observations = [
                web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                    let p = w.estimatedProgress
                    Task { @MainActor in self?.state.progress = p }
                },
                web.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in
                    let b = w.canGoBack
                    Task { @MainActor in self?.state.canGoBack = b }
                },
            ]
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
                return
            }
            guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
                decisionHandler(.allow, preferences)
                return
            }
            if ["http", "https", "about", "blob", "data"].contains(scheme) {
                decisionHandler(.allow, preferences)
                return
            }
            // App links (e.g. "Open in Bambu Handy") go to the app that owns them.
            decisionHandler(.cancel, preferences)
            let state = self.state
            UIApplication.shared.open(url) { opened in
                if !opened { Task { @MainActor in state.say("No app on this phone opens that link.") } }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let attachment = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
            let name = navigationResponse.response.suggestedFilename ?? ""
            if attachment || (navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType) || PrintFiles.isPrinterReady(name) {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        /// Links that open a new window load here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        // MARK: Downloads (also blob: links, which only the page itself can read)

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let name = PrintFiles.safeName(suggestedFilename)
            let target = PrintFiles.newFile(name)
            targets[ObjectIdentifier(download)] = (target, name)
            state.download = name
            completionHandler(target)
        }

        func downloadDidFinish(_ download: WKDownload) {
            state.download = nil
            guard let t = targets.removeValue(forKey: ObjectIdentifier(download)) else { return }
            if PrintFiles.isPrinterReady(t.name) {
                onFile(PrintJob(file: t.url, name: t.url.lastPathComponent))
            } else {
                try? FileManager.default.removeItem(at: t.url)
                state.say("\(t.name) is a model, not a sliced file. Slice it in Unified Slicer on your computer, or pick a print profile here.")
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            state.download = nil
            if let t = targets.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: t.url) }
            state.say("Download failed: \(error.localizedDescription)")
        }
    }
}
