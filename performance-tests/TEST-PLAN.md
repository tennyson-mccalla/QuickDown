# QuickDown v0.2.0 Performance Test Plan

## Goals

1. Establish baseline metrics for QuickDown
2. Compare against competitors
3. Identify bottlenecks
4. Set optimization targets

---

## Phase 1: Metrics to Measure

### Timing Metrics
| Metric | Description | How to Measure |
|--------|-------------|----------------|
| Cold start | Time from app launch to first render | Stopwatch / Instruments |
| Warm render | Time to re-render on file change | Console timestamps |
| Feature load | Time to render mermaid/katex when first used | Console timestamps |
| QuickLook response | Time from Space press to preview visible | Stopwatch |

### Resource Metrics
| Metric | Description | How to Measure |
|--------|-------------|----------------|
| Memory (idle) | RAM after loading file | Activity Monitor |
| Memory (peak) | Peak RAM during render | Instruments |
| CPU (render) | CPU% during initial render | Activity Monitor |
| CPU (idle) | CPU% after render complete | Activity Monitor |
| Bundle size | App size on disk | Finder |

### UX Metrics
| Metric | Description | How to Measure |
|--------|-------------|----------------|
| Scroll smoothness | FPS while scrolling large doc | Instruments Core Animation |
| Input latency | Delay when typing in search | Subjective |
| UI responsiveness | Can interact during render? | Subjective |

---

## Phase 2: Test Files

### Generate Test Files

Run `scripts/generate-test-files.py` to create:

| File | Size | Content |
|------|------|---------|
| `small.md` | ~100 lines | Plain markdown, headings, lists |
| `medium.md` | ~1,000 lines | Mixed: code blocks, tables, links |
| `large.md` | ~10,000 lines | Stress test |
| `huge.md` | ~50,000 lines | Extreme stress test |
| `code-heavy.md` | ~500 lines | Many syntax-highlighted blocks |
| `mermaid-heavy.md` | ~200 lines | 10+ mermaid diagrams |
| `math-heavy.md` | ~300 lines | 50+ KaTeX equations |
| `mixed-features.md` | ~500 lines | All features combined |

### Real-World Test Files

Download from GitHub:
- `react-readme.md` - facebook/react README (~200 lines)
- `typescript-readme.md` - microsoft/TypeScript README (~300 lines)
- `linux-readme.md` - torvalds/linux README (short but symbolic)
- `pandoc-manual.md` - jgm/pandoc user guide (~4,000 lines)

---

## Phase 3: Competitor Benchmarks

### Free Alternatives
| App | Type | Notes |
|-----|------|-------|
| **MacDown** | Editor | Open source, similar tech stack |
| **QLMarkdown** | QuickLook only | Minimal, good baseline |
| **VS Code** | Editor + preview | Electron-based |

### Paid Alternatives
| App | Price | Notes |
|-----|-------|-------|
| **Marked 2** | $14 | macOS native, feature-rich |
| **Typora** | $15 | WYSIWYG, very popular |
| **iA Writer** | $50 | Premium writing app |

### Benchmark Protocol

For each app, measure with `medium.md` and `large.md`:
1. Cold start to render
2. Memory usage after render
3. Scroll smoothness (subjective 1-5)
4. Re-render speed on file change

---

## Phase 4: Profiling

### Instruments Templates

1. **Time Profiler** - Find slow functions
   ```bash
   instruments -t "Time Profiler" -D profile.trace QuickDown.app
   ```

2. **Allocations** - Find memory issues
   ```bash
   instruments -t "Allocations" -D memory.trace QuickDown.app
   ```

3. **Core Animation** - Find scroll/render issues
   ```bash
   instruments -t "Core Animation" -D animation.trace QuickDown.app
   ```

### Add Timing Instrumentation

Add to AppDelegate.swift for render timing:
```swift
let startTime = CFAbsoluteTimeGetCurrent()
// ... render code ...
let elapsed = CFAbsoluteTimeGetCurrent() - startTime
print("[PERF] Render completed in \(elapsed * 1000)ms")
```

### Key Areas to Profile

1. **JavaScript execution** - marked.js, highlight.js, mermaid, katex
2. **WKWebView loading** - HTML injection, resource loading
3. **File I/O** - Reading file, encoding detection
4. **DOM updates** - How WKWebView handles large HTML

---

## Phase 5: Optimization Targets

Based on initial profiling, likely candidates:

### Quick Wins (low effort, high impact)
- [ ] Lazy load mermaid.min.js (3.2 MB) - only when `mermaid` code block detected
- [ ] Lazy load katex - only when `$` detected in content
- [ ] Cache rendered HTML for unchanged files

### Medium Effort
- [ ] Progressive rendering for large files (render visible portion first)
- [ ] Debounce file watcher to avoid rapid re-renders
- [ ] Use lighter syntax highlighter for common languages

### Research Required
- [ ] WebKit vs alternative rendering approaches
- [ ] Incremental DOM updates vs full re-render
- [ ] Native rendering vs WKWebView for simple markdown

---

## Phase 6: Test Execution Checklist

### Round 1: Baseline (before optimization)

- [ ] Generate test files
- [ ] Run timing tests on all test files
- [ ] Record memory/CPU metrics
- [ ] Profile with Instruments
- [ ] Document results in `BASELINE-RESULTS.md`

### Round 2: Competitor Comparison

- [ ] Install MacDown, Marked 2 (trial)
- [ ] Run same tests on competitors
- [ ] Document in `COMPETITOR-RESULTS.md`

### Round 3: Post-Optimization

- [ ] Implement optimizations
- [ ] Re-run all tests
- [ ] Compare to baseline
- [ ] Document improvements

---

## Appendix: Quick Commands

```bash
# Generate test files
python3 performance-tests/scripts/generate-test-files.py

# Time a render (rough)
time open -a QuickDown performance-tests/files/large.md

# Watch memory
top -pid $(pgrep QuickDown) -l 1

# Profile for 30 seconds
instruments -t "Time Profiler" -l 30000 -D perf.trace -p $(pgrep QuickDown)
```
