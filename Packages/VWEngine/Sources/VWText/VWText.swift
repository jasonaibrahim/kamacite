// VWText — CoreText shaping (lands in P1/P2).
//
// CFAttributedString per block (a custom "vw.run" attribute recovers our styled run
// after CoreText splits runs for font fallback), CTTypesetterSuggestLineBreak for
// wrapping, glyph/position/stringIndices extraction per CTRun. Bidi, CJK/emoji
// fallback, and ligatures come free from CoreText.
