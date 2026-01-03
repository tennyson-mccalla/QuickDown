import Cocoa
import Quartz
import WebKit

class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView!

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        self.view = view

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let markdownContent = try String(contentsOf: url, encoding: .utf8)
            let html = generateHTML(markdown: markdownContent)
            webView.loadHTMLString(html, baseURL: nil)
            handler(nil)
        } catch {
            handler(error)
        }
    }

    private func loadResource(_ name: String, ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return content
    }

    private func generateHTML(markdown: String) -> String {
        let escapedMarkdown = escapeForJavaScript(markdown)

        let markedJS = loadResource("marked.min", ext: "js")
        let highlightJS = loadResource("highlight.min", ext: "js")
        let stylesCSS = loadResource("styles", ext: "css")
        let githubCSS = loadResource("github.min", ext: "css")
        let githubDarkCSS = loadResource("github-dark.min", ext: "css")

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>\(stylesCSS)</style>
            <style media="(prefers-color-scheme: light)">\(githubCSS)</style>
            <style media="(prefers-color-scheme: dark)">\(githubDarkCSS)</style>
            <script>\(markedJS)</script>
            <script>\(highlightJS)</script>
        </head>
        <body>
            <div id="content"></div>
            <script>
                marked.setOptions({
                    highlight: function(code, lang) {
                        if (lang && hljs.getLanguage(lang)) {
                            try {
                                return hljs.highlight(code, { language: lang }).value;
                            } catch (e) {}
                        }
                        return hljs.highlightAuto(code).value;
                    },
                    gfm: true,
                    breaks: false
                });

                const markdown = `\(escapedMarkdown)`;
                document.getElementById('content').innerHTML = marked.parse(markdown);
            </script>
        </body>
        </html>
        """
    }

    private func escapeForJavaScript(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "`", with: "\\`")
        result = result.replacingOccurrences(of: "$", with: "\\$")
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        return result
    }
}
