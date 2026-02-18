# Smooth Transitions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 300ms crossfade transitions to theme changes and live reloads using WKWebView snapshots as overlays.

**Architecture:** Before any reload, capture a snapshot of the current webview and pin it as an NSImageView overlay. Trigger the reload underneath. In `didFinish`, restore scroll position then fade the overlay alpha 1→0 over 300ms and remove it.

**Tech Stack:** Swift, AppKit (NSAnimationContext, NSImageView), WebKit (WKWebView.takeSnapshot, WKNavigationDelegate)

---

### Task 1: Create branch and add `snapshotOverlay` property

**Files:**
- Modify: `QuickDown/AppDelegate.swift` (property declarations, ~line 48)

**Step 1: Create the branch**

```bash
git checkout -b feat/smooth-transitions
```

**Step 2: Add the property**

In `AppDelegate`, near `private var pendingScrollRestoreY: Double?`, add:

```swift
private var snapshotOverlay: NSImageView?
```

**Step 3: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "feat(ui): add snapshotOverlay property for crossfade transitions"
```

---

### Task 2: Implement `crossfadeTransition(then:)` helper

**Files:**
- Modify: `QuickDown/AppDelegate.swift` — add private method near `updateWindowBackground()`

**Step 1: Add the helper method**

Find `private func updateWindowBackground()` and add this immediately before it:

```swift
/// Captures a snapshot of the current webview, pins it as an overlay,
/// executes `action` (which should trigger a loadFileURL), then fades
/// the overlay out in didFinish once new content is ready.
private func crossfadeTransition(then action: @escaping () -> Void) {
    guard let webView = webView, !webView.isHidden, snapshotOverlay == nil else {
        // No webview, not visible, or transition already in progress — skip
        action()
        return
    }

    webView.takeSnapshot(with: nil) { [weak self] image, _ in
        guard let self = self, let image = image else {
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
```

**Step 2: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "feat(ui): add crossfadeTransition helper using WKWebView snapshot"
```

---

### Task 3: Update `didFinish` to fade out the overlay

**Files:**
- Modify: `QuickDown/AppDelegate.swift` — `WKNavigationDelegate` extension, `webView(_:didFinish:)`

**Step 1: Replace the current `didFinish` implementation**

Find the `WKNavigationDelegate` extension (near bottom of file):

```swift
extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let scrollY = pendingScrollRestoreY {
            webView.evaluateJavaScript("window.scrollTo(0, \(scrollY))")
            pendingScrollRestoreY = nil
        }
    }
}
```

Replace with:

```swift
extension AppDelegate: WKNavigationDelegate {
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
                startFade()
            }
        } else {
            startFade()
        }
    }
}
```

**Step 2: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "feat(ui): fade out snapshot overlay in didFinish after scroll restore"
```

---

### Task 4: Wire `selectTheme` to use `crossfadeTransition`

**Files:**
- Modify: `QuickDown/AppDelegate.swift` — `selectTheme(_:)` method

**Step 1: Find the current reload block in `selectTheme`**

It looks like:

```swift
webView?.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
    guard let self = self else { return }
    self.pendingScrollRestoreY = result as? Double

    if let url = self.currentFileURL {
        do {
            let content = try self.readFileWithFallbackEncoding(url: url)
            let baseDir = url.deletingLastPathComponent()
            let processedContent = self.resolveRelativePaths(in: content, baseDirectory: baseDir)
            let html = self.generateHTML(markdown: processedContent)

            let tempHTMLURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("quickdown-preview.html")
            try html.write(to: tempHTMLURL, atomically: true, encoding: .utf8)
            self.webView?.loadFileURL(tempHTMLURL, allowingReadAccessTo: baseDir)
        } catch {
            // Ignore reload errors
        }
    }
}
```

**Step 2: Wrap `loadFileURL` with `crossfadeTransition`**

Replace `self.webView?.loadFileURL(tempHTMLURL, allowingReadAccessTo: baseDir)` so the full block becomes:

```swift
webView?.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
    guard let self = self else { return }
    self.pendingScrollRestoreY = result as? Double

    if let url = self.currentFileURL {
        self.crossfadeTransition {
            do {
                let content = try self.readFileWithFallbackEncoding(url: url)
                let baseDir = url.deletingLastPathComponent()
                let processedContent = self.resolveRelativePaths(in: content, baseDirectory: baseDir)
                let html = self.generateHTML(markdown: processedContent)

                let tempHTMLURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("quickdown-preview.html")
                try html.write(to: tempHTMLURL, atomically: true, encoding: .utf8)
                self.webView?.loadFileURL(tempHTMLURL, allowingReadAccessTo: baseDir)
            } catch {
                // Ignore reload errors
            }
        }
    }
}
```

**Step 3: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED.

**Step 4: Manual test — theme transition**

- Copy build to /Applications, launch app, open `demo.md`
- Scroll halfway down
- Switch themes via menu (System → Sepia → Dark → Light)
- Expected: smooth 300ms crossfade on each switch, scroll position preserved

**Step 5: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "feat(ui): crossfade theme changes via snapshot overlay"
```

---

### Task 5: Wire `reloadCurrentFile` to use `crossfadeTransition`

**Files:**
- Modify: `QuickDown/AppDelegate.swift` — `reloadCurrentFile()` method

**Step 1: Find the current `loadFileURL` call in `reloadCurrentFile`**

Near the end of the `evaluateJavaScript` completion handler, it looks like:

```swift
self.pendingScrollRestoreY = scrollY as? Double
self.webView?.loadFileURL(tempHTMLURL, allowingReadAccessTo: baseDir)
```

**Step 2: Wrap `loadFileURL` with `crossfadeTransition`**

Replace those two lines with:

```swift
self.pendingScrollRestoreY = scrollY as? Double
self.crossfadeTransition {
    self.webView?.loadFileURL(tempHTMLURL, allowingReadAccessTo: baseDir)
}
```

Note: HTML generation and `html.write(to:)` happen BEFORE `crossfadeTransition` is called, which is correct — the new HTML is on disk before we take the snapshot.

**Step 3: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED.

**Step 4: Manual test — live reload transition**

- Copy build to /Applications, launch app, open `demo.md`
- Scroll to the Math/LaTeX section
- In a text editor, change "The quadratic formula:" to "The classic quadratic formula:" and save
- Expected: smooth 300ms crossfade as content updates, scroll position preserved
- Undo the change and save again — expected: another smooth crossfade

**Step 5: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "feat(ui): crossfade live reloads via snapshot overlay"
```

---

### Task 6: Final polish, version bump, merge

**Files:**
- Modify: `QuickDown/Info.plist` — version bump to 0.3.0
- Modify: `DEVLOG.md` — add 0.3.0 section

**Step 1: Bump version in Info.plist**

Change both `CFBundleShortVersionString` and `CFBundleVersion` from `0.2.0` to `0.3.0`.

**Step 2: Add DEVLOG entry**

Add a new section at the top of `DEVLOG.md`:

```markdown
## v0.3.0 — Smooth Transitions

- Smooth 300ms crossfade transition on theme changes (no more hard cut)
- Smooth 300ms crossfade transition on live reloads
- Fixed live reload silently dying after first atomic save (editors like VS Code, Zed)
- Fixed scroll position resetting on theme change and live reload
- Fixed Mermaid diagrams and KaTeX math not rendering in QuickLook extension
```

**Step 3: Commit version bump**

```bash
git add QuickDown/Info.plist DEVLOG.md
git commit -m "chore: bump version to 0.3.0"
```

**Step 4: Merge to main**

```bash
git checkout main
git merge feat/smooth-transitions
git push origin main
```
