# Smooth Transitions Design — v0.3.0

## Problem

Theme changes and live reloads both trigger a full `loadFileURL`, causing an abrupt hard cut in content. Users lose visual continuity.

## Approach: Snapshot Crossfade

Before any reload, take a `WKWebView` snapshot and pin it as an `NSImageView` overlay on top of the webview. Trigger the reload underneath. When `didFinish` fires, fade the overlay alpha 1→0 over 300ms and remove it. The user sees old content smoothly replaced by new content — no flash, no blank frame.

This approach works identically for theme changes and live reloads.

## Architecture

### New helper: `crossfadeTransition(then:)`

```
takeSnapshot → pin overlay → execute action (loadFileURL) → [reload happens underneath] → didFinish → scroll restore → fade overlay out → remove overlay
```

- If snapshot fails (webview not ready, etc.), fall through to the action immediately — no crash, no hang.
- The overlay exactly covers the webview bounds.

### Scroll coordination

In `didFinish`, scroll restoration happens before the fade starts:
1. `evaluateJavaScript("window.scrollTo(0, Y)")` with completion handler
2. On completion: begin fade animation

This ensures the new content is at the correct scroll position before it becomes visible.

### Call sites

- `selectTheme`: wraps `loadFileURL` with `crossfadeTransition`
- `reloadCurrentFile`: wraps `loadFileURL` with `crossfadeTransition`
- `openFile`: no change — no overlay is set up, `didFinish` skips fade

### New state

- `private var snapshotOverlay: NSImageView?`

## Timing

- Transition duration: 300ms (empirically chosen — perceptible but not laggy)
- Snapshot is async (~50-100ms) — imperceptible for theme changes; fine for live reload given existing 150ms debounce

## Out of Scope

- CSS variables refactor (true no-reload theme transitions) — future 0.4.0
- Skeleton loading effect on live reload — future consideration
