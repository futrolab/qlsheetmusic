import Cocoa
import QuickLookUI
import WebKit

final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private var webView: WKWebView!
    private var pendingBase64XML: String?
    private var pendingCompletion: ((Error?) -> Void)?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 760), configuration: config)
        wv.navigationDelegate = self
        wv.autoresizingMask = [.width, .height]

        self.webView = wv
        self.preferredContentSize = NSSize(width: 900, height: 760)
        self.view = wv
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let xmlString = try Self.loadMusicXMLString(from: url)
                let base64 = Data(xmlString.utf8).base64EncodedString()

                DispatchQueue.main.async {
                    guard let self else {
                        handler(nil)
                        return
                    }
                    self.render(base64XML: base64, completion: handler)
                }
            } catch {
                DispatchQueue.main.async {
                    handler(error)
                }
            }
        }
    }

    // MARK: - File Loading

    private static func loadMusicXMLString(from url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ext = url.pathExtension.lowercased()
        if ext == "mxl" {
            let archive = try MXLArchive(url: url)
            return try archive.extractRootMusicXML()
        }

        let rawData = try Data(contentsOf: url, options: .mappedIfSafe)
        return try MXLArchive.decodeXMLString(from: rawData)
    }

    // MARK: - WebView Rendering

    private func render(base64XML: String, completion: @escaping (Error?) -> Void) {
        if let stale = pendingCompletion {
            pendingCompletion = nil
            stale(nil)
        }

        let bundle = Bundle(for: PreviewViewController.self)
        let htmlURL = bundle.url(forResource: "index", withExtension: "html")
            ?? bundle.url(forResource: "index", withExtension: "html", subdirectory: "Resources")

        guard let htmlURL else {
            completion(NSError(
                domain: "MusicXMLPreviewExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing index.html in extension resources."]
            ))
            return
        }

        pendingBase64XML = base64XML
        pendingCompletion = completion
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let base64 = pendingBase64XML {
            pendingBase64XML = nil
            webView.evaluateJavaScript("window.renderMusicXMLBase64('\(base64)');", completionHandler: nil)
        }
        pendingCompletion?(nil)
        pendingCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingBase64XML = nil
        pendingCompletion?(error)
        pendingCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pendingBase64XML = nil
        pendingCompletion?(error)
        pendingCompletion = nil
    }
}
