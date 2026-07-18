import Foundation
import VWCore

// Resolution of wire edits against the CURRENT buffer bytes. Find/replace
// resolves and applies in one main-actor turn on the server, so it is immune
// to the read-then-edit revision race that byte-range edits guard against
// with the revision assert.

public enum ResolveError: Error, Equatable {
    case invalidRequest(String)
    case noMatch(old: String)
    case nonUniqueMatch(old: String, count: Int, offsets: [Int])
    case invalidRange(start: Int, end: Int, bytes: Int)
    /// A verified splice's `at` span no longer reads `old` — the buffer
    /// moved (or the belief was stale). `actual` is what's there now.
    case spanMismatch(start: Int, end: Int, actual: String)
    /// `expect` asserted a match count the buffer doesn't have.
    case expectationFailed(old: String, count: Int, expected: Int)
}

/// Turn a wire batch into engine edits (pre-batch byte coordinates).
/// Range edits pass through with bounds checks; find/replace edits resolve
/// by exact UTF-8 byte match — without `all`, exactly one occurrence or a
/// `nonUniqueMatch` carrying the first offsets (≤3) for the error message.
/// Overlap and UTF-8-boundary validation stay with SourceBuffer.apply — one
/// authority for batch validity.
public func resolveEdits(_ wireEdits: [WireEdit], against data: Data) throws -> [SourceEdit] {
    guard !wireEdits.isEmpty else {
        throw ResolveError.invalidRequest("edits must be a non-empty array")
    }
    var resolved: [SourceEdit] = []
    for edit in wireEdits {
        switch (edit.range, edit.text, edit.at, edit.old, edit.new) {
        case (let range?, let text?, nil, nil, nil):
            guard range.count == 2, range[0] >= 0, range[0] <= range[1] else {
                throw ResolveError.invalidRequest("range must be [start, end) with start <= end")
            }
            guard range[1] <= data.count else {
                throw ResolveError.invalidRange(start: range[0], end: range[1], bytes: data.count)
            }
            resolved.append(SourceEdit(
                span: SourceSpan(startUTF8: range[0], endUTF8: range[1]),
                replacement: text
            ))
        case (nil, nil, let at?, let old?, let new?):
            // Verified splice: the span must still read `old`, so an edit
            // can only land where the agent last SAW that content — the
            // string matching elsewhere can't hijack it.
            guard at.count == 2, at[0] >= 0, at[0] <= at[1] else {
                throw ResolveError.invalidRequest("at must be [start, end) with start <= end")
            }
            guard at[1] <= data.count else {
                throw ResolveError.invalidRange(start: at[0], end: at[1], bytes: data.count)
            }
            if data.subdata(in: at[0]..<at[1]) != Data(old.utf8) {
                throw ResolveError.spanMismatch(
                    start: at[0], end: at[1],
                    actual: String(decoding: data.subdata(in: at[0]..<at[1]).prefix(120), as: UTF8.self)
                )
            }
            resolved.append(SourceEdit(
                span: SourceSpan(startUTF8: at[0], endUTF8: at[1]),
                replacement: new
            ))
        case (nil, nil, nil, let old?, let new?):
            guard !old.isEmpty else {
                throw ResolveError.invalidRequest("old must be non-empty")
            }
            let offsets = occurrences(of: Data(old.utf8), in: data)
            if let expected = edit.expect, offsets.count != expected {
                // The stale-mental-model guard: "I believe N remain" is
                // checked before anything lands, not discovered after.
                throw ResolveError.expectationFailed(
                    old: old, count: offsets.count, expected: expected
                )
            }
            guard !offsets.isEmpty else {
                throw ResolveError.noMatch(old: old)
            }
            if edit.all != true, offsets.count > 1 {
                throw ResolveError.nonUniqueMatch(
                    old: old, count: offsets.count, offsets: Array(offsets.prefix(3))
                )
            }
            let length = old.utf8.count
            for offset in offsets {
                resolved.append(SourceEdit(
                    span: SourceSpan(startUTF8: offset, endUTF8: offset + length),
                    replacement: new
                ))
            }
        default:
            throw ResolveError.invalidRequest(
                "each edit is {range, text}, {old, new, all?, expect?}, or {at, old, new}"
            )
        }
    }
    return resolved
}

/// Context snippet per resolved edit for responses and previews: the
/// replacement text spliced into its pre-batch surroundings — cheap
/// self-verification without a follow-up read. (Margins read the PRE-batch
/// buffer, so a snippet won't reflect an ADJACENT edit from the same batch;
/// margins snap to UTF-8 scalar boundaries.)
public func editContexts(
    of edits: [SourceEdit], against data: Data, margin: Int = 40
) -> [String] {
    let ascending = edits.enumerated().sorted {
        ($0.element.span.startUTF8, $0.element.span.endUTF8, $0.offset)
            < ($1.element.span.startUTF8, $1.element.span.endUTF8, $1.offset)
    }
    func snap(_ offset: Int, down: Bool) -> Int {
        var o = min(max(offset, 0), data.count)
        while o > 0, o < data.count, data[data.startIndex + o] & 0xC0 == 0x80 {
            o += down ? -1 : 1
        }
        return o
    }
    return ascending.map { entry in
        let span = entry.element.span
        let before = snap(span.startUTF8 - margin, down: true)
        let after = snap(span.endUTF8 + margin, down: false)
        var snippet = data.subdata(in: before..<span.startUTF8)
        snippet.append(entry.element.replacement)
        snippet.append(data.subdata(in: span.endUTF8..<after))
        return String(decoding: snippet, as: UTF8.self)
    }
}

/// Non-overlapping occurrences of `needle`, left to right.
func occurrences(of needle: Data, in haystack: Data) -> [Int] {
    guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
    var found: [Int] = []
    haystack.withUnsafeBytes { (rawHay: UnsafeRawBufferPointer) in
        needle.withUnsafeBytes { (rawNeedle: UnsafeRawBufferPointer) in
            let hay = rawHay.bindMemory(to: UInt8.self)
            let pattern = rawNeedle.bindMemory(to: UInt8.self)
            let first = pattern[0]
            var i = 0
            while i <= hay.count - pattern.count {
                if hay[i] == first {
                    var j = 1
                    while j < pattern.count, hay[i + j] == pattern[j] { j += 1 }
                    if j == pattern.count {
                        found.append(i)
                        i += pattern.count // non-overlapping, replace-all safe
                        continue
                    }
                }
                i += 1
            }
        }
    }
    return found
}

/// Post-apply spans of each replacement (ascending), for the edit response —
/// the agent can anchor follow-up edits without a re-read.
public func postApplySpans(of edits: [SourceEdit]) -> [[Int]] {
    let ascending = edits.enumerated().sorted {
        ($0.element.span.startUTF8, $0.element.span.endUTF8, $0.offset)
            < ($1.element.span.startUTF8, $1.element.span.endUTF8, $1.offset)
    }
    var delta = 0
    var spans: [[Int]] = []
    for entry in ascending {
        let start = entry.element.span.startUTF8 + delta
        spans.append([start, start + entry.element.replacement.count])
        delta += entry.element.replacement.count - entry.element.span.length
    }
    return spans
}
