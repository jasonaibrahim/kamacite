import Foundation

// The mutable source of truth for live editing. Edits are byte-range
// replacements against the buffer; the file on disk is untouched until an
// explicit commit reads `data` back out. Whole-buffer UTF-8 validity is an
// invariant: the parser's line table is built over the DECODED string, so a
// buffer that decodes lossily (invalid bytes → U+FFFD, 1 byte → 3) would put
// every SourceSpan in a different coordinate space than the bytes they index.

/// A single replacement of a byte range in the source buffer.
///
/// `span` is in PRE-BATCH coordinates: every edit in one `apply` batch
/// addresses the buffer as it was before the batch, so callers never do
/// their own offset shifting.
public struct SourceEdit: Sendable, Equatable {
    public var span: SourceSpan
    /// Valid UTF-8. Empty = deletion; an empty `span` makes this an insertion.
    public var replacement: Data

    public init(span: SourceSpan, replacement: Data) {
        self.span = span
        self.replacement = replacement
    }

    public init(span: SourceSpan, replacement: String) {
        self.init(span: span, replacement: Data(replacement.utf8))
    }
}

/// Batch validation failures. The `index` identifies the offending edit in
/// the caller's (unsorted) batch so IPC errors can point at it.
public enum SourceEditError: Error, Equatable {
    case spanOutOfBounds(index: Int)
    case overlappingEdits(index: Int)
    /// A span edge lands mid-scalar (on a UTF-8 continuation byte). Applying
    /// it would leave the buffer invalid, desynchronizing spans from bytes.
    case notCharacterBoundary(offset: Int)
    case invalidReplacementUTF8(index: Int)
}

/// What a batch changed, in both coordinate spaces — the input the edit
/// splice needs to bound its reparse.
public struct SourceEditSummary: Sendable, Equatable {
    /// Union of the batch's spans, pre-batch coordinates.
    public var changedPreEdit: SourceSpan
    /// The same union after application (post-batch coordinates).
    public var changedPostEdit: SourceSpan
    public var byteDelta: Int
}

public struct SourceBuffer: Sendable {
    public private(set) var data: Data
    /// Bumped once per successfully applied non-empty batch. This is the
    /// wire-visible "revision": staleness guards throughout the session
    /// (in-flight parses, highlights) and the IPC compare-and-swap all key
    /// off it.
    public private(set) var version: UInt64 = 0
    /// True when init found invalid UTF-8 and re-encoded it (lossily, with
    /// U+FFFD) so buffer offsets match what the parser's decoded string sees.
    /// The session must treat existing spans as stale and full-reparse once.
    public let wasCanonicalized: Bool

    public init(data: Data) {
        if data.firstInvalidUTF8Offset() == nil {
            self.data = data
            self.wasCanonicalized = false
        } else {
            // Re-encode exactly the way parseMarkdown(data:) decodes, so the
            // canonical bytes and the parser's string are one space.
            self.data = Data(String(decoding: data, as: UTF8.self).utf8)
            self.wasCanonicalized = true
        }
    }

    /// Atomic: the whole batch is validated first (in bounds, non-overlapping,
    /// scalar-aligned edges, valid replacement UTF-8), then applied
    /// back-to-front so every span stays in pre-batch coordinates. Throws with
    /// the buffer and version untouched. Adjacent edits are legal; same-offset
    /// insertions land in batch order. An empty batch is a no-op (no version
    /// bump).
    public mutating func apply(_ edits: [SourceEdit]) throws -> SourceEditSummary {
        guard !edits.isEmpty else {
            let empty = SourceSpan(startUTF8: 0, endUTF8: 0)
            return SourceEditSummary(changedPreEdit: empty, changedPostEdit: empty, byteDelta: 0)
        }

        // Deterministic order regardless of stdlib sort stability: position,
        // then batch index (so same-offset insertions keep batch order after
        // the back-to-front application below).
        let sorted = edits.enumerated().sorted {
            ($0.element.span.startUTF8, $0.element.span.endUTF8, $0.offset)
                < ($1.element.span.startUTF8, $1.element.span.endUTF8, $1.offset)
        }

        for (position, entry) in sorted.enumerated() {
            let (batchIndex, edit) = (entry.offset, entry.element)
            guard edit.span.endUTF8 <= data.count else {
                throw SourceEditError.spanOutOfBounds(index: batchIndex)
            }
            if position + 1 < sorted.count,
               edit.span.endUTF8 > sorted[position + 1].element.span.startUTF8 {
                throw SourceEditError.overlappingEdits(index: sorted[position + 1].offset)
            }
            // Buffer validity + scalar-aligned edges + valid replacements ⇒
            // the spliced result is valid by construction: no rescan needed.
            for offset in [edit.span.startUTF8, edit.span.endUTF8] where !isScalarBoundary(offset) {
                throw SourceEditError.notCharacterBoundary(offset: offset)
            }
            if edit.replacement.firstInvalidUTF8Offset() != nil {
                throw SourceEditError.invalidReplacementUTF8(index: batchIndex)
            }
        }

        let unionStart = sorted.first!.element.span.startUTF8
        let unionEnd = sorted.map(\.element.span.endUTF8).max()!
        let byteDelta = edits.reduce(0) { $0 + $1.replacement.count - $1.span.length }

        for entry in sorted.reversed() {
            let span = entry.element.span
            let base = data.startIndex
            data.replaceSubrange((base + span.startUTF8)..<(base + span.endUTF8),
                                 with: entry.element.replacement)
        }
        version &+= 1

        return SourceEditSummary(
            changedPreEdit: SourceSpan(startUTF8: unionStart, endUTF8: unionEnd),
            changedPostEdit: SourceSpan(startUTF8: unionStart, endUTF8: unionEnd + byteDelta),
            byteDelta: byteDelta
        )
    }

    /// Wholesale replacement (discard-to-disk-truth, tests). Counts as a
    /// revision: anything in flight against the old bytes must go stale.
    public mutating func replaceAll(with newData: Data) {
        data = SourceBuffer(data: newData).data
        version &+= 1
    }

    private func isScalarBoundary(_ offset: Int) -> Bool {
        if offset == 0 || offset == data.count { return true }
        let byte = data[data.startIndex + offset]
        return byte & 0xC0 != 0x80
    }
}

extension Data {
    /// Offset of the first byte at which the data stops being well-formed
    /// UTF-8 (RFC 3629: no overlongs, no surrogates, max U+10FFFF), or nil if
    /// valid throughout. Allocation-free — used on the open path where a
    /// 100MB mmap must not be copied just to be checked.
    func firstInvalidUTF8Offset() -> Int? {
        withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let count = bytes.count
            while i < count {
                let b0 = bytes[i]
                if b0 < 0x80 { i += 1; continue }
                let width: Int
                let (minB1, maxB1): (UInt8, UInt8)
                switch b0 {
                case 0xC2...0xDF: width = 2; (minB1, maxB1) = (0x80, 0xBF)
                case 0xE0: width = 3; (minB1, maxB1) = (0xA0, 0xBF) // no overlongs
                case 0xE1...0xEC, 0xEE...0xEF: width = 3; (minB1, maxB1) = (0x80, 0xBF)
                case 0xED: width = 3; (minB1, maxB1) = (0x80, 0x9F) // no surrogates
                case 0xF0: width = 4; (minB1, maxB1) = (0x90, 0xBF) // no overlongs
                case 0xF1...0xF3: width = 4; (minB1, maxB1) = (0x80, 0xBF)
                case 0xF4: width = 4; (minB1, maxB1) = (0x80, 0x8F) // max U+10FFFF
                default: return i // 0x80-0xC1 lead, 0xF5+
                }
                guard i + width <= count else { return i }
                guard (minB1...maxB1).contains(bytes[i + 1]) else { return i }
                for j in 2..<width where bytes[i + j] & 0xC0 != 0x80 { return i }
                i += width
            }
            return nil
        }
    }
}
