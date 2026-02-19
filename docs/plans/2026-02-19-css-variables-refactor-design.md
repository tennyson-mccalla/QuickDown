# CSS Variables Refactor Design — v0.4.0

## Problem

Theme changes trigger a full `loadFileURL` reload: scroll captured → HTML regenerated with baked-in `!important` CSS → page reloaded → scroll restored → 300ms crossfade. This is unnecessarily expensive. Theme colors are baked into Swift string literals inside `generateThemeStyles()`, duplicating values that belong in CSS.

## Approach: `data-theme` Attribute + CSS Variables

Theme change = one `evaluateJavaScript("applyTheme('dark')")` call. No reload, no crossfade, no scroll save/restore for theme changes. The 200ms color fade is handled entirely by CSS `transition` properties.

## Architecture

### CSS (`styles.css`)

Three additions to the existing file:

**1. Theme variable overrides via attribute selectors:**
```css
[data-theme="light"] {
    color-scheme: light;
    --bg-color: #ffffff; --text-color: #24292e; --link-color: #0366d6;
    --code-bg: #f6f8fa; --border-color: #e1e4e8;
    --blockquote-color: #6a737d; --table-border: #dfe2e5;
}
[data-theme="dark"] {
    color-scheme: dark;
    --bg-color: #0d1117; --text-color: #c9d1d9; --link-color: #58a6ff;
    --code-bg: #161b22; --border-color: #30363d;
    --blockquote-color: #8b949e; --table-border: #30363d;
}
[data-theme="sepia"] {
    color-scheme: light;
    --bg-color: #f4ecd8; --text-color: #5b4636; --link-color: #8b4513;
    --code-bg: #e8dcc8; --border-color: #d4c4a8;
    --blockquote-color: #7a6048; --table-border: #d4c4a8;
}
```
System theme = no `data-theme` attribute → existing `@media (prefers-color-scheme: dark)` already handles it.

**2. CSS transitions** on key elements (200ms ease):
```css
body, pre, code, blockquote, table, th, td, a,
h1, h2, h3, h4, h5, h6 {
    transition: background-color 200ms ease, color 200ms ease, border-color 200ms ease;
}
```

### HTML (`generateHTML` + sidebar path)

Replace `generateThemeStyles()` call with always-embedded highlight CSS + `applyTheme()` function:

```html
<style id="hl-light">{githubCSS}</style>
<style id="hl-dark">{githubDarkCSS}</style>
<script>
function applyTheme(theme) {
    const html = document.documentElement;
    const hlLight = document.getElementById('hl-light');
    const hlDark  = document.getElementById('hl-dark');

    if (theme === 'system') {
        html.removeAttribute('data-theme');
    } else {
        html.setAttribute('data-theme', theme);
    }

    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const useDark = theme === 'dark' || (theme === 'system' && prefersDark);
    if (hlLight) hlLight.disabled = useDark;
    if (hlDark)  hlDark.disabled  = !useDark;
}

window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function() {
    if (!document.documentElement.hasAttribute('data-theme')) {
        applyTheme('system');
    }
});

applyTheme('{currentTheme}');
</script>
```

Script lives in `<head>`, runs synchronously before paint — no flash of wrong theme. Media query listener handles OS appearance changes while system theme is active.

### Swift (`AppDelegate.swift`)

**`selectTheme` after refactor:**
```swift
@objc func selectTheme(_ sender: NSMenuItem) {
    guard let theme = sender.representedObject as? Theme else { return }
    currentTheme = theme
    if let themeMenu = sender.menu {
        for item in themeMenu.items {
            item.state = (item.representedObject as? Theme == theme) ? .on : .off
        }
    }
    updateWindowBackground()
    webView?.evaluateJavaScript("applyTheme('\(theme.rawValue.lowercased())')")
}
```

**Deleted:**
- `generateThemeStyles()` method — removed entirely
- Scroll capture, `crossfadeTransition`, `loadFileURL`, `generateHTML` calls from `selectTheme`

**Untouched:**
- `crossfadeTransition` + `didFinish` scroll restore — still used for live reloads
- `pendingScrollRestoreY` — still used by `reloadCurrentFile`
- `updateWindowBackground()` — native window chrome still needs explicit colors

## Extensibility

Adding a new theme requires:
1. `styles.css`: one new `[data-theme="name"] { ... }` block
2. `Theme` enum: one new `case`
3. `updateWindowBackground()`: one new `case` for window chrome color

The `applyTheme()` JS function and `selectTheme()` Swift method need zero changes.

## Out of Scope

- Sepia syntax highlight variant (sepia uses github.min.css light styles — acceptable for now)
- Per-theme mermaid diagram theme (currently hardcoded to `'default'`)
