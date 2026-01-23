<p align="center">
  <img src="QuickDownIcon.svg" width="128" height="128" alt="QuickDown Icon">
</p>

<h1 align="center">QuickDown</h1>

<p align="center">
  <strong>A fast, native markdown previewer for macOS</strong><br>
  QuickLook extension + standalone app with live reload, mermaid diagrams, and more.
</p>

<p align="center">
  <a href="https://github.com/tennyson-mccalla/QuickDown/releases/latest">
    <img src="https://img.shields.io/github/v/release/tennyson-mccalla/QuickDown" alt="Latest Release">
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

<!-- TODO: Add screenshot of main window with mermaid diagram visible -->

## Features

### QuickLook Integration
Press **Space** on any markdown file in Finder for instant preview—no app launch needed.

### Standalone App
- **Live Reload** — Edits appear instantly as you save
- **Table of Contents** — Sidebar navigation for long documents (Cmd+Ctrl+S)
- **Search** — Find text with Cmd+F
- **Themes** — System, Light, Dark, or Sepia

### Rich Markdown Support
- **GitHub-Flavored Markdown** — Tables, task lists, strikethrough, autolinks
- **Syntax Highlighting** — 190+ languages via highlight.js
- **Mermaid Diagrams** — Flowcharts, sequence diagrams, gantt charts
- **Math Equations** — LaTeX via KaTeX (`$inline$` and `$$display$$`)

### Export & Share
- **PDF Export** — Print-ready documents
- **HTML Export** — Standalone files with embedded styles
- **Share Menu** — AirDrop, Messages, Mail, and more

### macOS Integration
- **Services Menu** — Select text anywhere, right-click → "Preview as Markdown"
- **URL Scheme** — `quickdown:///path/to/file.md`
- **Drag & Drop** — Drop files onto the app or dock icon
- **Recent Files** — Quick access with Cmd+Shift+1-9

## Installation

Download **QuickDown.dmg** from [Releases](https://github.com/tennyson-mccalla/QuickDown/releases/latest), open it, and drag to Applications.

Launch once to register the QuickLook extension, then press Space on any `.md` file in Finder.

### Supported Extensions
`.md` · `.markdown` · `.mdown` · `.mkdn` · `.mkd`

## Build from Source

Requires Xcode 15+ and macOS 14+.

```bash
git clone https://github.com/tennyson-mccalla/QuickDown.git
cd QuickDown
open QuickDown.xcodeproj
```

Build with **Product → Archive** for a signed release, or **Cmd+R** for development.

## Performance

QuickDown is designed to launch fast and stay out of your way:

- **Cold start**: ~0.1s to drop zone, ~2s with file
- **Memory**: 89MB idle, 95-115MB with file (less if no mermaid/math)
- **Live reload**: Debounced with content-hash checking

Heavy libraries (Mermaid, KaTeX) only load when your document needs them.

## Tech Stack

- **Swift** — Native macOS, no Electron
- **WebKit** — WKWebView for rendering
- **marked.js** — Markdown parsing
- **highlight.js** — Syntax highlighting
- **Mermaid** — Diagrams
- **KaTeX** — Math rendering

## License

MIT
