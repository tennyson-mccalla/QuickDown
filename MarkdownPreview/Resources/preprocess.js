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
    // Split markdown into alternating prose/code segments. Odd-indexed parts
    // are fenced code blocks or inline code spans and must be left untouched
    // by any preprocessor that operates on prose.
    var CODE_SPLIT_RE = /(```[^]*?```|`[^`]*`)/;
    function mapProse(md, fn) {
        return md.split(CODE_SPLIT_RE).map(function (part, i) {
            return i % 2 === 1 ? part : fn(part);
        }).join('');
    }

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
        return mapProse(md, function (part) {
            return part
                .replace(/~~/g, 'QDDBLTILDE')
                .replace(/~/g, '&#126;')
                .replace(/QDDBLTILDE/g, '~~');
        });
    }

    // Escape angle-bracketed tokens whose tag name contains a hyphen — i.e.
    // custom-element-shaped tokens like <local-jndi-name>, </my-tag>, or
    // <foo-bar attr="x">. Real HTML5 element names never contain hyphens, so
    // a hyphen in the tag name is a strong signal that the author meant the
    // token as literal prose (e.g. discussing XML tags in documentation),
    // not as inline HTML to render.
    //
    // Without this, marked.js passes such tokens through verbatim and the
    // browser parses them as unknown custom elements with zero-width tag
    // names — making the tag tokens visually disappear from the rendered
    // output while their inner text survives. See bug #3.
    //
    // The escape skips fenced code blocks and inline code spans, and only
    // matches when the token actually closes with `>` on the same paragraph.
    // Autolinks like <https://my-site.com> are not affected because their
    // tag-name region (`https`) contains no hyphen before the `:`.
    function escapeCustomElementTags(md) {
        var TAG_RE = /<\/?[a-zA-Z][a-zA-Z0-9]*-[a-zA-Z0-9-]*(?:\s[^>]*)?\/?>/g;
        return mapProse(md, function (part) {
            return part.replace(TAG_RE, function (match) {
                return match
                    .replace(/&/g, '&amp;')
                    .replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;');
            });
        });
    }

    function run(md) {
        return escapeCustomElementTags(preprocessTildes(stripFrontmatter(md)));
    }

    // True if the markdown contains a currency-shaped token in prose. We look
    // for `$` immediately followed by a digit outside of fenced code blocks
    // or inline code spans, then disambiguate against legitimate math that
    // happens to start with a digit (e.g. `$0 = \nabla^2 P$` in math papers).
    //
    // The disambiguation rule: between an opening `$<digit>` and the next
    // `$`, look for TeX indicator characters (`\`, `^`, `_`, `{`, `}`, `=`).
    // If any are present, treat the span as math; otherwise, treat it as
    // currency. If there's no closing `$` within the same paragraph, fall
    // back to a 60-character lookahead with the same rule.
    //
    // The heuristic errs toward "math" when ambiguous on a single token,
    // but a single confirmed currency match anywhere in the document is
    // enough to disable single-`$` inline math globally — KaTeX walks the
    // whole DOM, so any currency leak would still get mangled.
    function hasCurrencyInProse(md) {
        var TEX_INDICATORS = /[\\^_{}=]/;
        var LOOKAHEAD = 60;
        var parts = md.split(CODE_SPLIT_RE);
        for (var i = 0; i < parts.length; i++) {
            if (i % 2 === 1) continue; // skip code spans/blocks
            var prose = parts[i];
            var re = /\$\d/g;
            var match;
            while ((match = re.exec(prose)) !== null) {
                // Skip the second `$` of a `$$` display-math opener — that's
                // not currency, it's the start of `$$...$$`.
                if (match.index > 0 && prose.charAt(match.index - 1) === '$') continue;
                var start = match.index + 1; // position of the digit
                // Find the next `$` on the same paragraph (don't cross blank lines).
                var paraEnd = prose.indexOf('\n\n', start);
                var horizon = paraEnd === -1 ? prose.length : paraEnd;
                var nextDollar = prose.indexOf('$', start);
                if (nextDollar !== -1 && nextDollar > horizon) nextDollar = -1;
                var endIdx;
                if (nextDollar === -1) {
                    endIdx = Math.min(start + LOOKAHEAD, horizon);
                } else {
                    endIdx = nextDollar;
                }
                var between = prose.substring(start, endIdx);
                if (TEX_INDICATORS.test(between)) {
                    // Math-shaped — keep scanning for other potential currency.
                    continue;
                }
                return true;
            }
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
        escapeCustomElementTags: escapeCustomElementTags,
        hasCurrencyInProse: hasCurrencyInProse,
        computeMathDelimiters: computeMathDelimiters
    };
})();

// Make available under both Node-ish and JSContext globals.
if (typeof globalThis !== 'undefined') { globalThis.QDPreprocess = QDPreprocess; }
