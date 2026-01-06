# QuickDown Development Log

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

### v0.1.3 (current)
- Mermaid diagram rendering
- KaTeX math rendering (inline `$...$` and display `$$...$$`)
- Table of Contents sidebar (Cmd+Ctrl+S to toggle)
- In-document search (Cmd+F) with scroll markers
- Escape key dismisses search
- Security-scoped bookmarks for recent files (sandbox fix)
- TOC column auto-resizing fix

---

## Roadmap

### v0.1.4 (planned)
- **Share Extension (receiving)** - Select markdown text in any app → Share → Preview in QuickDown
- **Share Menu (sending)** - Share rendered output via AirDrop, copy as rich text, etc.
- **Services Menu** - Right-click text → Services → Preview as Markdown
- **URL Scheme** - `quickdown://open?file=...` for automation

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

## Current Stats
- Source: ~1,300 lines (AppDelegate.swift)
- Resources: 3.7 MB (mermaid.min.js is 3.2 MB)
- Built app: ~8 MB

---

## Future Ideas (unprioritized)
- Printing support
- Multiple windows
- Outline/document map
- Word count
- Custom CSS injection
- Vim keybindings for navigation
- Fountain screenplay format support
