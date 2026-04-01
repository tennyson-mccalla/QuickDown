import Cocoa
import UniformTypeIdentifiers
import WebKit

// MARK: - Local File Scheme Handler

/// Serves local files to WKWebView via a custom URL scheme, bypassing sandbox
/// restrictions on WebKit's content process. The app process has security-scoped
/// bookmark access; this handler bridges that access to WebKit.
class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let filePath = url.path
        let fileURL = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: filePath) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType: String
            if let utType = UTType(filenameExtension: fileURL.pathExtension) {
                mimeType = utType.preferredMIMEType ?? "application/octet-stream"
            } else {
                mimeType = "application/octet-stream"
            }
            let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No async work to cancel
    }
}

enum Theme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case sepia = "Sepia"
    case solarizedLight = "Solarized Light"
    case solarizedDark = "Solarized Dark"
    case nord = "Nord"
}

struct TOCItem {
    let level: Int
    let title: String
    let id: String
}

struct FileState {
    let url: URL
    var contentHash: Int = 0
    var scrollY: Double = 0
    var sidebarVisible: Bool = false
    var fontScale: Double = 1.0
    var isRawMode: Bool = false
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSSearchFieldDelegate {

    var window: NSWindow!
    var webView: WKWebView?  // Lazily initialized when first file is opened
    var dropZoneLabel: NSTextField!
    private var mainContentView: DropView!  // Container for lazy WebView

    // Tab state
    private var openFiles: [FileState] = []
    private var activeFileIndex: Int = 0

    // Convenience accessor for the active file (nil when no files open)
    var currentFileURL: URL? {
        guard !openFiles.isEmpty else { return nil }
        return openFiles[activeFileIndex].url
    }

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var reloadDebounceWorkItem: DispatchWorkItem?

    private let tempHTMLURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("quickdown-preview.html")

    private var recentFilesMenu: NSMenu!
    private let recentFilesKey = "RecentFiles"
    private let directoryBookmarksKey = "DirectoryBookmarks"
    private let maxRecentFiles = 10
    private let maxDirectoryBookmarks = 50

    // TOC sidebar
    private var splitView: NSSplitView!
    private var tocScrollView: NSScrollView!
    private var tocTableView: NSTableView!
    private var tocItems: [TOCItem] = []
    private var isSidebarVisible = false
    private let sidebarVisibleKey = "SidebarVisible"

    // Search
    private var searchBar: NSView!
    private var searchField: NSSearchField!
    private var searchResultLabel: NSTextField!
    private var searchBarHeightConstraint: NSLayoutConstraint!
    private var isSearchVisible = false

    // Word count
    private var wordCountLabel: NSTextField!
    private var themeLabelColor: NSColor?  // nil = use system default

    // Track setup state for deferred file opens
    private var isSetupComplete = false
    private var pendingFileURLs: [URL] = []
    private var pendingScrollRestoreY: Double?
    private var snapshotOverlay: NSImageView?
    private var currentAccessibleDirectory: URL?
    private var currentAccessedDirectoryURL: URL?

    // Tab bar (added in Task 2)
    private var tabBarView: PillTabBarView!
    private var tabBarHeightConstraint: NSLayoutConstraint!

    // Font size
    private let fontScaleKey = "FontScale"
    private let fontScaleMin = 0.7
    private let fontScaleMax = 2.0
    private let fontScaleStep = 0.1
    private var fontScale: Double {
        get {
            let val = UserDefaults.standard.double(forKey: fontScaleKey)
            return val > 0 ? val : 1.0
        }
        set {
            let clamped = min(max(newValue, fontScaleMin), fontScaleMax)
            UserDefaults.standard.set(clamped, forKey: fontScaleKey)
        }
    }

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
        updateWindowBackground()  // Apply saved theme to window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Register as Services provider
        NSApp.servicesProvider = self

        // Mark setup complete and open any pending file
        isSetupComplete = true
        if !pendingFileURLs.isEmpty {
            let urls = pendingFileURLs
            pendingFileURLs = []
            for url in urls {
                openFile(url)
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
        currentAccessedDirectoryURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Window Setup

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickDown"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(width: 500, height: 300)

        // Create split view
        splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autoresizingMask = [.width, .height]

        // Create TOC sidebar
        setupTOCSidebar()

        // Create drop view for main content (WebView created lazily when file opened)
        mainContentView = DropView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        mainContentView.autoresizingMask = [.width, .height]
        mainContentView.onFileDrop = { [weak self] url in
            self?.openFile(url)
        }
        mainContentView.onClick = { [weak self] in
            self?.openDocument(nil)
        }

        // Create drop zone label
        dropZoneLabel = NSTextField(labelWithString: "Drop a Markdown file here\nor use File → Open")
        dropZoneLabel.alignment = .center
        dropZoneLabel.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        dropZoneLabel.textColor = .secondaryLabelColor
        dropZoneLabel.translatesAutoresizingMaskIntoConstraints = false
        mainContentView.addSubview(dropZoneLabel)

        NSLayoutConstraint.activate([
            dropZoneLabel.centerXAnchor.constraint(equalTo: mainContentView.centerXAnchor),
            dropZoneLabel.centerYAnchor.constraint(equalTo: mainContentView.centerYAnchor)
        ])

        // Add views to split view
        splitView.addArrangedSubview(tocScrollView)
        splitView.addArrangedSubview(mainContentView)

        // Create container view for search bar + split view
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        containerView.autoresizingMask = [.width, .height]

        // Setup search bar
        setupSearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(searchBar)

        // Setup tab bar (hidden until 2+ files are open)
        tabBarView = PillTabBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 34))
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        tabBarView.delegate = self
        tabBarView.isHidden = true
        containerView.addSubview(tabBarView)

        tabBarHeightConstraint = tabBarView.heightAnchor.constraint(equalToConstant: 0)

        splitView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(splitView)

        // Word/character count status bar
        wordCountLabel = NSTextField(labelWithString: "")
        wordCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        wordCountLabel.textColor = .tertiaryLabelColor
        wordCountLabel.alignment = .right
        wordCountLabel.translatesAutoresizingMaskIntoConstraints = false
        wordCountLabel.isHidden = true
        containerView.addSubview(wordCountLabel)

        searchBarHeightConstraint = searchBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: containerView.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            searchBarHeightConstraint,

            tabBarView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tabBarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tabBarView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tabBarHeightConstraint,

            splitView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: wordCountLabel.topAnchor),

            wordCountLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            wordCountLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            wordCountLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
            wordCountLabel.heightAnchor.constraint(equalToConstant: 18)
        ])

        // Set initial sidebar state
        isSidebarVisible = UserDefaults.standard.bool(forKey: sidebarVisibleKey)
        splitView.setPosition(isSidebarVisible ? 200 : 0, ofDividerAt: 0)
        tocScrollView.isHidden = !isSidebarVisible

        // Initially hide search bar (height already 0)
        searchBar.isHidden = true

        window.contentView = containerView
    }

    private func setupTOCSidebar() {
        // Create table view for TOC
        tocTableView = NSTableView()
        tocTableView.headerView = nil
        tocTableView.rowHeight = 24
        tocTableView.intercellSpacing = NSSize(width: 0, height: 2)
        tocTableView.backgroundColor = .clear
        tocTableView.selectionHighlightStyle = .regular
        tocTableView.dataSource = self
        tocTableView.delegate = self
        tocTableView.target = self
        tocTableView.action = #selector(tocItemClicked)
        tocTableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TOC"))
        column.title = "Table of Contents"
        column.resizingMask = .autoresizingMask
        column.width = 200
        tocTableView.addTableColumn(column)

        // Create scroll view
        tocScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        tocScrollView.documentView = tocTableView
        tocScrollView.hasVerticalScroller = true
        tocScrollView.autohidesScrollers = true
        tocScrollView.borderType = .noBorder
        tocScrollView.drawsBackground = false
    }

    @objc private func tocItemClicked() {
        let row = tocTableView.clickedRow
        guard row >= 0 && row < tocItems.count else { return }
        let item = tocItems[row]
        webView?.evaluateJavaScript("document.getElementById('\(item.id)')?.scrollIntoView({behavior: 'smooth'})")
    }

    @objc func toggleSidebar(_ sender: Any?) {
        isSidebarVisible.toggle()
        UserDefaults.standard.set(isSidebarVisible, forKey: sidebarVisibleKey)

        // Save to active tab
        if !openFiles.isEmpty {
            openFiles[activeFileIndex].sidebarVisible = isSidebarVisible
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            tocScrollView.isHidden = !isSidebarVisible
            splitView.setPosition(isSidebarVisible ? 200 : 0, ofDividerAt: 0)
        }
    }

    private func setupSearchBar() {
        searchBar = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 32))
        searchBar.wantsLayer = true
        searchBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Search field
        searchField = NSSearchField(frame: NSRect(x: 8, y: 4, width: 300, height: 24))
        searchField.placeholderString = "Search in document"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchField)

        // Previous button
        let prevButton = NSButton(title: "◀", target: self, action: #selector(findPrevious(_:)))
        prevButton.bezelStyle = .inline
        prevButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(prevButton)

        // Next button
        let nextButton = NSButton(title: "▶", target: self, action: #selector(findNext(_:)))
        nextButton.bezelStyle = .inline
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(nextButton)

        // Result label
        searchResultLabel = NSTextField(labelWithString: "")
        searchResultLabel.font = NSFont.systemFont(ofSize: 11)
        searchResultLabel.textColor = .secondaryLabelColor
        searchResultLabel.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchResultLabel)

        // Close button
        let closeButton = NSButton(title: "✕", target: self, action: #selector(hideSearch(_:)))
        closeButton.bezelStyle = .inline
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(closeButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 250),

            prevButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            prevButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 4),
            nextButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            searchResultLabel.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 12),
            searchResultLabel.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor)
        ])
    }

    // MARK: - Search Actions

    @objc func showSearch(_ sender: Any?) {
        isSearchVisible = true
        searchBar.isHidden = false
        searchBarHeightConstraint.constant = 32
        window.makeFirstResponder(searchField)
    }

    @objc func hideSearch(_ sender: Any?) {
        isSearchVisible = false
        searchBarHeightConstraint.constant = 0
        searchBar.isHidden = true
        clearSearchHighlights()
        searchResultLabel.stringValue = ""
    }

    @objc func searchFieldAction(_ sender: NSSearchField) {
        performSearch(sender.stringValue)
    }

    // Handle Escape key to dismiss search
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == NSSelectorFromString("cancelOperation:") {
            hideSearch(nil)
            return true
        }
        return false
    }

    @objc func findNext(_ sender: Any?) {
        webView?.evaluateJavaScript("window.findNext && window.findNext()") { [weak self] result, _ in
            if let info = result as? [String: Int],
               let current = info["current"],
               let total = info["total"] {
                self?.searchResultLabel.stringValue = "\(current) of \(total)"
            }
        }
    }

    @objc func findPrevious(_ sender: Any?) {
        webView?.evaluateJavaScript("window.findPrevious && window.findPrevious()") { [weak self] result, _ in
            if let info = result as? [String: Int],
               let current = info["current"],
               let total = info["total"] {
                self?.searchResultLabel.stringValue = "\(current) of \(total)"
            }
        }
    }

    private func performSearch(_ query: String) {
        guard !query.isEmpty else {
            clearSearchHighlights()
            searchResultLabel.stringValue = ""
            return
        }

        let escapedQuery = query.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            // Clear previous highlights
            document.querySelectorAll('.search-highlight').forEach(el => {
                el.outerHTML = el.textContent;
            });

            const query = '\(escapedQuery)'.toLowerCase();
            if (!query) return { count: 0, current: 0 };

            const content = document.getElementById('content');
            const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null, false);
            const matches = [];
            let node;

            while (node = walker.nextNode()) {
                const text = node.textContent.toLowerCase();
                let index = 0;
                while ((index = text.indexOf(query, index)) !== -1) {
                    matches.push({ node: node, index: index });
                    index += query.length;
                }
            }

            // Highlight matches
            for (let i = matches.length - 1; i >= 0; i--) {
                const match = matches[i];
                const range = document.createRange();
                range.setStart(match.node, match.index);
                range.setEnd(match.node, match.index + query.length);
                const span = document.createElement('span');
                span.className = 'search-highlight';
                span.style.backgroundColor = '#ffff00';
                span.style.color = '#000000';
                range.surroundContents(span);
            }

            window.searchMatches = document.querySelectorAll('.search-highlight');
            window.currentMatchIndex = 0;

            if (window.searchMatches.length > 0) {
                window.searchMatches[0].style.backgroundColor = '#ff9500';
                window.searchMatches[0].scrollIntoView({ block: 'center' });
            }

            // Create scroll markers
            var markerContainer = document.getElementById('search-markers');
            if (!markerContainer) {
                markerContainer = document.createElement('div');
                markerContainer.id = 'search-markers';
                markerContainer.style.cssText = 'position:fixed;right:0;top:0;width:8px;height:100%;pointer-events:none;z-index:9999;';
                document.body.appendChild(markerContainer);
            }
            markerContainer.innerHTML = '';

            var docHeight = document.documentElement.scrollHeight;
            window.searchMatches.forEach(function(match, i) {
                var rect = match.getBoundingClientRect();
                var scrollTop = window.pageYOffset || document.documentElement.scrollTop;
                var absoluteTop = rect.top + scrollTop;
                var percent = (absoluteTop / docHeight) * 100;
                var marker = document.createElement('div');
                marker.style.cssText = 'position:absolute;right:0;width:8px;height:3px;background:#ff9500;top:' + percent + '%;';
                marker.dataset.index = i;
                markerContainer.appendChild(marker);
            });

            window.findNext = function() {
                if (!window.searchMatches || window.searchMatches.length === 0) return null;
                window.searchMatches[window.currentMatchIndex].style.backgroundColor = '#ffff00';
                window.currentMatchIndex = (window.currentMatchIndex + 1) % window.searchMatches.length;
                window.searchMatches[window.currentMatchIndex].style.backgroundColor = '#ff9500';
                window.searchMatches[window.currentMatchIndex].scrollIntoView({ block: 'center' });
                return { current: window.currentMatchIndex + 1, total: window.searchMatches.length };
            };

            window.findPrevious = function() {
                if (!window.searchMatches || window.searchMatches.length === 0) return null;
                window.searchMatches[window.currentMatchIndex].style.backgroundColor = '#ffff00';
                window.currentMatchIndex = (window.currentMatchIndex - 1 + window.searchMatches.length) % window.searchMatches.length;
                window.searchMatches[window.currentMatchIndex].style.backgroundColor = '#ff9500';
                window.searchMatches[window.currentMatchIndex].scrollIntoView({ block: 'center' });
                return { current: window.currentMatchIndex + 1, total: window.searchMatches.length };
            };

            return { count: window.searchMatches.length, current: 1 };
        })();
        """

        webView?.evaluateJavaScript(js) { [weak self] result, error in
            if let dict = result as? [String: Int] {
                let count = dict["count"] ?? 0
                if count > 0 {
                    self?.searchResultLabel.stringValue = "1 of \(count)"
                } else {
                    self?.searchResultLabel.stringValue = "No matches"
                }
            }
        }
    }

    private func clearSearchHighlights() {
        webView?.evaluateJavaScript("""
            document.querySelectorAll('.search-highlight').forEach(el => {
                el.outerHTML = el.textContent;
            });
            var markers = document.getElementById('search-markers');
            if (markers) markers.remove();
            window.searchMatches = null;
            window.currentMatchIndex = 0;
        """)
    }

    // MARK: - File Handling

    /// Lazily creates the WebView when first needed (saves ~0.3-0.5s on app launch)
    private func ensureWebViewExists() {
        guard webView == nil else { return }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: "quickdown-file")
        let wv = DroppableWebView(frame: mainContentView.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.onFileDrop = { [weak self] url in
            self?.openFile(url)
        }
        wv.isHidden = true

        // Make WebView background transparent so theme colors show correctly
        wv.setValue(false, forKey: "drawsBackground")

        mainContentView.addSubview(wv)
        webView = wv
    }

    private func loadHTMLInWebView(_ html: String, allowingAccessTo directory: URL? = nil) throws {
        try html.write(to: tempHTMLURL, atomically: true, encoding: .utf8)
        // Images are served via quickdown-file:// scheme handler, so we only
        // need read access to the temp directory for the HTML file itself.
        webView?.loadFileURL(tempHTMLURL, allowingReadAccessTo: FileManager.default.temporaryDirectory)
    }

    func openFile(_ url: URL) {
        guard window != nil else {
            NSLog("QuickDown: openFile called but window is nil")
            return
        }

        // If this file is already open, switch to its tab
        if let existingIndex = openFiles.firstIndex(where: { $0.url.path == url.path }) {
            switchToTab(existingIndex)
            return
        }

        ensureWebViewExists()

        // Save current tab state before adding new tab
        let addAndLoad = { [weak self] in
            guard let self = self else { return }

            // Create new file state, inheriting current sidebar/font settings
            var newFile = FileState(url: url)
            newFile.sidebarVisible = self.isSidebarVisible
            newFile.fontScale = self.fontScale

            // Add tab after the current active tab
            let insertIndex = self.openFiles.isEmpty ? 0 : self.activeFileIndex + 1
            self.openFiles.insert(newFile, at: insertIndex)
            self.activeFileIndex = insertIndex

            self.loadTab(at: insertIndex)

            self.webView?.isHidden = false
            self.dropZoneLabel.isHidden = true

            self.addToRecentFiles(url)
        }

        if openFiles.isEmpty {
            addAndLoad()
        } else {
            saveCurrentTabState { addAndLoad() }
        }
    }

    /// Opens multiple files at once — adds all as tabs, then loads only the last one.
    /// Avoids the cascading async crossfade issue of calling openFile() in a loop.
    func openFiles(_ urls: [URL]) {
        guard !urls.isEmpty, window != nil else { return }
        if urls.count == 1 {
            openFile(urls[0])
            return
        }

        ensureWebViewExists()

        // Filter out already-open files and deduplicate
        let newURLs = urls.filter { url in
            !openFiles.contains(where: { $0.url.path == url.path })
        }
        guard !newURLs.isEmpty else {
            // All files already open — just activate the last one
            if let last = urls.last,
               let idx = openFiles.firstIndex(where: { $0.url.path == last.path }) {
                switchToTab(idx)
            }
            return
        }

        // Add all new files as tabs silently (no loading/crossfade)
        for url in newURLs {
            var newFile = FileState(url: url)
            newFile.sidebarVisible = isSidebarVisible
            newFile.fontScale = fontScale
            openFiles.append(newFile)
            addToRecentFiles(url)
        }

        // Load only the last added file
        let lastIndex = openFiles.count - 1
        activeFileIndex = lastIndex
        loadTab(at: lastIndex)

        webView?.isHidden = false
        dropZoneLabel.isHidden = true
    }

    private func parseTOC(from markdown: String) -> [TOCItem] {
        var items: [TOCItem] = []
        let lines = markdown.components(separatedBy: .newlines)
        var inCodeBlock = false

        for line in lines {
            // Track code blocks to avoid parsing headings inside them
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { continue }

            // Match ATX-style headings (# Heading)
            if let match = line.range(of: "^(#{1,6})\\s+(.+)$", options: .regularExpression) {
                let matchedLine = String(line[match])
                let hashCount = matchedLine.prefix(while: { $0 == "#" }).count
                let title = matchedLine.dropFirst(hashCount).trimmingCharacters(in: .whitespaces)
                let id = generateHeadingId(title)
                items.append(TOCItem(level: hashCount, title: title, id: id))
            }
        }
        return items
    }

    private func generateHeadingId(_ title: String) -> String {
        return title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
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
            guard let self = self else { return }
            let eventData = self.fileWatcher?.data ?? []

            // Debounce: cancel pending reload and schedule a new one
            self.reloadDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.reloadCurrentFile()
            }
            self.reloadDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)

            // Atomic saves (write-then-rename) replace the inode, invalidating our
            // file descriptor. Restart the watcher to track the new inode.
            if eventData.contains(.rename) || eventData.contains(.delete) {
                let watchedURL = url
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self, self.currentFileURL == watchedURL else { return }
                    self.stopWatchingFile()
                    self.startWatchingFile(watchedURL)
                }
            }
        }

        let fd = fileDescriptor
        fileWatcher?.setCancelHandler {
            // Capture fd by value so restarting the watcher doesn't accidentally
            // close the new file descriptor when this cancel handler fires.
            close(fd)
        }

        fileWatcher?.resume()
    }

    private func stopWatchingFile() {
        reloadDebounceWorkItem?.cancel()
        reloadDebounceWorkItem = nil
        fileWatcher?.cancel()  // cancel handler owns the close of the captured fd
        fileWatcher = nil
        fileDescriptor = -1
    }

    private func reloadCurrentFile() {
        guard !openFiles.isEmpty else { return }
        let url = openFiles[activeFileIndex].url

        webView?.evaluateJavaScript("window.scrollY") { [weak self] (scrollY, _) in
            guard let self = self, !self.openFiles.isEmpty else { return }

            do {
                let content = try self.readFileWithFallbackEncoding(url: url)

                let contentHash = content.hashValue
                if contentHash == self.openFiles[self.activeFileIndex].contentHash {
                    return
                }
                self.openFiles[self.activeFileIndex].contentHash = contentHash

                self.tocItems = self.parseTOC(from: content)
                self.tocTableView.reloadData()
                self.updateWordCount(content)

                let html = self.generateHTML(markdown: content, baseDirectoryURL: self.currentAccessibleDirectory)

                try html.write(to: self.tempHTMLURL, atomically: true, encoding: .utf8)
                self.pendingScrollRestoreY = scrollY as? Double
                self.crossfadeTransition { [weak self] in
                    guard let self = self else { return }
                    self.webView?.loadFileURL(self.tempHTMLURL, allowingReadAccessTo: FileManager.default.temporaryDirectory)
                }
            } catch {
                // Silently fail on reload errors - file might be mid-save
            }
        }
    }

    // MARK: - Recent Files (with security-scoped bookmarks for sandbox)

    private func addToRecentFiles(_ url: URL) {
        var bookmarks = getRecentBookmarks()

        // Remove existing bookmark for same path
        bookmarks.removeAll { resolveBookmark($0)?.path == url.path }

        // Create security-scoped bookmark
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarks.insert(bookmark, at: 0)
        } catch {
            // Fallback: store without bookmark (won't persist across launches)
            print("Failed to create bookmark: \(error)")
        }

        // Limit count
        if bookmarks.count > maxRecentFiles {
            bookmarks = Array(bookmarks.prefix(maxRecentFiles))
        }

        UserDefaults.standard.set(bookmarks, forKey: recentFilesKey)
        updateRecentFilesMenu()
    }

    private func getRecentBookmarks() -> [Data] {
        return UserDefaults.standard.array(forKey: recentFilesKey) as? [Data] ?? []
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return url
        } catch {
            return nil
        }
    }

    private func getRecentFiles() -> [(url: URL, bookmark: Data)] {
        return getRecentBookmarks().compactMap { bookmark in
            if let url = resolveBookmark(bookmark) {
                return (url, bookmark)
            }
            return nil
        }
    }

    private func updateRecentFilesMenu() {
        recentFilesMenu.removeAllItems()

        let recentFiles = getRecentFiles()

        if recentFiles.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentFilesMenu.addItem(emptyItem)
        } else {
            for (index, entry) in recentFiles.enumerated() {
                let item = NSMenuItem(
                    title: entry.url.lastPathComponent,
                    action: #selector(openRecentFile(_:)),
                    keyEquivalent: index < 9 ? "\(index + 1)" : ""
                )
                item.keyEquivalentModifierMask = index < 9 ? [.command, .shift] : []
                item.representedObject = entry.bookmark
                item.toolTip = entry.url.path
                recentFilesMenu.addItem(item)
            }

            recentFilesMenu.addItem(NSMenuItem.separator())
            recentFilesMenu.addItem(withTitle: "Clear Recent Files", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
        }
    }

    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let bookmark = sender.representedObject as? Data,
              let url = resolveBookmark(bookmark) else {
            showError("Could not resolve file from recent files")
            return
        }

        // Start accessing the security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            showError("Permission denied: \(url.lastPathComponent)")
            return
        }

        if FileManager.default.fileExists(atPath: url.path) {
            openFile(url)
            // Note: we don't call stopAccessingSecurityScopedResource here
            // because we need continued access for live reload
        } else {
            url.stopAccessingSecurityScopedResource()
            showError("File not found: \(url.lastPathComponent)")
            // Remove from recents
            var bookmarks = getRecentBookmarks()
            bookmarks.removeAll { $0 == bookmark }
            UserDefaults.standard.set(bookmarks, forKey: recentFilesKey)
            updateRecentFilesMenu()
        }
    }

    @objc private func clearRecentFiles(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: recentFilesKey)
        updateRecentFilesMenu()
    }

    // MARK: - Directory Access (Sandbox)

    private func getDirectoryBookmarks() -> [String: Data] {
        return UserDefaults.standard.dictionary(forKey: directoryBookmarksKey) as? [String: Data] ?? [:]
    }

    /// Resolves and begins accessing the security-scoped bookmark for the given directory.
    /// Returns the directory URL if access was granted, nil otherwise.
    private func resolveDirectoryBookmark(for directoryPath: String) -> URL? {
        let bookmarks = getDirectoryBookmarks()
        guard let data = bookmarks[directoryPath] else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                if let newData = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    var bookmarks = getDirectoryBookmarks()
                    bookmarks[directoryPath] = newData
                    UserDefaults.standard.set(bookmarks, forKey: directoryBookmarksKey)
                }
            }

            guard url.startAccessingSecurityScopedResource() else {
                return nil
            }

            return url
        } catch {
            return nil
        }
    }

    /// Returns the parent directory URL with sandbox access, either from a stored
    /// bookmark or by prompting the user to grant access via NSOpenPanel.
    /// When `promptIfNeeded` is false, only uses saved bookmarks (no UI prompt).
    private func accessibleParentDirectory(for fileURL: URL, promptIfNeeded: Bool = true) -> URL? {
        let dirURL = fileURL.deletingLastPathComponent()

        // Stop accessing the previous directory
        currentAccessedDirectoryURL?.stopAccessingSecurityScopedResource()
        currentAccessedDirectoryURL = nil

        // Try existing bookmark first (saved from a previous grant)
        if let resolved = resolveDirectoryBookmark(for: dirURL.path) {
            currentAccessedDirectoryURL = resolved
            return resolved
        }

        // No bookmark — prompt user only if requested (i.e., file has relative images)
        if promptIfNeeded, let granted = requestDirectoryAccess(for: dirURL) {
            currentAccessedDirectoryURL = granted
            return granted
        }

        return nil
    }

    /// Checks whether markdown content contains relative image or link paths
    /// (not absolute paths or URLs). Used to avoid prompting for directory access
    /// when the file doesn't reference any local resources.
    private func contentHasRelativePaths(_ markdown: String) -> Bool {
        // Match ![...](...) and [...](...) where the path doesn't start with http/https/# or /
        // Also match HTML <img src="..."> with relative paths
        let patterns = [
            #"!\[[^\]]*\]\((?!https?://|/|#)"#,      // ![alt](relative/path)
            #"<img\s[^>]*src\s*=\s*"(?!https?://|/)"# // <img src="relative/path">
        ]
        for pattern in patterns {
            if markdown.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Shows an NSOpenPanel asking the user to grant access to a directory
    /// so relative images can be displayed. Saves a bookmark on success.
    private func requestDirectoryAccess(for directoryURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directoryURL
        panel.message = "QuickDown needs access to this folder to display images referenced in your Markdown file."
        panel.prompt = "Grant Access"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        // Save bookmark for future sessions
        do {
            let bookmarkData = try selectedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = getDirectoryBookmarks()
            bookmarks[selectedURL.path] = bookmarkData

            // LRU eviction: prevent unbounded bookmark growth
            if bookmarks.count > maxDirectoryBookmarks {
                let excess = bookmarks.count - maxDirectoryBookmarks
                for key in Array(bookmarks.keys.prefix(excess)) {
                    bookmarks.removeValue(forKey: key)
                }
            }

            UserDefaults.standard.set(bookmarks, forKey: directoryBookmarksKey)
        } catch {
            NSLog("QuickDown: Could not bookmark granted directory: \(error)")
        }

        guard selectedURL.startAccessingSecurityScopedResource() else {
            return nil
        }
        return selectedURL
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
        guard let wv = webView else { return }

        // Get the full content size from the web view
        wv.evaluateJavaScript("document.body.scrollHeight") { [weak self] (_, _) in
            guard let self = self, let wv = self.webView else { return }

            let config = WKPDFConfiguration()
            // Don't set rect - let it capture full content

            wv.createPDF(configuration: config) { result in
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

        // Extract pre-rendered HTML from WKWebView (no JS needed in output)
        webView?.evaluateJavaScript("document.getElementById('content').innerHTML") { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                self.showError("Failed to extract HTML: \(error.localizedDescription)")
                return
            }

            guard let renderedContent = result as? String else {
                self.showError("Failed to extract HTML content")
                return
            }

            let html = self.generateStaticHTML(content: renderedContent)

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.html]
            savePanel.nameFieldStringValue = currentFileURL.deletingPathExtension().lastPathComponent + ".html"

            savePanel.beginSheetModal(for: self.window) { response in
                guard response == .OK, let url = savePanel.url else { return }

                do {
                    try html.write(to: url, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    self.showError("Failed to save HTML: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func shareDocument(_ sender: Any?) {
        guard let sourceURL = currentFileURL else {
            showError("No file loaded. Open a Markdown file first.")
            return
        }

        // Extract rendered HTML from WebView
        webView?.evaluateJavaScript("document.getElementById('content').innerHTML") { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                self.showError("Failed to extract content: \(error.localizedDescription)")
                return
            }

            guard let renderedContent = result as? String else {
                self.showError("Failed to extract content")
                return
            }

            // Create HTML content
            let html = self.generateStaticHTML(content: renderedContent)

            // Write to temporary file for AirDrop
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = sourceURL.deletingPathExtension().lastPathComponent + ".html"
            let tempFileURL = tempDir.appendingPathComponent(fileName)

            do {
                try html.write(to: tempFileURL, atomically: true, encoding: .utf8)
            } catch {
                self.showError("Failed to create shareable file: \(error.localizedDescription)")
                return
            }

            // Share the file URL (works with AirDrop)
            let shareItems: [Any] = [tempFileURL]

            // Show share picker
            let picker = NSSharingServicePicker(items: shareItems)

            // Position the picker relative to the window's content view
            // (sender may be deallocated by the time this async callback runs)
            if let contentView = self.window.contentView {
                let rect = NSRect(x: contentView.bounds.width / 2 - 1, y: contentView.bounds.height - 50, width: 2, height: 2)
                picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
            }
        }
    }

    private func generateStaticHTML(content: String) -> String {
        let stylesCSS = loadResource("styles", ext: "css")
        let githubCSS = loadResource("github.min", ext: "css")
        let githubDarkCSS = loadResource("github-dark.min", ext: "css")

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>\(stylesCSS)</style>
            <style id="hl-light">\(githubCSS)</style>
            <style id="hl-dark">\(githubDarkCSS)</style>
            \(themeScript)
        </head>
        <body>
            <div id="content">\(content)</div>
        </body>
        </html>
        """
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - HTML Generation

    private var themeScript: String {
        """
        <script>
        function applyTheme(theme) {
            var html = document.documentElement;
            var hlLight = document.getElementById('hl-light');
            var hlDark  = document.getElementById('hl-dark');
            if (theme === 'system') {
                html.removeAttribute('data-theme');
            } else {
                html.setAttribute('data-theme', theme);
            }
            var prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
            var useDark = theme === 'dark' || theme === 'solarized dark' || theme === 'nord' || (theme === 'system' && prefersDark);
            if (hlLight) hlLight.disabled = useDark;
            if (hlDark)  hlDark.disabled  = !useDark;
        }
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function() {
            if (!document.documentElement.hasAttribute('data-theme')) {
                applyTheme('system');
            }
        });
        applyTheme('\(currentTheme.rawValue.lowercased())');
        </script>
        """
    }

    // Cache for loaded resources (static files that never change)
    private static var resourceCache: [String: String] = [:]

    private func loadResource(_ name: String, ext: String) -> String {
        let cacheKey = "\(name).\(ext)"

        // Return cached version if available
        if let cached = AppDelegate.resourceCache[cacheKey] {
            return cached
        }

        var content = ""

        // Try loading from the MarkdownPreview extension bundle
        if let plugInsURL = Bundle.main.builtInPlugInsURL {
            let extensionURL = plugInsURL.appendingPathComponent("MarkdownPreview.appex")
            if let bundle = Bundle(url: extensionURL),
               let url = bundle.url(forResource: name, withExtension: ext),
               let loaded = try? String(contentsOf: url, encoding: .utf8) {
                content = loaded
            } else {
                // Try Resources subdirectory
                let resourceURL = extensionURL
                    .appendingPathComponent("Contents/Resources")
                    .appendingPathComponent("\(name).\(ext)")
                if let loaded = try? String(contentsOf: resourceURL, encoding: .utf8) {
                    content = loaded
                }
            }
        }

        // Fallback: try main bundle
        if content.isEmpty {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let loaded = try? String(contentsOf: url, encoding: .utf8) {
                content = loaded
            }
        }

        if content.isEmpty {
            print("Warning: Could not load resource \(name).\(ext)")
        } else {
            // Cache for future use
            AppDelegate.resourceCache[cacheKey] = content
        }

        return content
    }

    private func generateHTML(markdown: String, baseDirectoryURL: URL? = nil) -> String {
        let escapedMarkdown = escapeForJavaScript(markdown)

        let baseTag: String
        if let baseDir = baseDirectoryURL {
            // Use custom scheme so WKURLSchemeHandler can serve local files,
            // bypassing WebKit's sandbox restrictions on file:// sub-resources.
            let path = baseDir.path.hasSuffix("/") ? baseDir.path : baseDir.path + "/"
            baseTag = "<base href=\"quickdown-file://localhost\(path)\">"
        } else {
            baseTag = ""
        }

        // Detect which features are needed (lazy loading)
        let needsMermaid = markdown.contains("```mermaid")
        let needsMath = markdown.contains("$") || markdown.contains("\\[") || markdown.contains("\\(")

        // Always load core libraries
        let markedJS = loadResource("marked.min", ext: "js")
        let highlightJS = loadResource("highlight.min", ext: "js")
        let stylesCSS = loadResource("styles", ext: "css")
        let githubCSS = loadResource("github.min", ext: "css")
        let githubDarkCSS = loadResource("github-dark.min", ext: "css")

        // Conditionally load heavy libraries
        let mermaidJS = needsMermaid ? loadResource("mermaid.min", ext: "js") : ""
        let katexJS = needsMath ? loadResource("katex.min", ext: "js") : ""
        let katexCSS = needsMath ? loadResource("katex.min", ext: "css") : ""
        let autoRenderJS = needsMath ? loadResource("auto-render.min", ext: "js") : ""

        // Build conditional script/style blocks
        let mermaidStyle = needsMermaid ? """
            <style>
                .mermaid { text-align: center; background: transparent; }
                .mermaid svg { max-width: 100%; }
            </style>
            """ : ""

        let mermaidScript = needsMermaid ? "<script>\(mermaidJS)</script>" : ""
        let katexStyleTag = needsMath ? "<style>\(katexCSS)</style>" : ""
        let katexScript = needsMath ? "<script>\(katexJS)</script><script>\(autoRenderJS)</script>" : ""

        // Build conditional initialization code
        let mermaidInit = needsMermaid ? "mermaid.initialize({ startOnLoad: false, theme: 'default' });" : ""


        let mermaidPostProcess = needsMermaid ? """
                // Post-process: convert mermaid code blocks to mermaid divs
                document.querySelectorAll('code.language-mermaid').forEach(function(codeEl) {
                    var pre = codeEl.parentElement;
                    var div = document.createElement('div');
                    div.className = 'mermaid';
                    div.textContent = codeEl.textContent;
                    pre.parentElement.replaceChild(div, pre);
                });
                mermaid.run({ nodes: document.querySelectorAll('.mermaid') });
            """ : ""

        let mathRender = needsMath ? """
                renderMathInElement(document.getElementById('content'), {
                    delimiters: [
                        {left: '$$', right: '$$', display: true},
                        {left: '$', right: '$', display: false},
                        {left: '\\\\[', right: '\\\\]', display: true},
                        {left: '\\\\(', right: '\\\\)', display: false}
                    ],
                    throwOnError: false
                });
            """ : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            \(baseTag)
            <style>\(stylesCSS)</style>
            \(katexStyleTag)
            <style id="hl-light">\(githubCSS)</style>
            <style id="hl-dark">\(githubDarkCSS)</style>
            \(themeScript)
            \(mermaidStyle)
            <script>\(markedJS)</script>
            <script>\(highlightJS)</script>
            \(mermaidScript)
            \(katexScript)
        </head>
        <body\(fontScale != 1.0 ? " style=\"font-size: \(fontScale * 16)px\"" : "")>
            <div id="content"></div>
            <script>
                \(mermaidInit)

                marked.setOptions({
                    gfm: true,
                    breaks: true
                });

                // Strip YAML frontmatter (--- delimited block at top of file)
                const stripFrontmatter = (md) => {
                    if (!md.startsWith('---\\n') && !md.startsWith('---\\r')) return md;
                    const end = md.indexOf('\\n---', 3);
                    if (end === -1) return md;
                    return md.substring(end + 4).replace(/^\\r?\\n/, '');
                };

                // marked v15 treats ~single~ tildes as strikethrough, which is not standard GFM.
                // Preprocess: protect lone tildes outside code blocks/spans by replacing with HTML entity.
                const preprocessTildes = (md) => {
                    const parts = md.split(/(```[^]*?```|`[^`]*`)/);
                    return parts.map((part, i) => i % 2 === 1 ? part :
                        part.replace(/~~/g, 'QDDBLTILDE').replace(/~/g, '&#126;').replace(/QDDBLTILDE/g, '~~')
                    ).join('');
                };

                const markdown = preprocessTildes(stripFrontmatter(`\(escapedMarkdown)`));
                document.getElementById('content').innerHTML = marked.parse(markdown);

                // Apply syntax highlighting (marked v5+ removed the highlight option)
                document.querySelectorAll('pre code').forEach((block) => {
                    // Skip mermaid blocks
                    if (!block.classList.contains('language-mermaid')) {
                        hljs.highlightElement(block);
                    }
                });

                \(mermaidPostProcess)
                \(mathRender)

                // Add IDs to headings for TOC navigation
                document.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function(heading) {
                    var id = heading.textContent
                        .toLowerCase()
                        .replace(/\\s+/g, '-')
                        .replace(/[^a-z0-9-]/g, '');
                    heading.id = id;
                });

                // Make task list checkboxes interactive (visual toggle only)
                document.querySelectorAll('input[type="checkbox"]').forEach(function(cb) {
                    cb.removeAttribute('disabled');
                    cb.style.cursor = 'pointer';
                });

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

        // Open Recent submenu
        let recentMenuItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentFilesMenu = NSMenu(title: "Open Recent")
        recentMenuItem.submenu = recentFilesMenu
        fileMenu.addItem(recentMenuItem)
        updateRecentFilesMenu()

        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Export as PDF…", action: #selector(exportPDFAction(_:)), keyEquivalent: "e")
        fileMenu.addItem(withTitle: "Export as HTML…", action: #selector(exportHTMLAction(_:)), keyEquivalent: "E")
        fileMenu.addItem(NSMenuItem.separator())

        let shareItem = NSMenuItem(title: "Share…", action: #selector(shareDocument(_:)), keyEquivalent: "")
        shareItem.target = self
        fileMenu.addItem(shareItem)

        fileMenu.addItem(NSMenuItem.separator())
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeActiveTab(_:)), keyEquivalent: "w")
        closeTabItem.target = self
        fileMenu.addItem(closeTabItem)

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(selectNextTab(_:)), keyEquivalent: "}")
        nextTabItem.target = self
        nextTabItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(selectPreviousTab(_:)), keyEquivalent: "{")
        prevTabItem.target = self
        prevTabItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(prevTabItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())

        let findItem = NSMenuItem(title: "Find…", action: #selector(showSearch(_:)), keyEquivalent: "f")
        findItem.target = self
        editMenu.addItem(findItem)

        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(findNext(_:)), keyEquivalent: "g")
        findNextItem.target = self
        editMenu.addItem(findNextItem)

        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(findPrevious(_:)), keyEquivalent: "G")
        findPrevItem.target = self
        editMenu.addItem(findPrevItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        // Toggle Sidebar
        let sidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.target = self
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(sidebarItem)
        viewMenu.addItem(NSMenuItem.separator())

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

        viewMenu.addItem(NSMenuItem.separator())

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)

        let zoomResetItem = NSMenuItem(title: "Actual Size", action: #selector(zoomReset(_:)), keyEquivalent: "0")
        zoomResetItem.target = self
        viewMenu.addItem(zoomResetItem)

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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.openFiles(panel.urls)
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

        // Update window background to match theme
        updateWindowBackground()

        // Clear any stuck snapshot overlay (can happen after rapid multi-file open)
        if let overlay = snapshotOverlay {
            overlay.removeFromSuperview()
            snapshotOverlay = nil
        }

        guard let webView = webView, !webView.isHidden else {
            webView?.evaluateJavaScript("applyTheme('\(theme.rawValue.lowercased())')")
            return
        }

        webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
            guard let self = self, let webView = webView else { return }
            if let image = image {
                let overlay = NSImageView(frame: webView.bounds)
                overlay.image = image
                overlay.imageScaling = .scaleAxesIndependently
                overlay.autoresizingMask = [.width, .height]
                webView.addSubview(overlay)
                self.snapshotOverlay = overlay
                webView.evaluateJavaScript("applyTheme('\(theme.rawValue.lowercased())')") { [weak self, weak overlay] _, _ in
                    guard let overlay = overlay else { return }
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.25
                        overlay.animator().alphaValue = 0
                    }, completionHandler: { [weak self, weak overlay] in
                        overlay?.removeFromSuperview()
                        self?.snapshotOverlay = nil
                    })
                }
            } else {
                webView.evaluateJavaScript("applyTheme('\(theme.rawValue.lowercased())')")
            }
        }
    }

    /// Captures a snapshot of the current webview, pins it as an overlay,
    /// executes `action` (which should trigger a loadFileURL), then fades
    /// the overlay out in didFinish once new content is ready.
    @objc func zoomIn(_ sender: Any?) {
        fontScale += fontScaleStep
        if !openFiles.isEmpty { openFiles[activeFileIndex].fontScale = fontScale }
        applyFontScale()
    }

    @objc func zoomOut(_ sender: Any?) {
        fontScale -= fontScaleStep
        if !openFiles.isEmpty { openFiles[activeFileIndex].fontScale = fontScale }
        applyFontScale()
    }

    @objc func zoomReset(_ sender: Any?) {
        fontScale = 1.0
        if !openFiles.isEmpty { openFiles[activeFileIndex].fontScale = fontScale }
        applyFontScale()
    }

    private func applyFontScale() {
        webView?.evaluateJavaScript("document.body.style.fontSize = '\(fontScale * 16)px'")
    }

    private func crossfadeTransition(then action: @escaping () -> Void) {
        guard let webView = webView, !webView.isHidden, snapshotOverlay == nil else {
            // No webview, not visible, or transition already in progress — skip
            action()
            return
        }

        webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
            guard let self = self, let webView = webView, let image = image else {
                action()
                return
            }

            let overlay = NSImageView(frame: webView.bounds)
            overlay.image = image
            overlay.imageScaling = .scaleAxesIndependently
            overlay.autoresizingMask = [.width, .height]
            webView.addSubview(overlay)
            self.snapshotOverlay = overlay

            action()
        }
    }

    private func updateWindowBackground() {
        if currentTheme == .system {
            window.backgroundColor = .windowBackgroundColor
            mainContentView.wantsLayer = false
            mainContentView.layer?.backgroundColor = nil
            searchBar.wantsLayer = false
            searchBar.layer?.backgroundColor = nil
            dropZoneLabel.textColor = .secondaryLabelColor
            wordCountLabel.textColor = .tertiaryLabelColor
            themeLabelColor = nil
            tocTableView.reloadData()
            tabBarView.pillBackgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.3)
            tabBarView.activeSegmentColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            tabBarView.textColor = .labelColor
            tabBarView.separatorColor = .separatorColor
            return
        }

        let backgroundColor: NSColor
        let labelColor: NSColor
        switch currentTheme {
        case .light:
            backgroundColor = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            labelColor = NSColor(white: 0.5, alpha: 1.0)
        case .dark:
            backgroundColor = NSColor(red: 0.051, green: 0.067, blue: 0.09, alpha: 1.0)  // #0d1117
            labelColor = NSColor(white: 0.7, alpha: 1.0)
        case .sepia:
            backgroundColor = NSColor(red: 0.957, green: 0.925, blue: 0.847, alpha: 1.0)  // #f4ecd8
            labelColor = NSColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1.0)
        case .solarizedLight:
            backgroundColor = NSColor(red: 0.992, green: 0.965, blue: 0.890, alpha: 1.0)  // #fdf6e3
            labelColor = NSColor(red: 0.576, green: 0.631, blue: 0.631, alpha: 1.0)  // #93a1a1
        case .solarizedDark:
            backgroundColor = NSColor(red: 0.0, green: 0.169, blue: 0.212, alpha: 1.0)  // #002b36
            labelColor = NSColor(red: 0.514, green: 0.580, blue: 0.588, alpha: 1.0)  // #839496 (base0)
        case .nord:
            backgroundColor = NSColor(red: 0.180, green: 0.204, blue: 0.251, alpha: 1.0)  // #2e3440
            labelColor = NSColor(red: 0.616, green: 0.663, blue: 0.749, alpha: 1.0)  // #9da9bf (snow storm 0 dimmed)
        case .system:
            return  // already handled above
        }

        window.backgroundColor = backgroundColor
        mainContentView.wantsLayer = true
        mainContentView.layer?.backgroundColor = backgroundColor.cgColor
        searchBar.wantsLayer = true
        searchBar.layer?.backgroundColor = backgroundColor.cgColor
        dropZoneLabel.textColor = labelColor
        wordCountLabel.textColor = labelColor
        themeLabelColor = labelColor
        tocTableView.reloadData()
        tabBarView.pillBackgroundColor = backgroundColor.blended(withFraction: 0.1, of: labelColor) ?? backgroundColor
        tabBarView.activeSegmentColor = backgroundColor.blended(withFraction: 0.2, of: labelColor) ?? backgroundColor
        tabBarView.textColor = labelColor
        tabBarView.separatorColor = labelColor.withAlphaComponent(0.2)
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportPDFAction(_:)) ||
           menuItem.action == #selector(exportHTMLAction(_:)) ||
           menuItem.action == #selector(shareDocument(_:)) ||
           menuItem.action == #selector(zoomIn(_:)) ||
           menuItem.action == #selector(zoomOut(_:)) ||
           menuItem.action == #selector(zoomReset(_:)) {
            return currentFileURL != nil
        }
        if menuItem.action == #selector(selectNextTab(_:)) ||
           menuItem.action == #selector(selectPreviousTab(_:)) {
            return openFiles.count > 1
        }
        if menuItem.action == #selector(closeActiveTab(_:)) {
            menuItem.title = openFiles.isEmpty ? "Close Window" : "Close Tab"
            return true
        }
        return true
    }

    // MARK: - Open from Finder / URL Scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        var fileURLs: [URL] = []
        for url in urls {
            if url.scheme == "quickdown" {
                if isSetupComplete {
                    handleQuickDownURL(url)
                } else {
                    pendingFileURLs.append(url)
                }
            } else if isSetupComplete {
                fileURLs.append(url)
            } else {
                pendingFileURLs.append(url)
            }
        }
        if !fileURLs.isEmpty {
            openFiles(fileURLs)
        }
    }


    // MARK: - URL Scheme

    private func handleQuickDownURL(_ url: URL) {
        // Support formats:
        // quickdown:///path/to/file.md (path in URL path)
        // quickdown://open?file=/path/to/file.md (path in query param)

        var filePath: String?

        // Check for query parameter first
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            filePath = queryItems.first(where: { $0.name == "file" })?.value
        }

        // Fall back to URL path
        if filePath == nil && !url.path.isEmpty {
            filePath = url.path
        }

        guard let path = filePath, !path.isEmpty else {
            showError("Invalid URL: no file path specified")
            return
        }

        let fileURL = URL(fileURLWithPath: path)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            openFile(fileURL)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            showError("File not found: \(path)")
        }
    }

    // MARK: - Services Menu

    @objc func previewMarkdownService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "Could not read text from pasteboard" as NSString
            return
        }

        // Create a temporary markdown file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent("Preview-\(UUID().uuidString.prefix(8)).md")

        do {
            try text.write(to: tempFileURL, atomically: true, encoding: .utf8)

            // Defer if setup not complete (app launched via service)
            if isSetupComplete {
                openFile(tempFileURL)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                pendingFileURLs.append(tempFileURL)
            }
        } catch let writeError {
            error.pointee = "Failed to create preview: \(writeError.localizedDescription)" as NSString
        }
    }

    private func updateTabBarVisibility() {
        let shouldShow = openFiles.count > 1
        tabBarView.isHidden = !shouldShow
        tabBarHeightConstraint.constant = shouldShow ? 34 : 0

        if shouldShow {
            tabBarView.setTabs(openFiles, activeIndex: activeFileIndex)
            tabBarView.scrollToActiveTab()
        }
    }

    /// Captures the current tab's transient state (scroll position) before switching away.
    private func saveCurrentTabState(completion: @escaping () -> Void) {
        guard !openFiles.isEmpty else {
            completion()
            return
        }

        webView?.evaluateJavaScript("window.scrollY") { [weak self] scrollY, _ in
            guard let self = self, !self.openFiles.isEmpty else {
                completion()
                return
            }
            if let y = scrollY as? Double {
                self.openFiles[self.activeFileIndex].scrollY = y
            }
            completion()
        }
    }

    /// Loads a tab's content into the WebView and restores its state.
    private func loadTab(at index: Int) {
        guard index >= 0 && index < openFiles.count else { return }

        activeFileIndex = index
        let file = openFiles[index]

        window.title = "QuickDown — \(file.url.lastPathComponent)"
        window.representedURL = file.url

        // Restore per-tab sidebar state
        isSidebarVisible = file.sidebarVisible
        UserDefaults.standard.set(isSidebarVisible, forKey: sidebarVisibleKey)
        tocScrollView.isHidden = !isSidebarVisible
        splitView.setPosition(isSidebarVisible ? 200 : 0, ofDividerAt: 0)

        // Restore per-tab font scale
        fontScale = file.fontScale

        // Stop watching previous file, start watching this one
        stopWatchingFile()
        startWatchingFile(file.url)

        do {
            let content = try readFileWithFallbackEncoding(url: file.url)
            openFiles[index].contentHash = content.hashValue

            tocItems = parseTOC(from: content)
            tocTableView.reloadData()
            updateWordCount(content)

            // Try to get directory access for relative path resolution
            currentAccessibleDirectory = accessibleParentDirectory(for: file.url, promptIfNeeded: contentHasRelativePaths(content))
            let html = generateHTML(markdown: content, baseDirectoryURL: currentAccessibleDirectory)
            pendingScrollRestoreY = file.scrollY
            try loadHTMLInWebView(html, allowingAccessTo: currentAccessibleDirectory)
        } catch {
            showError("Failed to load file: \(error.localizedDescription)")
        }

        // Update tab bar
        updateTabBarVisibility()
    }

    private func switchToTab(_ index: Int) {
        guard index != activeFileIndex, index >= 0, index < openFiles.count else { return }

        saveCurrentTabState { [weak self] in
            self?.loadTab(at: index)
        }
    }

    private func closeTab(at index: Int) {
        guard index >= 0 && index < openFiles.count else { return }

        openFiles.remove(at: index)

        if openFiles.isEmpty {
            // No more tabs — return to drop zone
            stopWatchingFile()
            webView?.isHidden = true
            dropZoneLabel.isHidden = false
            window.title = "QuickDown"
            window.representedURL = nil
            wordCountLabel.isHidden = true
            tocItems = []
            tocTableView.reloadData()
            activeFileIndex = 0
            updateTabBarVisibility()
            return
        }

        // Adjust active index
        if activeFileIndex >= openFiles.count {
            activeFileIndex = openFiles.count - 1
        } else if index < activeFileIndex {
            activeFileIndex -= 1
        }

        loadTab(at: activeFileIndex)
    }

    @objc func closeActiveTab(_ sender: Any?) {
        if openFiles.isEmpty {
            window.performClose(sender)
        } else {
            closeTab(at: activeFileIndex)
        }
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard openFiles.count > 1 else { return }
        let next = (activeFileIndex + 1) % openFiles.count
        switchToTab(next)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard openFiles.count > 1 else { return }
        let prev = (activeFileIndex - 1 + openFiles.count) % openFiles.count
        switchToTab(prev)
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension AppDelegate: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tocItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = tocItems[row]

        let cell = NSTextField(labelWithString: item.title)
        cell.lineBreakMode = .byTruncatingTail
        cell.font = NSFont.systemFont(ofSize: 12)
        if let color = themeLabelColor {
            cell.textColor = color
        }

        // Indent based on heading level
        let indent = CGFloat((item.level - 1) * 12)
        cell.frame.origin.x = indent

        let container = NSView()
        container.addSubview(cell)
        cell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8 + indent),
            cell.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            cell.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    // MARK: - Word Count

    private func updateWordCount(_ markdown: String) {
        // Strip frontmatter, code blocks, and HTML for a clean count
        var text = markdown
        // Strip YAML frontmatter
        if text.hasPrefix("---\n") || text.hasPrefix("---\r") {
            if let endRange = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
                text = String(text[endRange.upperBound...])
            }
        }
        // Strip code blocks
        while let start = text.range(of: "```") {
            if let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                break
            }
        }

        let charCount = text.count
        let words = text.split { $0.isWhitespace || $0.isNewline }
        let wordCount = words.count

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let wordStr = formatter.string(from: NSNumber(value: wordCount)) ?? "\(wordCount)"
        let charStr = formatter.string(from: NSNumber(value: charCount)) ?? "\(charCount)"

        wordCountLabel.stringValue = "\(wordStr) words  ·  \(charStr) characters"
        wordCountLabel.isHidden = false
    }
}

// MARK: - WKNavigationDelegate

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              let scheme = url.scheme else {
            decisionHandler(.allow)
            return
        }

        // External links — open in default browser
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // Relative or local file links (.md) — open in QuickDown
        // Handles both file:// and quickdown-file:// schemes
        if scheme == "file" || scheme == "quickdown-file" {
            let filePath = url.path
            let fileURL = URL(fileURLWithPath: filePath)
            let ext = fileURL.pathExtension.lowercased()
            let markdownExtensions = ["md", "markdown", "mdown", "mkdn", "mkd"]
            if markdownExtensions.contains(ext) {
                if FileManager.default.fileExists(atPath: filePath) {
                    openFile(fileURL.standardized)
                    decisionHandler(.cancel)
                    return
                }
            }

            // Non-.md file links — let the system handle them
            NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let startFade = { [weak self] in
            guard let self = self, let overlay = self.snapshotOverlay else { return }
            self.snapshotOverlay = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                overlay.animator().alphaValue = 0
            }) {
                overlay.removeFromSuperview()
            }
        }

        if let scrollY = pendingScrollRestoreY {
            pendingScrollRestoreY = nil
            // Scroll first, then fade — ensures content is at correct position before reveal
            webView.evaluateJavaScript("window.scrollTo(0, \(scrollY))") { _, _ in
                DispatchQueue.main.async {
                    startFade()
                }
            }
        } else {
            startFade()
        }
    }
}

// MARK: - NSSplitViewDelegate

extension AppDelegate: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 120  // Minimum sidebar width
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return min(300, splitView.bounds.width * 0.35)  // Max 300px or 35% of window
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return subview == tocScrollView
    }
}

// MARK: - PillTabBarDelegate

extension AppDelegate: PillTabBarDelegate {
    func tabBar(_ tabBar: PillTabBarView, didSelectTabAt index: Int) {
        switchToTab(index)
    }

    func tabBar(_ tabBar: PillTabBarView, didCloseTabAt index: Int) {
        closeTab(at: index)
    }

    func tabBar(_ tabBar: PillTabBarView, didClickActiveTabAt index: Int) {
        // Raw mode toggle — implemented in feature/raw-mode branch
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
