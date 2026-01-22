import Cocoa
import WebKit

enum Theme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case sepia = "Sepia"
}

struct TOCItem {
    let level: Int
    let title: String
    let id: String
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSSearchFieldDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    var dropZoneLabel: NSTextField!
    var currentFileURL: URL?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var reloadDebounceWorkItem: DispatchWorkItem?
    private var lastContentHash: Int = 0

    private var recentFilesMenu: NSMenu!
    private let recentFilesKey = "RecentFiles"
    private let maxRecentFiles = 10

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
    private var isSearchVisible = false

    // Track setup state for deferred file opens
    private var isSetupComplete = false
    private var pendingFileURL: URL?

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

        // Register as Services provider
        NSApp.servicesProvider = self

        // Mark setup complete and open any pending file
        isSetupComplete = true
        if let pendingURL = pendingFileURL {
            pendingFileURL = nil
            openFile(pendingURL)
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
        splitView.autoresizingMask = [.width, .height]

        // Create TOC sidebar
        setupTOCSidebar()

        // Create drop view for main content
        let dropView = DropView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
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

        // Add views to split view
        splitView.addArrangedSubview(tocScrollView)
        splitView.addArrangedSubview(dropView)

        // Create container view for search bar + split view
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        containerView.autoresizingMask = [.width, .height]

        // Setup search bar
        setupSearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(searchBar)

        splitView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(splitView)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: containerView.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 32),

            splitView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        // Set initial sidebar state
        isSidebarVisible = UserDefaults.standard.bool(forKey: sidebarVisibleKey)
        splitView.setPosition(isSidebarVisible ? 200 : 0, ofDividerAt: 0)
        tocScrollView.isHidden = !isSidebarVisible

        // Initially hide search bar
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
        webView.evaluateJavaScript("document.getElementById('\(item.id)')?.scrollIntoView({behavior: 'smooth'})")
    }

    @objc func toggleSidebar(_ sender: Any?) {
        isSidebarVisible.toggle()
        UserDefaults.standard.set(isSidebarVisible, forKey: sidebarVisibleKey)

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
        window.makeFirstResponder(searchField)
    }

    @objc func hideSearch(_ sender: Any?) {
        isSearchVisible = false
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
        webView.evaluateJavaScript("window.findNext && window.findNext()") { [weak self] result, _ in
            if let info = result as? [String: Int],
               let current = info["current"],
               let total = info["total"] {
                self?.searchResultLabel.stringValue = "\(current) of \(total)"
            }
        }
    }

    @objc func findPrevious(_ sender: Any?) {
        webView.evaluateJavaScript("window.findPrevious && window.findPrevious()") { [weak self] result, _ in
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

        webView.evaluateJavaScript(js) { [weak self] result, error in
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
        webView.evaluateJavaScript("""
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

    func openFile(_ url: URL) {
        // Stop watching the previous file
        stopWatchingFile()

        currentFileURL = url
        window.title = "QuickDown — \(url.lastPathComponent)"

        do {
            let content = try readFileWithFallbackEncoding(url: url)

            // Store content hash for change detection
            lastContentHash = content.hashValue

            // Parse TOC from markdown
            tocItems = parseTOC(from: content)
            tocTableView.reloadData()

            let html = generateHTML(markdown: content)
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
            webView.isHidden = false
            dropZoneLabel.isHidden = true

            // Start watching for changes
            startWatchingFile(url)

            // Add to recent files
            addToRecentFiles(url)
        } catch {
            showError("Failed to open file: \(error.localizedDescription)")
        }
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
            // Debounce: cancel pending reload and schedule a new one
            self?.reloadDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.reloadCurrentFile()
            }
            self?.reloadDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
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

                // Skip re-render if content hasn't changed
                let contentHash = content.hashValue
                if contentHash == self.lastContentHash {
                    return
                }
                self.lastContentHash = contentHash

                // Update TOC
                self.tocItems = self.parseTOC(from: content)
                self.tocTableView.reloadData()

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
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] (_, _) in
            guard let self = self else { return }

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

        // Extract pre-rendered HTML from WKWebView (no JS needed in output)
        webView.evaluateJavaScript("document.getElementById('content').innerHTML") { [weak self] result, error in
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
        webView.evaluateJavaScript("document.getElementById('content').innerHTML") { [weak self] result, error in
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

        let themeStyles = generateThemeStyles(
            githubCSS: githubCSS,
            githubDarkCSS: githubDarkCSS
        )

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>\(stylesCSS)</style>
            \(themeStyles)
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

    private func generateHTML(markdown: String) -> String {
        let escapedMarkdown = escapeForJavaScript(markdown)

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

        let themeStyles = generateThemeStyles(
            githubCSS: githubCSS,
            githubDarkCSS: githubDarkCSS
        )

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

        let mermaidHighlightCheck = needsMermaid ? "if (lang === 'mermaid') return code;" : ""

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
            <style>\(stylesCSS)</style>
            \(katexStyleTag)
            \(themeStyles)
            \(mermaidStyle)
            <script>\(markedJS)</script>
            <script>\(highlightJS)</script>
            \(mermaidScript)
            \(katexScript)
        </head>
        <body>
            <div id="content"></div>
            <script>
                \(mermaidInit)

                marked.setOptions({
                    highlight: function(code, lang) {
                        \(mermaidHighlightCheck)
                        if (lang && hljs.getLanguage(lang)) {
                            try {
                                return hljs.highlight(code, { language: lang }).value;
                            } catch (e) {}
                        }
                        return hljs.highlightAuto(code).value;
                    },
                    gfm: true,
                    breaks: true
                });

                const markdown = `\(escapedMarkdown)`;
                document.getElementById('content').innerHTML = marked.parse(markdown);

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
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
           menuItem.action == #selector(exportHTMLAction(_:)) ||
           menuItem.action == #selector(shareDocument(_:)) {
            return currentFileURL != nil
        }
        return true
    }

    // MARK: - Open from Finder / URL Scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }

        // Handle quickdown:// URL scheme
        if url.scheme == "quickdown" {
            if isSetupComplete {
                handleQuickDownURL(url)
            } else {
                pendingFileURL = url
            }
            return
        }

        // Handle file URLs - defer if setup not complete
        if isSetupComplete {
            openFile(url)
        } else {
            pendingFileURL = url
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
                pendingFileURL = tempFileURL
            }
        } catch let writeError {
            error.pointee = "Failed to create preview: \(writeError.localizedDescription)" as NSString
        }
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
