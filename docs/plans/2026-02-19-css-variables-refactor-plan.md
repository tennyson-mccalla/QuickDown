# CSS Variables Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the baked-in `!important` CSS theme injection with a `data-theme` attribute + CSS variables approach so theme changes require zero page reload.

**Architecture:** `styles.css` gains `[data-theme="light/dark/sepia"]` variable override blocks and CSS transitions. `generateHTML` embeds both highlight CSS files with IDs and an `applyTheme(theme)` JS function. `selectTheme` drops all scroll/reload/crossfade logic and just calls `evaluateJavaScript("applyTheme('dark')")`.

**Tech Stack:** Swift, AppKit, WKWebView, CSS custom properties, CSS attribute selectors

---

### Task 1: Create branch and add theme CSS to `styles.css`

**Files:**
- Modify: `MarkdownPreview/Resources/styles.css`

**Step 1: Create the branch**

```bash
git checkout -b feat/css-variables-refactor
```

**Step 2: Add theme variable overrides and transitions**

Open `MarkdownPreview/Resources/styles.css`. The file currently ends at line 239 with the closing `}` of `@media print`. Append the following **before** the `/* Print styles */` comment (i.e. insert between line 190 and line 191):

```css
/* Explicit theme overrides via data-theme attribute on <html>.
   System theme uses no attribute — the @media block above handles it. */
[data-theme="light"] {
    color-scheme: light;
    --bg-color: #ffffff;
    --text-color: #24292e;
    --link-color: #0366d6;
    --code-bg: #f6f8fa;
    --border-color: #e1e4e8;
    --blockquote-color: #6a737d;
    --table-border: #dfe2e5;
}

[data-theme="dark"] {
    color-scheme: dark;
    --bg-color: #0d1117;
    --text-color: #c9d1d9;
    --link-color: #58a6ff;
    --code-bg: #161b22;
    --border-color: #30363d;
    --blockquote-color: #8b949e;
    --table-border: #30363d;
}

[data-theme="sepia"] {
    color-scheme: light;
    --bg-color: #f4ecd8;
    --text-color: #5b4636;
    --link-color: #8b4513;
    --code-bg: #e8dcc8;
    --border-color: #d4c4a8;
    --blockquote-color: #7a6048;
    --table-border: #d4c4a8;
}

/* Smooth color transitions when switching themes */
body, pre, code, blockquote, table, th, td, a,
h1, h2, h3, h4, h5, h6 {
    transition: background-color 200ms ease, color 200ms ease, border-color 200ms ease;
}
```

Note: `[data-theme="..."]` has equal specificity to `:root` (both are 0-1-0), but because it appears **after** the media query block in the file, it wins when `data-theme` is set. When `data-theme` is absent (system theme), neither matches and the existing `@media (prefers-color-scheme: dark)` rule applies.

**Step 3: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED. The CSS file change has no Swift compilation impact; this just verifies nothing else broke.

**Step 4: Commit**

```bash
git add MarkdownPreview/Resources/styles.css
git commit -m "feat(ui): add data-theme CSS variable overrides and transitions to styles.css"
```

---

### Task 2: Update `generateHTML` — replace `generateThemeStyles` with highlight CSS embeds + `applyTheme` script

**Files:**
- Modify: `QuickDown/AppDelegate.swift` — `generateHTML(_:)` method (~lines 1019–1134)

**Step 1: Remove the `themeStyles` variable**

Find this block (~lines 1039–1042):

```swift
        let themeStyles = generateThemeStyles(
            githubCSS: githubCSS,
            githubDarkCSS: githubDarkCSS
        )
```

Delete it entirely.

**Step 2: Replace `\(themeStyles)` in the HTML template**

In the same method, find `\(themeStyles)` inside the `return """..."""` block (~line 1091):

```swift
            \(katexStyleTag)
            \(themeStyles)
            \(mermaidStyle)
```

Replace with:

```swift
            \(katexStyleTag)
            <style id="hl-light">\(githubCSS)</style>
            <style id="hl-dark">\(githubDarkCSS)</style>
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
                var useDark = theme === 'dark' || (theme === 'system' && prefersDark);
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
            \(mermaidStyle)
```

This script block lives in `<head>` and runs synchronously before the body renders — no flash of wrong theme. `applyTheme` sets the `data-theme` attribute and toggles which highlight CSS is active. The media query listener handles OS appearance changes while system theme is active.

**Step 3: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "feat(ui): embed both highlight CSS files and applyTheme() in generateHTML"
```

---

### Task 3: Update `generateStaticHTML` — same treatment

**Files:**
- Modify: `QuickDown/AppDelegate.swift` — `generateStaticHTML(content:)` method (~lines 934–958)

**Step 1: Remove the `themeStyles` variable**

Find this block (~lines 939–942):

```swift
        let themeStyles = generateThemeStyles(
            githubCSS: githubCSS,
            githubDarkCSS: githubDarkCSS
        )
```

Delete it.

**Step 2: Replace `\(themeStyles)` in the HTML template**

Find (~line 951):

```swift
            <style>\(stylesCSS)</style>
            \(themeStyles)
        </head>
```

Replace with:

```swift
            <style>\(stylesCSS)</style>
            <style id="hl-light">\(githubCSS)</style>
            <style id="hl-dark">\(githubDarkCSS)</style>
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
                var useDark = theme === 'dark' || (theme === 'system' && prefersDark);
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
        </head>
```

**Step 3: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "feat(ui): apply applyTheme() pattern to generateStaticHTML"
```

---

### Task 4: Simplify `selectTheme` — remove reload logic

**Files:**
- Modify: `QuickDown/AppDelegate.swift` — `selectTheme(_:)` method (~lines 1419–1456)

**Step 1: Replace the reload block**

Find the comment and everything below `updateWindowBackground()` inside `selectTheme` (~lines 1433–1455):

```swift
        // Capture scroll position, then reload with new theme and restore position
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

Replace with:

```swift
        webView?.evaluateJavaScript("applyTheme('\(theme.rawValue.lowercased())')")
```

The full `selectTheme` method should now look like:

```swift
    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? Theme else { return }
        currentTheme = theme

        // Update menu checkmarks
        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = (item.representedObject as? Theme == theme) ? .on : .off
            }
        }

        updateWindowBackground()
        webView?.evaluateJavaScript("applyTheme('\(theme.rawValue.lowercased())')")
    }
```

**Step 2: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED.

**Step 3: Manual test — theme transitions**

- Copy the Debug build to /Applications (drag from `~/Library/Developer/Xcode/DerivedData/.../Debug/QuickDown.app`)
- Launch from /Applications, open `demo.md`
- Scroll halfway down the document
- Switch themes via View → Theme: System → Light → Dark → Sepia → System
- Expected:
  - Colors fade smoothly (~200ms) on each switch
  - Scroll position does NOT reset (no reload happening)
  - Syntax highlighting colors update correctly (light highlight CSS for light/sepia, dark for dark)
  - Switching macOS to dark mode while "System" theme is active updates highlight CSS

**Step 4: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "feat(ui): simplify selectTheme to evaluateJavaScript applyTheme, remove reload"
```

---

### Task 5: Delete `generateThemeStyles` method

**Files:**
- Modify: `QuickDown/AppDelegate.swift` — `generateThemeStyles(githubCSS:githubDarkCSS:)` method (~lines 1136–1231)

**Step 1: Delete the entire method**

Find and delete the entire `generateThemeStyles` method. It starts at:

```swift
    private func generateThemeStyles(githubCSS: String, githubDarkCSS: String) -> String {
```

And ends with the closing `}` after the sepia case's `"""` block (~line 1231).

The method is now unreferenced — Tasks 2, 3, and 4 removed all call sites.

**Step 2: Build to confirm no errors**

Build in Xcode (⌘B). Expected: BUILD SUCCEEDED with no "use of unresolved identifier" or "unused function" warnings.

**Step 3: Commit**

```bash
git add QuickDown/AppDelegate.swift
git commit -m "refactor(ui): delete generateThemeStyles, replaced by CSS data-theme approach"
```

---

### Task 6: Final manual test, DEVLOG entry, merge

**Files:**
- Modify: `DEVLOG.md`

**Step 1: Comprehensive manual test**

- Open QuickDown from /Applications with `demo.md`
- Test all four themes — verify smooth 200ms color fades
- Scroll to the code blocks section — verify syntax highlighting is correct per theme
- Scroll to the math/LaTeX section — verify KaTeX still renders
- Scroll to the mermaid section — verify diagrams still render
- Scroll halfway down, switch theme — verify scroll position preserved
- Edit `demo.md` and save — verify live reload crossfade still works
- QuickLook `demo.md` in Finder (press Space) — verify preview still renders (QuickLook is unaffected by this change)

**Step 2: Add DEVLOG entry**

Add a new section at the top of `DEVLOG.md`:

```markdown
## v0.4.0 — CSS Variables Theme Refactor

- Theme changes are now instant CSS variable updates — no page reload, no snapshot crossfade
- Smooth 200ms color fade animation on theme switch via CSS transitions
- Scroll position always preserved on theme change (no reload = no scroll loss)
- Deleted `generateThemeStyles()` — theme colors now live entirely in `styles.css`
- Adding a new theme now requires only a CSS block + one enum case
```

**Step 3: Commit DEVLOG**

```bash
git add DEVLOG.md
git commit -m "docs: add v0.4.0 DEVLOG entry for CSS variables theme refactor"
```

**Step 4: Merge to main**

```bash
git checkout main
git merge feat/css-variables-refactor
git push origin main
```
