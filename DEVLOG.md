# QuickDown Development Log

## v0.4.0 — CSS Variables Theme Refactor

- Theme changes are now instant CSS variable updates — no page reload, no scroll loss
- Smooth crossfade animation on theme switch via snapshot overlay (same as live reload)
- Scroll position always preserved on theme change (no reload = no scroll loss)
- Deleted `generateThemeStyles()` — theme colors now live entirely in `styles.css`
- Adding a new theme now requires only a CSS block + one enum case

## v0.3.0 — Smooth Transitions

- Smooth 300ms crossfade transition on theme changes (no more hard cut)
- Smooth 300ms crossfade transition on live reloads
- Fixed live reload silently dying after first atomic save (editors like VS Code, Zed)
- Fixed scroll position resetting on theme change and live reload
- Fixed Mermaid diagrams and KaTeX math not rendering in QuickLook extension

## What is QuickDown?
A lightweight macOS markdown previewer with QuickLook integration. Focused on being fast and simple - a viewer, not an editor.

---

## Version History

### v0.1.1
- Basic markdown preview with WKWebView
- Drag-and-drop file opening
- GitHub-flavored markdown via marked.js
- Syntax highlighting via highlight.js
- PDF and HTML export
- QuickLook extension (MarkdownPreview.appex)

### v0.1.2
- Live reload (file watching)
- Recent files menu with keyboard shortcuts (Cmd+Shift+1-9)
- Custom themes (System, Light, Dark, Sepia)
- HTML export hotfix (portable, no JS required)

### v0.1.3
- Mermaid diagram rendering
- KaTeX math rendering (inline `$...$` and display `$$...$$`)
- Table of Contents sidebar (Cmd+Ctrl+S to toggle)
- In-document search (Cmd+F) with scroll markers
- Escape key dismisses search
- Security-scoped bookmarks for recent files (sandbox fix)
- TOC column auto-resizing fix

### v0.1.4 (current)
- **Share Menu** - File → Share to AirDrop rendered HTML, copy as rich text, etc.
- **Services Menu** - Right-click text → Services → Preview as Markdown (needs testing)
- **URL Scheme** - `quickdown:///path/to/file.md` or `quickdown://open?file=...` for automation

---

## Roadmap

### v0.2.0 (planned - performance)
- **Benchmarking** - Compare render speed against MacDown, Marked 2, Typora, iA Writer
- **Profiling** - Identify bottlenecks in render pipeline
- **Lazy loading** - Defer heavy libraries (mermaid.min.js is 3.2 MB) until needed
- **Large file optimization** - Progressive rendering, chunking for huge documents
- **Caching** - Cache rendered HTML for unchanged content
- **UI responsiveness** - Fix any hangs or stutters discovered during testing

### v2.0 (future)
- **Editor Mode** - Split view edit/preview, syntax highlighting, save functionality
- This is a significant shift from viewer to editor, intentionally deferred

---

## Design Decisions

### Why no editor in v0.1.x?
Editor mode would add 500-800 lines and change the app's identity. QuickDown's value is being lightweight and focused. Editors like Typora, MacDown, Obsidian exist. Editing belongs in v2.0 as a deliberate expansion, not feature creep.

### Share extension: two directions
1. **Receiving** - Other apps share markdown text TO QuickDown for preview. Useful for AI-generated markdown, documentation snippets, etc.
2. **Sending** - QuickDown shares rendered HTML OUT to other apps. Useful for AirDrop to phone, paste into emails as rich text, etc.

Both are valuable. "Sending" may be higher priority since it completes the workflow: preview → use.

### Why security-scoped bookmarks?
Sandboxed apps lose file permissions after restart. Storing paths as strings doesn't preserve access. Bookmarks retain permission across launches.

---

## Technical Reference

### Entitlements (CRITICAL - don't lose this info)

**Main App (QuickDown.entitlements):**
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

**QuickLook Extension (MarkdownPreview.entitlements):**
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

**Why these specific entitlements for QuickLook:**
1. **DO NOT use `com.apple.security.inherit`** - QuickLook extensions are launched by `quicklookd` which is NOT sandboxed. There's nothing to inherit, causing crash: "Process is not in an inherited sandbox"
2. **MUST have `network.client`** - WKWebView spawns separate WebContent and NetworkProcess processes that need to communicate via IPC. Without this, WebContent crashes with "Application does not have permission to communicate with network resources" even when loading local HTML.
3. **`files.user-selected.read-only`** - Allows reading the file being previewed.

### Services Menu

Services require:
1. `NSServices` array in Info.plist with `NSMenuItem`, `NSMessage`, `NSPortName`, `NSSendTypes`
2. `NSApp.servicesProvider = self` in `applicationDidFinishLaunching`
3. Method with signature: `@objc func methodName(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)`
4. After install, flush services cache: `/System/Library/CoreServices/pbs -flush && /System/Library/CoreServices/pbs -update`

### Build & Release Checklist

1. Archive: `xcodebuild -scheme QuickDown -configuration Release -archivePath build/QuickDown.xcarchive archive`
2. Export with Developer ID: `xcodebuild -exportArchive -archivePath build/QuickDown.xcarchive -exportPath build/Export -exportOptionsPlist build/ExportOptions.plist`
3. Notarize: `xcrun notarytool submit QuickDown.zip --keychain-profile "notarytool-profile" --wait`
4. Staple: `xcrun stapler staple QuickDown.app`
5. Verify extension: `pluginkit -m -v -i com.tennyson.QuickDown.MarkdownPreview`
6. Verify entitlements: `codesign -d --entitlements - /Applications/QuickDown.app/Contents/PlugIns/MarkdownPreview.appex`

---

## Current Stats
- Source: ~1,300 lines (AppDelegate.swift)
- Resources: 3.7 MB (mermaid.min.js is 3.2 MB)
- Built app: ~8 MB

---

## Research TODO (for v0.2.0)
- Search "QuickLook markdown" and find all alternatives
- Identify free options to benchmark against
- Identify paid options and analyze what premium features they offer that QuickDown doesn't
- Known competitors: MacDown, Marked 2, Typora, iA Writer
- Question to answer: What are paid apps offering that's worth the money?

---

## Future Ideas (unprioritized)
- Printing support
- Multiple windows
- Outline/document map
- Word count
- Custom CSS injection
- Vim keybindings for navigation
- Fountain screenplay format support
