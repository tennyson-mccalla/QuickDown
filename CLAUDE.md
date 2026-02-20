# QuickDown - Claude Code Configuration

## Context

macOS Markdown preview app with a QuickLook extension. Renders Markdown files with syntax highlighting, KaTeX math, Mermaid diagrams, live reload on save, and four themes (System/Light/Dark/Sepia).

**Tech Stack**: Swift, AppKit, WKWebView, CSS Custom Properties, Xcode

**Core Principle**: Single-file AppDelegate architecture. Rendering happens entirely in WKWebView via embedded HTML/CSS/JS — Swift orchestrates, the browser renders.

**Last Updated**: 2026-02-19
**SuperNavigator Version**: 6.0.0

---

## SuperNavigator Auto-Start

At the beginning of every session, automatically invoke the `supernavigator:nav-start` skill to load project context. Do not wait for the user to ask.

**Core workflow**:
1. **Start session** → Loads both layers automatically
2. **Design** → `/superpowers:brainstorming`
3. **Plan** → `/superpowers:writing-plans`
4. **Execute** → `/superpowers:executing-plans`
5. **Review** → `/superpowers:requesting-code-review`
6. **Release** → `/release`

---

## Project-Specific Code Standards

### Architecture
- All app logic lives in `QuickDown/AppDelegate.swift` — keep it that way unless there's a compelling reason to split
- Theme colors live in `MarkdownPreview/Resources/styles.css` via `[data-theme]` attribute selectors — not in Swift
- Resources (JS/CSS libraries) are bundled and loaded via `loadResource(_:ext:)` with an in-memory cache
- QuickLook extension (`MarkdownPreview/`) shares CSS/rendering logic but is a separate target

### Swift Patterns
- Use `[weak self]` in all closures that capture `self`
- `evaluateJavaScript` calls go through WKWebView — no Swift↔JS bridge classes
- Crossfade transitions: snapshot → instant change → fade overlay out (see `crossfadeTransition`)

### Releases
- Version bump both `QuickDown/Info.plist` and `MarkdownPreview/Info.plist` before releasing
- Use `/release` skill for the full archive → notarize → DMG → GitHub pipeline
- App Store builds use a separate export options plist

---

## Forbidden Actions

- ❌ NEVER request or initiate a build — the user does all building
- ❌ NEVER load all `.agent/` docs at once
- ❌ NEVER skip reading DEVELOPMENT-README.md at session start
- ❌ NEVER commit secrets or API keys
- ❌ NEVER add `!important` CSS overrides — use CSS variables via `[data-theme]` instead

---

## Documentation Structure

```
.agent/
├── DEVELOPMENT-README.md      # Navigator (always load first)
├── tasks/                     # Implementation plans
├── system/                    # Architecture docs
└── sops/
    ├── debugging/             # WKWebView quirks, theme issues, live reload
    └── deployment/            # Release checklist, notarization
```

---

## Commit Guidelines

- **Format**: `type(scope): description`
- **Types**: feat, fix, docs, refactor, chore
- **Scopes**: ui, core, ql (QuickLook), build
- Examples: `feat(ui): add sepia theme`, `fix(core): resolve live reload on atomic save`

---

**Navigator docs**: `.agent/DEVELOPMENT-README.md`
