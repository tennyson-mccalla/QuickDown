// QuickDown markdown preprocessor.
//
// Currently a test-only mirror of the inline preprocessor in
// QuickDown/AppDelegate.swift (around lines 1504-1521). When the bug fixes
// land in branches 2 and 3, the canonical implementation will live here and
// AppDelegate will load this file via loadResource() instead of inlining.
//
// Exposed surface (stable for tests):
//   QDPreprocess.run(markdown)            -> preprocessed markdown string
//   QDPreprocess.computeMathDelimiters(md) -> array of {left, right, display}
//                                             objects to feed KaTeX auto-render
//
// computeMathDelimiters is intentionally NOT YET IMPLEMENTED in this branch;
// the failing test for bug #2 documents the desired contract.

var QDPreprocess = (function () {
    function stripFrontmatter(md) {
        if (!md.startsWith('---\n') && !md.startsWith('---\r')) return md;
        var end = md.indexOf('\n---', 3);
        if (end === -1) return md;
        return md.substring(end + 4).replace(/^\r?\n/, '');
    }

    // marked v15 treats ~single~ tildes as strikethrough, which is not
    // standard GFM. Protect lone tildes outside code blocks/spans by
    // replacing with the HTML numeric entity.
    function preprocessTildes(md) {
        var parts = md.split(/(```[^]*?```|`[^`]*`)/);
        return parts.map(function (part, i) {
            return i % 2 === 1
                ? part
                : part
                    .replace(/~~/g, 'QDDBLTILDE')
                    .replace(/~/g, '&#126;')
                    .replace(/QDDBLTILDE/g, '~~');
        }).join('');
    }

    function run(md) {
        return preprocessTildes(stripFrontmatter(md));
    }

    return {
        run: run,
        stripFrontmatter: stripFrontmatter,
        preprocessTildes: preprocessTildes,
    };
})();

// Make available under both Node-ish and JSContext globals.
if (typeof globalThis !== 'undefined') { globalThis.QDPreprocess = QDPreprocess; }
