import Cocoa
import QuickLookUI
import WebKit

final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private enum PreviewPayload {
        case musicXML(base64: String)
        case pngThumbnail(base64: String)
        case fallbackMessage(titleBase64: String, detailBase64: String)
    }

    private var webView: WKWebView!
    private var pendingPayload: PreviewPayload?
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
                let payload = try Self.loadPreviewPayload(from: url)

                DispatchQueue.main.async {
                    guard let self else {
                        handler(nil)
                        return
                    }
                    self.render(payload: payload, completion: handler)
                }
            } catch {
                DispatchQueue.main.async {
                    handler(error)
                }
            }
        }
    }

    // MARK: - File Loading

    private static func loadPreviewPayload(from url: URL) throws -> PreviewPayload {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mscz":
            let archive = try MXLArchive(url: url)
            if let pngData = try archive.extractMuseScoreThumbnail(), !pngData.isEmpty {
                return .pngThumbnail(base64: pngData.base64EncodedString())
            }
            let title = "No Preview Thumbnail Embedded"
            let detail = "This .mscz archive was saved without Thumbnails/thumbnail.png. Re-save the score in MuseScore with thumbnail export enabled, or export as .musicxml / .mxl for full notation rendering."
            return .fallbackMessage(
                titleBase64: Data(title.utf8).base64EncodedString(),
                detailBase64: Data(detail.utf8).base64EncodedString()
            )

        case "mxl":
            let archive = try MXLArchive(url: url)
            let xmlString = try archive.extractRootMusicXML()
            return .musicXML(base64: Data(xmlString.utf8).base64EncodedString())

        default:
            let rawData = try Data(contentsOf: url, options: .mappedIfSafe)
            let xmlString = try MXLArchive.decodeXMLString(from: rawData)
            return .musicXML(base64: Data(xmlString.utf8).base64EncodedString())
        }
    }

    // MARK: - WebView Rendering

    private func render(payload: PreviewPayload, completion: @escaping (Error?) -> Void) {
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

        pendingPayload = payload
        pendingCompletion = completion
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let payload = pendingPayload {
            pendingPayload = nil
            switch payload {
            case .musicXML(let base64):
                webView.evaluateJavaScript("window.renderMusicXMLBase64('\(base64)');", completionHandler: nil)
            case .pngThumbnail(let base64):
                webView.evaluateJavaScript("window.renderThumbnailBase64('\(base64)');", completionHandler: nil)
            case .fallbackMessage(let titleBase64, let detailBase64):
                webView.evaluateJavaScript("window.renderMessageBase64('\(titleBase64)', '\(detailBase64)');", completionHandler: nil)
            }
        }
        pendingCompletion?(nil)
        pendingCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingPayload = nil
        pendingCompletion?(error)
        pendingCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pendingPayload = nil
        pendingCompletion?(error)
        pendingCompletion = nil
    }
}
