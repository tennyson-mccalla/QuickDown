#!/usr/bin/env swift
//
// QuickDown rendering test harness.
//
// Usage:    swift RenderingTests/run-tests.swift
// Exit:     0 if all pass, 1 if any fail, 2 on harness error.
//
// Loads marked.min.js from the bundled resources and preprocess.js from this
// directory into a JSContext, then exercises the markdown -> HTML pipeline
// against a list of test cases. No WKWebView, no DOM, no Xcode target.
//
// Tests in this branch (test/rendering-harness):
//   - Regression cases pin existing behavior so future changes can't silently
//     break them.
//   - Two cases for bugs #2 and #3 are intentionally FAILING. They document
//     the desired contract; subsequent branches make them pass.
//

import Foundation
import JavaScriptCore

// MARK: - Locate resources

let scriptURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
let scriptDir = scriptURL.deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let markedJSURL = repoRoot.appendingPathComponent("MarkdownPreview/Resources/marked.min.js")
let preprocessJSURL = repoRoot.appendingPathComponent("MarkdownPreview/Resources/preprocess.js")

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
    exit(2)
}

func readFile(_ url: URL) -> String {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        die("could not read \(url.path): \(error)")
    }
}

let markedJS = readFile(markedJSURL)
let preprocessJS = readFile(preprocessJSURL)

// MARK: - Boot JSContext

guard let ctx = JSContext() else { die("could not create JSContext") }

var jsErrors: [String] = []
ctx.exceptionHandler = { _, exception in
    if let exc = exception {
        jsErrors.append(exc.toString() ?? "<unknown JS exception>")
    }
}

func eval(_ src: String) -> JSValue? {
    let result = ctx.evaluateScript(src)
    return result
}

_ = eval(markedJS)
if !jsErrors.isEmpty { die("loading marked.min.js failed: \(jsErrors.joined(separator: "; "))") }
_ = eval(preprocessJS)
if !jsErrors.isEmpty { die("loading preprocess.js failed: \(jsErrors.joined(separator: "; "))") }

// Sanity: marked and QDPreprocess must be defined.
if eval("typeof marked")?.toString() != "function" && eval("typeof marked")?.toString() != "object" {
    die("marked global not found after loading marked.min.js (got: \(eval("typeof marked")?.toString() ?? "?"))")
}
if eval("typeof QDPreprocess")?.toString() != "object" {
    die("QDPreprocess global not found after loading preprocess.js")
}

// MARK: - Render helper

func render(_ markdown: String) -> String {
    jsErrors.removeAll()
    ctx.setObject(markdown, forKeyedSubscript: "__qd_input" as NSString)
    let result = eval("marked.parse(QDPreprocess.run(__qd_input))")
    return result?.toString() ?? ""
}

// MARK: - Test infrastructure

struct CheckResult {
    let ok: Bool
    let message: String
    static let pass = CheckResult(ok: true, message: "")
    static func fail(_ msg: String) -> CheckResult { CheckResult(ok: false, message: msg) }
}

struct TestCase {
    let name: String
    let check: () -> CheckResult
}

func mustContain(_ haystack: String, _ needle: String, _ label: String = "output") -> CheckResult {
    if haystack.contains(needle) { return .pass }
    return .fail("\(label) missing `\(needle)`\n      got: \(truncate(haystack))")
}

func mustNotContain(_ haystack: String, _ needle: String, _ label: String = "output") -> CheckResult {
    if !haystack.contains(needle) { return .pass }
    return .fail("\(label) unexpectedly contains `\(needle)`\n      got: \(truncate(haystack))")
}

func truncate(_ s: String, _ n: Int = 240) -> String {
    if s.count <= n { return s }
    return String(s.prefix(n)) + "…"
}

// MARK: - Test cases

let cases: [TestCase] = [

    // ---- Regression: existing behavior we don't want to break ----

    TestCase(name: "regression: marked parses a heading") {
        mustContain(render("# Hello"), "<h1")
    },

    TestCase(name: "regression: YAML frontmatter is stripped") {
        let html = render("---\ntitle: Doc\n---\n# Hello")
        let a = mustContain(html, "<h1")
        if !a.ok { return a }
        return mustNotContain(html, "title:")
    },

    TestCase(name: "regression: lone tilde is not strikethrough") {
        let html = render("approximately ~10 items")
        return mustNotContain(html, "<del>")
    },

    TestCase(name: "regression: real HTML inline tag survives") {
        let html = render("line one<br>line two")
        return mustContain(html, "<br>")
    },

    TestCase(name: "regression: fenced code block preserves dollar signs literally") {
        let html = render("```\nlet price = $75\n```")
        return mustContain(html, "$75")
    },

    TestCase(name: "regression: fenced code block preserves angle-bracket tokens literally") {
        let html = render("```xml\n<local-jndi-name>x</local-jndi-name>\n```")
        return mustContain(html, "&lt;local-jndi-name&gt;")
    },

    // ---- FAILING in this branch — document the bugs ----

    TestCase(name: "bug #2: currency disables single-$ inline math delimiter") {
        // Contract: QDPreprocess.computeMathDelimiters(md) returns the array
        // of {left,right,display} delimiters to feed KaTeX auto-render.
        // For documents containing currency-shaped tokens like "$75" the
        // single-$ pair must be omitted so KaTeX doesn't pair currency
        // markers across the document and eat prose.
        let probe = """
        typeof QDPreprocess.computeMathDelimiters === 'function'
            ? JSON.stringify(QDPreprocess.computeMathDelimiters('Cost: $75 to $95K, also $3/$15 per million'))
            : 'NOT_IMPLEMENTED'
        """
        let result = eval(probe)?.toString() ?? ""
        if result == "NOT_IMPLEMENTED" {
            return .fail("QDPreprocess.computeMathDelimiters is not implemented yet")
        }
        // The forbidden pattern: a delimiter pair where both left and right are "$"
        // (irrespective of key order in the JSON).
        if result.contains("\"left\":\"$\"") && result.contains("\"right\":\"$\"") {
            // It might still be OK if those are not the SAME object, but the
            // expected fix removes single-$ entirely from currency docs, so
            // any occurrence of left=$ should be gone.
            return .fail("currency document still has single-$ inline delimiter enabled\n      got: \(result)")
        }
        return .pass
    },

    TestCase(name: "bug #2: pure-math doc keeps single-$ inline delimiter") {
        // Negative case: a doc with no currency-shaped tokens should still
        // get the single-$ delimiter so existing math users keep working.
        let probe = """
        typeof QDPreprocess.computeMathDelimiters === 'function'
            ? JSON.stringify(QDPreprocess.computeMathDelimiters('Let $x$ be a real number. Then $x^2 \\\\geq 0$.'))
            : 'NOT_IMPLEMENTED'
        """
        let result = eval(probe)?.toString() ?? ""
        if result == "NOT_IMPLEMENTED" {
            return .fail("QDPreprocess.computeMathDelimiters is not implemented yet")
        }
        if !(result.contains("\"left\":\"$\"") && result.contains("\"right\":\"$\"")) {
            return .fail("non-currency math doc lost its single-$ inline delimiter\n      got: \(result)")
        }
        return .pass
    },

    TestCase(name: "bug #3: hyphenated custom-element tag in prose is escaped") {
        let html = render("the tag is <local-jndi-name> rather than <indi-name>.")
        // Must NOT pass the bare tag through to the browser.
        if html.contains("<local-jndi-name>") || html.contains("<indi-name>") {
            return .fail("custom-element tags rendered as raw HTML\n      got: \(truncate(html))")
        }
        // Should appear as escaped, visible text.
        return mustContain(html, "&lt;local-jndi-name&gt;")
    },

    TestCase(name: "bug #3: known HTML inline tag is still allowed") {
        // Negative case: the escape rule must not break legitimate inline HTML.
        let html = render("press <kbd>Cmd</kbd>+<kbd>S</kbd> to save")
        return mustContain(html, "<kbd>")
    },
]

// MARK: - Runner

var passed = 0
var failed = 0

for tc in cases {
    jsErrors.removeAll()
    let result = tc.check()
    if result.ok {
        print("PASS  \(tc.name)")
        passed += 1
    } else {
        print("FAIL  \(tc.name)")
        print("      \(result.message)")
        if !jsErrors.isEmpty {
            print("      JS errors: \(jsErrors.joined(separator: "; "))")
        }
        failed += 1
    }
}

print("")
print("\(passed) passed, \(failed) failed, \(cases.count) total")

exit(failed == 0 ? 0 : 1)
