import Foundation
import JavaScriptCore
import Testing
@testable import BentoTerminalCore

/// The web preview is only as good as its bundled assets — these tests load
/// the vendored highlight.js / markdown-it plus our preview.js into a bare
/// JSContext (no WebView) and exercise the render pipeline offline.
@Suite struct FilePreviewWebAssetsTests {
    private func resourceURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil,
                          subdirectory: "PathPreview")
    }

    @Test func bundledAssetsPresent() {
        for name in ["preview.html", "preview.css", "preview.js",
                     "highlight.min.js", "markdown-it.min.js",
                     "hljs-github.min.css", "hljs-github-dark.min.css",
                     "LICENSES.txt"] {
            #expect(resourceURL(name) != nil, "missing \(name)")
        }
    }

    private func pipelineContext() throws -> JSContext {
        let ctx = try #require(JSContext())
        var jsError: String?
        ctx.exceptionHandler = { _, exc in jsError = exc?.toString() }
        ctx.evaluateScript("var window = this;")
        for file in ["highlight.min.js", "markdown-it.min.js", "preview.js"] {
            let url = try #require(resourceURL(file))
            ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            #expect(jsError == nil, "\(file): \(jsError ?? "")")
        }
        return ctx
    }

    @Test func swiftCodeHighlights() throws {
        let ctx = try pipelineContext()
        ctx.setObject("let x = 42 // note", forKeyedSubscript: "src" as NSString)
        let html = ctx.evaluateScript("highlightedCode('main.swift', src)")?.toString() ?? ""
        #expect(html.contains("hljs-keyword"))
        #expect(html.contains("hljs-comment"))
    }

    @Test func markdownRenders() throws {
        let ctx = try pipelineContext()
        ctx.setObject("# Title\n\n- item\n\n```swift\nlet a = 1\n```\n![alt](http://x/y.png)",
                      forKeyedSubscript: "src" as NSString)
        let html = ctx.evaluateScript("md.render(src)")?.toString() ?? ""
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<li>item</li>"))
        #expect(html.contains("hljs-keyword"))          // fenced code highlighted
        #expect(html.contains("img-stub"))              // images stubbed, not loaded
        #expect(!html.contains("<img"))
    }

    @Test func rawHTMLStaysInert() throws {
        let ctx = try pipelineContext()
        ctx.setObject("hello <script>alert(1)</script>", forKeyedSubscript: "src" as NSString)
        let html = ctx.evaluateScript("md.render(src)")?.toString() ?? ""
        #expect(!html.contains("<script>"))
        let code = ctx.evaluateScript("highlightedCode('x.txt', src)")?.toString() ?? ""
        #expect(!code.contains("<script>"))
    }

    @Test func hugeFileFallsBackToPlainText() throws {
        let ctx = try pipelineContext()
        ctx.evaluateScript("var big = 'x = 1;\\n'.repeat(40000);")   // ~280 KB
        let html = ctx.evaluateScript("highlightedCode('big.js', big)")?.toString() ?? ""
        #expect(!html.contains("hljs-"))
    }
}
