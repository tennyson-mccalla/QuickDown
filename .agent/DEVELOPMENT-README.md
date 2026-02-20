# QuickDown - Development Documentation Navigator

**Project**: macOS Markdown preview app with QuickLook extension
**Tech Stack**: Swift, AppKit, WKWebView, CSS Custom Properties, Xcode
**Updated**: 2026-02-19

---

## 🚀 Quick Start for Development

### New to This Project?
**Read in this order:**
1. [Project Architecture](./system/project-architecture.md) - Tech stack, structure, patterns
2. [Tech Stack Patterns](./system/tech-stack-patterns.md) - Swift/AppKit-specific patterns
3. [Workflow Guide](./system/workflow.md) - Development workflow

### Starting a New Feature?
1. Check if similar task exists in [`tasks/`](#implementation-plans-tasks)
2. Read relevant system docs from [`system/`](#system-architecture-system)
3. Check for integration SOPs in [`sops/`](#standard-operating-procedures-sops)
4. Generate implementation plan with `/superpowers:writing-plans`
5. Execute with `/superpowers:executing-plans`

### Fixing a Bug?
1. Check [`sops/debugging/`](#debugging) for known issues
2. Review relevant system docs for context
3. After fixing, create SOP: `/nav:sop`

---

## 📂 Documentation Structure

```
.agent/
├── DEVELOPMENT-README.md     ← You are here (navigator)
│
├── tasks/                    ← Implementation plans
│   └── TASK-XX-feature.md
│
├── system/                   ← Living architecture documentation
│   ├── project-architecture.md
│   └── tech-stack-patterns.md
│
├── sops/                     ← Standard Operating Procedures
│   ├── integrations/         # Third-party service integration guides
│   ├── debugging/            # Common issues and solutions
│   ├── development/          # Development workflows
│   └── deployment/           # Release & notarization procedures
│
└── grafana/                  ← Token usage metrics dashboard
```

---

## 📖 Documentation Index

### System Architecture (`system/`)

#### [Project Architecture](./system/project-architecture.md)
**When to read**: Starting work, understanding overall structure

**Contains**:
- Single-file AppDelegate architecture
- WKWebView + HTML/CSS/JS rendering pipeline
- QuickLook extension structure
- Theme system (CSS custom properties + data-theme)
- Release pipeline (archive → notarize → DMG → GitHub)

#### [Tech Stack Patterns](./system/tech-stack-patterns.md)
**When to read**: Implementing new components/features

**Contains**:
- Swift/AppKit patterns in use
- WKWebView JS bridge patterns
- CSS variable theme architecture
- Resource loading (bundle → cache)

---

### Implementation Plans (`tasks/`)

**Format**: `TASK-XX-feature-slug.md`

Plans are created via `/superpowers:writing-plans` and executed via `/superpowers:executing-plans`.

---

### Standard Operating Procedures (`sops/`)

#### Debugging (`sops/debugging/`)
Known issues and solutions for WKWebView quirks, theme rendering, live reload, notarization.

#### Deployment (`sops/deployment/`)
Release checklist: version bump → archive → notarize → staple → DMG → GitHub release → App Store.

---

## 🛠️ Key Commands

| Task | Command |
|------|---------|
| New feature | `/superpowers:brainstorming` |
| Write plan | `/superpowers:writing-plans` |
| Execute plan | `/superpowers:executing-plans` |
| Debug issue | `/superpowers:systematic-debugging` |
| Release | `/release` |
| Commit & push | `/version-control` |

---

## 📊 Token Optimization

1. **Always load**: `DEVELOPMENT-README.md` (~2,000 tokens)
2. **Load for current work**: Specific task doc (~3,000 tokens)
3. **Load as needed**: Relevant system doc (~5,000 tokens)
4. **Load if required**: Specific SOP (~2,000 tokens)

**Total**: ~12,000 tokens vs loading everything

---

**Last Updated**: 2026-02-19
**Powered By**: SuperNavigator 6.0.0
