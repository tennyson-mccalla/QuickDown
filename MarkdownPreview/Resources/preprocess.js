// QuickDown markdown preprocessor.
//
// Single source of truth shared by:
//   - QuickDown/AppDelegate.swift (loaded via loadResource and injected as a
//     <script> tag in the rendered HTML)
//   - RenderingTests/run-tests.swift (loaded directly into a JSContext)
//
// Exposed surface (treated as stable by the test harness):
//   QDPreprocess.run(markdown)             -> preprocessed markdown string
//   QDPreprocess.computeMathDelimiters(md) -> array of {left, right, display}
//                                             objects suitable for KaTeX
//                                             auto-render's `delimiters` option

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

    // True if the markdown contains a `$` immediately followed by a digit
    // outside of any fenced code block or inline code span. That pattern is
    // currency in prose, and KaTeX's auto-render will pair such dollar signs
    // greedily if `$` is enabled as an inline math delimiter, eating the
    // text between them. See bug #2.
    function hasCurrencyInProse(md) {
        var parts = md.split(/(```[^]*?```|`[^`]*`)/);
        for (var i = 0; i < parts.length; i++) {
            if (i % 2 === 1) continue; // skip code spans/blocks
            if (/\$\d/.test(parts[i])) return true;
        }
        return false;
    }

    // Build the delimiter list for KaTeX auto-render. The single-`$` inline
    // delimiter is hostile to any document containing dollar amounts in
    // prose, so we omit it whenever currency is detected. Documents with no
    // currency keep `$x$`-style inline math working.
    //
    // The other delimiters (`$$...$$`, `\[...\]`, `\(...\)`) are always
    // included — they don't collide with prose.
    function computeMathDelimiters(md) {
        var delims = [
            { left: '$$', right: '$$', display: true },
            { left: '\\[', right: '\\]', display: true },
            { left: '\\(', right: '\\)', display: false }
        ];
        if (!hasCurrencyInProse(md)) {
            delims.push({ left: '$', right: '$', display: false });
        }
        return delims;
    }

    return {
        run: run,
        stripFrontmatter: stripFrontmatter,
        preprocessTildes: preprocessTildes,
        hasCurrencyInProse: hasCurrencyInProse,
        computeMathDelimiters: computeMathDelimiters
    };
})();

// Make available under both Node-ish and JSContext globals.
if (typeof globalThis !== 'undefined') { globalThis.QDPreprocess = QDPreprocess; }
