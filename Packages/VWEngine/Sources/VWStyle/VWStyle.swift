// VWStyle — Theme/ResolvedTheme/FontTable; ContentTree → FlatDocument (lands in P2).
//
// Flattens nested structure (lists/quotes → indent + decorations) into a linear
// block array — what makes lazy layout O(1)-indexable. Colors resolve as tokens
// (appearance flip = re-render only); fonts as slots (font change = re-layout, no
// re-parse). The CodeHighlighter hook slots in here at flatten time.
