import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    var window: NSWindow!
    var webView: WKWebView!
    var dropZoneLabel: NSTextField!
    var currentFileURL: URL?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

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

    func applicationWillTerminate(_ notification: Notification) {
        stopWatchingFile()
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
        // Stop watching the previous file
        stopWatchingFile()

        currentFileURL = url
        window.title = "QuickDown — \(url.lastPathComponent)"

        do {
            let content = try readFileWithFallbackEncoding(url: url)
            let html = generateHTML(markdown: content)
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
            webView.isHidden = false
            dropZoneLabel.isHidden = true

            // Start watching for changes
            startWatchingFile(url)
        } catch {
            showError("Failed to open file: \(error.localizedDescription)")
        }
    }

    // MARK: - Live Reload

    private func startWatchingFile(_ url: URL) {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )

        fileWatcher?.setEventHandler { [weak self] in
            self?.reloadCurrentFile()
        }

        fileWatcher?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        fileWatcher?.resume()
    }

    private func stopWatchingFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    private func reloadCurrentFile() {
        guard let url = currentFileURL else { return }

        // Save scroll position before reload
        webView.evaluateJavaScript("window.scrollY") { [weak self] (scrollY, _) in
            guard let self = self else { return }

            do {
                let content = try self.readFileWithFallbackEncoding(url: url)
                let html = self.generateHTML(markdown: content)
                self.webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())

                // Restore scroll position after content loads
                if let scrollPosition = scrollY as? Double {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.webView.evaluateJavaScript("window.scrollTo(0, \(scrollPosition))")
                    }
                }
            } catch {
                // Silently fail on reload errors - file might be mid-save
            }
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
