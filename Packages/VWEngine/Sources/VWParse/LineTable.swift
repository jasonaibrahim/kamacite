import VWCore

/// Maps cmark's (line, column) source locations — 1-based, columns counted in
/// UTF-8 bytes — to absolute UTF-8 byte offsets. Built in one pass over the
/// source; O(1) lookups.
public struct LineTable: Sendable {
    /// UTF-8 offset where each line starts (index 0 = line 1).
    private let lineStarts: [Int]
    public let utf8Count: Int

    public init(text: String) {
        var starts = [0]
        var offset = 0
        for byte in text.utf8 {
            offset += 1
            if byte == 0x0A { // \n — CRLF also lands here, \r stays in the prior line
                starts.append(offset)
            }
        }
        lineStarts = starts
        utf8Count = offset
    }

    /// 1-based line and column (UTF-8 bytes) → absolute UTF-8 offset, clamped
    /// to valid range so malformed locations can never produce a bad span.
    public func utf8Offset(line: Int, column: Int) -> Int {
        guard line >= 1 else { return 0 }
        let lineIndex = min(line - 1, lineStarts.count - 1)
        return min(max(0, lineStarts[lineIndex] + column - 1), utf8Count)
    }
}
