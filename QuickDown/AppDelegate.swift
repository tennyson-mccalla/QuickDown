import Cocoa
import WebKit

enum Theme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case sepia = "Sepia"
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    var window: NSWindow!
    var webView: WKWebView!
    var dropZoneLabel: NSTextField!
    var currentFileURL: URL?

    private let themeKey = "SelectedTheme"
    private var currentTheme: Theme {
        get {
            if let value = UserDefaults.standard.string(forKey: themeKey),
               let theme = Theme(rawValue: value) {
                return theme
            }
            return .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // MARK: - Window Setup

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickDown"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(width: 400, height: 300)

        // Create drop view as content
        let dropView = DropView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        dropView.autoresizingMask = [.width, .height]
        dropView.onFileDrop = { [weak self] url in
            self?.openFile(url)
        }
        dropView.onClick = { [weak self] in
            self?.openDocument(nil)
        }

        // Create WKWebView with drag support
        let config = WKWebViewConfiguration()
        let customWebView = DroppableWebView(frame: dropView.bounds, configuration: config)
        customWebView.autoresizingMask = [.width, .height]
        customWebView.isHidden = true
        customWebView.onFileDrop = { [weak self] url in
            self?.openFile(url)
        }
        webView = customWebView
        dropView.addSubview(webView)


        // Create drop zone label
        dropZoneLabel = NSTextField(labelWithString: "Drop a Markdown file here\nor use File → Open")
        dropZoneLabel.alignment = .center
        dropZoneLabel.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        dropZoneLabel.textColor = .secondaryLabelColor
        dropZoneLabel.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(dropZoneLabel)

        NSLayoutConstraint.activate([
            dropZoneLabel.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            dropZoneLabel.centerYAnchor.constraint(equalTo: dropView.centerYAnchor)
        ])

        window.contentView = dropView
    }

    // MARK: - File Handling

    func openFile(_ url: URL) {
        currentFileURL = url
        window.title = "QuickDown — \(url.lastPathComponent)"

        do {
            let content = try readFileWithFallbackEncoding(url: url)
            let html = generateHTML(markdown: content)
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
            webView.isHidden = false
            dropZoneLabel.isHidden = true
        } catch {
            showError("Failed to open file: \(error.localizedDescription)")
        }
    }

    private func readFileWithFallbackEncoding(url: URL) throws -> String {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .windowsCP1252) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
            return content
        }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Export

    func exportPDF() {
        guard let currentFileURL = currentFileURL else {
            showError("No file loaded. Open a Markdown file first.")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = currentFileURL.deletingPathExtension().lastPathComponent + ".pdf"

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            self?.performPDFExport(to: url)
        }
    }

    private func performPDFExport(to url: URL) {
        // Get the full content size from the web view
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] (height, error) in
            guard let self = self else { return }

            let contentHeight = (height as? CGFloat) ?? 792
            let pageWidth: CGFloat = 612  // US Letter width in points

            let config = WKPDFConfiguration()
            // Don't set rect - let it capture full content

            self.webView.createPDF(configuration: config) { result in
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        self.showError("Failed to save PDF: \(error.localizedDescription)")
                    }
                case .failure(let error):
                    self.showError("Failed to create PDF: \(error.localizedDescription)")
                }
            }
        }
    }

    func exportHTML() {
        guard let currentFileURL = currentFileURL else {
            showError("No file loaded. Open a Markdown file first.")
            return
        }

        do {
            let content = try readFileWithFallbackEncoding(url: currentFileURL)
            let html = generateHTML(markdown: content)

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.html]
            savePanel.nameFieldStringValue = currentFileURL.deletingPathExtension().lastPathComponent + ".html"

            savePanel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = savePanel.url else { return }

                do {
                    try html.write(to: url, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    self.showError("Failed to save HTML: \(error.localizedDescription)")
                }
            }
        } catch {
            showError("Failed to read file: \(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - HTML Generation

    private func loadResource(_ name: String, ext: String) -> String {
        // Try loading from the MarkdownPreview extension bundle
        if let plugInsURL = Bundle.main.builtInPlugInsURL {
            let extensionURL = plugInsURL.appendingPathComponent("MarkdownPreview.appex")
            if let bundle = Bundle(url: extensionURL),
               let url = bundle.url(forResource: name, withExtension: ext),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
            // Try Resources subdirectory
            let resourceURL = extensionURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent("\(name).\(ext)")
            if let content = try? String(contentsOf: resourceURL, encoding: .utf8) {
                return content
            }
        }
        // Fallback: try main bundle
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        print("Warning: Could not load resource \(name).\(ext)")
        return ""
    }

    private func generateHTML(markdown: String) -> String {
        let escapedMarkdown = escapeForJavaScript(markdown)

        let markedJS = loadResource("marked.min", ext: "js")
        let highlightJS = loadResource("highlight.min", ext: "js")
        let stylesCSS = loadResource("styles", ext: "css")
        let githubCSS = loadResource("github.min", ext: "css")
        let githubDarkCSS = loadResource("github-dark.min", ext: "css")

        let themeStyles = generateThemeStyles(
            githubCSS: githubCSS,
            githubDarkCSS: githubDarkCSS
        )

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>\(stylesCSS)</style>
            \(themeStyles)
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

    private func generateThemeStyles(githubCSS: String, githubDarkCSS: String) -> String {
        switch currentTheme {
        case .system:
            return """
            <style media="(prefers-color-scheme: light)">\(githubCSS)</style>
            <style media="(prefers-color-scheme: dark)">\(githubDarkCSS)</style>
            """
        case .light:
            return """
            <meta name="color-scheme" content="light only">
            <style>
            :root { color-scheme: light only; }
            \(githubCSS)
            body, #content {
                background-color: #ffffff !important;
                color: #1f2328 !important;
            }
            table, th, td, tr {
                background-color: #ffffff !important;
                color: #1f2328 !important;
                border-color: #d0d7de !important;
            }
            th {
                background-color: #f6f8fa !important;
            }
            tr:nth-child(2n) {
                background-color: #f6f8fa !important;
            }
            pre, code {
                background-color: #f6f8fa !important;
                color: #1f2328 !important;
            }
            </style>
            """
        case .dark:
            return """
            <meta name="color-scheme" content="dark only">
            <style>
            :root { color-scheme: dark only; }
            \(githubDarkCSS)
            </style>
            """
        case .sepia:
            return """
            <meta name="color-scheme" content="light only">
            <style>
            :root { color-scheme: light only; }
            \(githubCSS)
            body, #content {
                background-color: #f4ecd8 !important;
                color: #5b4636 !important;
            }
            table, th, td, tr {
                background-color: #f4ecd8 !important;
                color: #5b4636 !important;
                border-color: #d4c4a8 !important;
            }
            th {
                background-color: #e8dcc8 !important;
            }
            tr:nth-child(2n) {
                background-color: #ebe3d0 !important;
            }
            pre, code {
                background-color: #e8dcc8 !important;
                color: #5b4636 !important;
            }
            a { color: #8b4513 !important; }
            h1, h2, h3, h4, h5, h6 { color: #5b4636 !important; }
            </style>
            """
        }
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

    // MARK: - Menu Setup

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About QuickDown", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit QuickDown", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Export as PDF…", action: #selector(exportPDFAction(_:)), keyEquivalent: "e")
        fileMenu.addItem(withTitle: "Export as HTML…", action: #selector(exportHTMLAction(_:)), keyEquivalent: "E")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        // Theme submenu
        let themeMenuItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        for theme in Theme.allCases {
            let item = NSMenuItem(
                title: theme.rawValue,
                action: #selector(selectTheme(_:)),
                keyEquivalent: ""
            )
            item.representedObject = theme
            item.state = (theme == currentTheme) ? .on : .off
            themeMenu.addItem(item)
        }
        themeMenuItem.submenu = themeMenu
        viewMenu.addItem(themeMenuItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Menu Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!,
                                      .init(filenameExtension: "markdown")!,
                                      .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFile(url)
        }
    }

    @objc func exportPDFAction(_ sender: Any?) {
        exportPDF()
    }

    @objc func exportHTMLAction(_ sender: Any?) {
        exportHTML()
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? Theme else { return }
        currentTheme = theme

        // Update menu checkmarks
        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = (item.representedObject as? Theme == theme) ? .on : .off
            }
        }

        // Reload current file with new theme
        if let url = currentFileURL {
            do {
                let content = try readFileWithFallbackEncoding(url: url)
                let html = generateHTML(markdown: content)
                webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
            } catch {
                // Ignore reload errors
            }
        }
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportPDFAction(_:)) ||
           menuItem.action == #selector(exportHTMLAction(_:)) {
            return currentFileURL != nil
        }
        return true
    }

    // MARK: - Open from Finder

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openFile(url)
    }
}

// MARK: - Droppable WebView

class DroppableWebView: WKWebView {
    var onFileDrop: ((URL) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasMarkdownFile(sender) {
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasMarkdownFile(sender) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = getMarkdownURL(from: sender) else { return false }
        onFileDrop?(url)
        return true
    }

    private func hasMarkdownFile(_ sender: NSDraggingInfo) -> Bool {
        return getMarkdownURL(from: sender) != nil
    }

    private func getMarkdownURL(from sender: NSDraggingInfo) -> URL? {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first else { return nil }

        let markdownExtensions = ["md", "markdown", "mdown", "mkdn", "mkd"]
        if markdownExtensions.contains(url.pathExtension.lowercased()) {
            return url
        }
        return nil
    }
}

// MARK: - Drop View

class DropView: NSView {
    var onFileDrop: ((URL) -> Void)?
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasMarkdownFile(sender) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = getMarkdownURL(from: sender) else { return false }
        onFileDrop?(url)
        return true
    }

    private func hasMarkdownFile(_ sender: NSDraggingInfo) -> Bool {
        return getMarkdownURL(from: sender) != nil
    }

    private func getMarkdownURL(from sender: NSDraggingInfo) -> URL? {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first else { return nil }

        let markdownExtensions = ["md", "markdown", "mdown", "mkdn", "mkd"]
        if markdownExtensions.contains(url.pathExtension.lowercased()) {
            return url
        }
        return nil
    }
}
