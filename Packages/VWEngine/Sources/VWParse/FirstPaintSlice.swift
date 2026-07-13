import Foundation

// First-paint slice: huge documents paint their opening viewport from a small
// synchronous parse while the full parse runs in the background. The cut must
// land on a boundary cmark treats identically in both parses — a blank line at
// top level, never inside a fenced code block — so the slice's blocks are a
// prefix of the full document's blocks and splicing is an index-stable swap.

/// Threshold above which documents open via the slice.
public let firstPaintSliceThreshold = 1 << 20 // 1 MB

/// A safe truncation length ≤ `limit` for `data`, or nil when the document is
/// small enough to parse whole (or no safe cut exists).
public func firstPaintSliceLength(of data: Data, limit: Int = 256 * 1024) -> Int? {
    guard data.count > firstPaintSliceThreshold else { return nil }

    var lastSafeCut = 0
    var inFence = false
    var fenceMarker: UInt8 = 0

    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        let bytes = buffer.bindMemory(to: UInt8.self)
        var lineStart = 0
        while lineStart < limit {
            // Find end of line.
            var lineEnd = lineStart
            while lineEnd < min(bytes.count, limit + 4096), bytes[lineEnd] != 0x0A {
                lineEnd += 1
            }
            guard lineEnd < bytes.count else { break }

            // Classify the line: blank? fence?
            var i = lineStart
            var leadingSpaces = 0
            while i < lineEnd, bytes[i] == 0x20, leadingSpaces < 4 {
                i += 1
                leadingSpaces += 1
            }
            let isBlank = (lineStart == lineEnd)
                || (i == lineEnd && leadingSpaces == lineEnd - lineStart)

            if !inFence, isBlank, lineEnd + 1 <= limit {
                lastSafeCut = lineEnd + 1
            }

            // ``` or ~~~ after ≤3 spaces toggles fence state.
            if leadingSpaces < 4, i + 2 < lineEnd {
                let marker = bytes[i]
                if marker == 0x60 || marker == 0x7E, // ` or ~
                   bytes[i + 1] == marker, bytes[i + 2] == marker {
                    if inFence {
                        if marker == fenceMarker { inFence = false }
                    } else {
                        inFence = true
                        fenceMarker = marker
                    }
                }
            }

            lineStart = lineEnd + 1
        }
    }

    // A degenerate cut (giant opening block) isn't worth slicing for.
    return lastSafeCut > 4096 ? lastSafeCut : nil
}
