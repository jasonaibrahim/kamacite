// VWParse — swift-markdown AST → compact, theme-free ContentTree IR (lands in P2).
//
// Owns the LineTable (cmark line/column → UTF-8 byte offsets) and drops the
// swift-markdown AST immediately after conversion: the IR is Sendable, cheap to
// re-theme, and O(document) instead of holding the whole cmark tree.
