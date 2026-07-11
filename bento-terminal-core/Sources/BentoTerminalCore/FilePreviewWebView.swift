import Foundation
import WebKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Shared web renderer for the `.text` case of file previews: syntax
/// highlighting (highlight.js) for code, rendered GitHub-flavored Markdown
/// (markdown-it) for .md, with a line gutter and `path:42`-style jump.
/// One implementation for the macOS panel and the iOS sheet — the template
/// and vendored JS live in this package's resources.
///
/// Isolation: the page is a local template loaded once via `loadFileURL`;
/// content goes in as a JSON payload through `evaluateJavaScript`, never as
/// interpolated HTML. The navigation delegate cancels everything except the
/// initial template load — link taps open in the system browser, and the
/// page has no way to reach the network (markdown images render as stubs).
@MainActor
public final class FilePreviewWebView: WKWebView, WKNavigationDelegate {

    private struct Payload: Encodable {
        let name: String
        let text: String
        let line: Int?
        let dark: Bool
    }

    private var templateReady = false
    private var pending: Payload?

    public static func makePreview() -> FilePreviewWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let v = FilePreviewWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = v
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        v.allowsMagnification = true
        #endif
        if let html = Bundle.module.url(forResource: "preview", withExtension: "html",
                                        subdirectory: "PathPreview") {
            v.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return v
    }

    /// Render `text` as `fileName`'s content. Safe to call before the
    /// template finished loading — the last payload wins once it's up.
    public func render(fileName: String, text: String, line: Int?, dark: Bool) {
        let payload = Payload(name: fileName, text: text, line: line, dark: dark)
        guard templateReady else { pending = payload; return }
        guard let data = try? JSONEncoder().encode(payload),
              var json = String(data: data, encoding: .utf8) else { return }
        // U+2028/2029 are valid JSON but not valid JS string literals.
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        evaluateJavaScript("bentoRender(\(json))")
    }

    /// Follow an appearance change without re-rendering.
    public func setDark(_ dark: Bool) {
        guard templateReady else {
            if let p = pending {
                pending = Payload(name: p.name, text: p.text, line: p.line, dark: dark)
            }
            return
        }
        evaluateJavaScript("bentoSetTheme(\(dark))")
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        templateReady = true
        if let p = pending {
            pending = nil
            render(fileName: p.name, text: p.text, line: p.line, dark: p.dark)
        }
    }

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Initial template load (and only that) is a local file navigation.
        if navigationAction.navigationType == .other,
           navigationAction.request.url?.isFileURL == true, !templateReady {
            decisionHandler(.allow)
            return
        }
        // A tapped link opens outside; nothing else navigates, ever.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            GhosttyRuntime.openExternalURL(url.absoluteString)
        }
        decisionHandler(.cancel)
    }
}
