import Foundation
import Testing
import VWCore
import VWParse

// Reference implementation: apply edits to a String by byte-splicing through
// Array<UInt8>. Deliberately naive — the buffer must agree with it exactly.
private func naiveApply(_ source: String, _ edits: [SourceEdit]) -> String {
    var bytes = Array(source.utf8)
    let sorted = edits.enumerated().sorted {
        ($0.element.span.startUTF8, $0.element.span.endUTF8, $0.offset)
            < ($1.element.span.startUTF8, $1.element.span.endUTF8, $1.offset)
    }
    for entry in sorted.reversed() {
        let span = entry.element.span
        bytes.replaceSubrange(span.startUTF8..<span.endUTF8, with: Array(entry.element.replacement))
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func buffer(_ source: String) -> SourceBuffer {
    SourceBuffer(data: Data(source.utf8))
}

private func text(_ buffer: SourceBuffer) -> String {
    String(decoding: buffer.data, as: UTF8.self)
}

@Suite struct SourceBufferTests {
    @Test func replaceInsertDeleteAreByteExact() throws {
        var b = buffer("# Title\n\nHello world.\n")
        _ = try b.apply([SourceEdit(span: SourceSpan(startUTF8: 9, endUTF8: 14), replacement: "Goodbye")])
        #expect(text(b) == "# Title\n\nGoodbye world.\n")
        _ = try b.apply([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 0), replacement: "> ")])
        #expect(text(b) == "> # Title\n\nGoodbye world.\n")
        _ = try b.apply([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 2), replacement: "")])
        #expect(text(b) == "# Title\n\nGoodbye world.\n")
        #expect(b.version == 3)
    }

    @Test func batchUsesPreEditCoordinates() throws {
        // Both edits address the original bytes; the first (earlier offset)
        // must not shift the second.
        var b = buffer("aaa bbb ccc")
        let summary = try b.apply([
            SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 3), replacement: "XXXXX"),
            SourceEdit(span: SourceSpan(startUTF8: 8, endUTF8: 11), replacement: "Y"),
        ])
        #expect(text(b) == "XXXXX bbb Y")
        #expect(summary.changedPreEdit == SourceSpan(startUTF8: 0, endUTF8: 11))
        #expect(summary.byteDelta == 0)
        #expect(summary.changedPostEdit == SourceSpan(startUTF8: 0, endUTF8: 11))
        #expect(b.version == 1)
    }

    @Test func summaryTracksDeltas() throws {
        var b = buffer("0123456789")
        let summary = try b.apply([
            SourceEdit(span: SourceSpan(startUTF8: 2, endUTF8: 4), replacement: ""),
            SourceEdit(span: SourceSpan(startUTF8: 6, endUTF8: 6), replacement: "abc"),
        ])
        // Delete "23", insert "abc" before pre-offset 6 (the "6"): the insert
        // sits at post-offset 4 after the deletion shifts it left.
        #expect(text(b) == "0145abc6789")
        #expect(summary.changedPreEdit == SourceSpan(startUTF8: 2, endUTF8: 6))
        #expect(summary.byteDelta == 1)
        #expect(summary.changedPostEdit == SourceSpan(startUTF8: 2, endUTF8: 7))
    }

    @Test func sameOffsetInsertionsKeepBatchOrder() throws {
        var b = buffer("ab")
        _ = try b.apply([
            SourceEdit(span: SourceSpan(startUTF8: 1, endUTF8: 1), replacement: "X"),
            SourceEdit(span: SourceSpan(startUTF8: 1, endUTF8: 1), replacement: "Y"),
        ])
        #expect(text(b) == "aXYb")
    }

    @Test func errorsLeaveBufferUntouched() {
        let original = "hé🚀llo"
        var b = buffer(original)

        #expect(throws: SourceEditError.spanOutOfBounds(index: 0)) {
            try b.apply([SourceEdit(span: SourceSpan(startUTF8: 5, endUTF8: 99), replacement: "x")])
        }
        #expect(throws: SourceEditError.overlappingEdits(index: 1)) {
            try b.apply([
                SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 3), replacement: "x"),
                SourceEdit(span: SourceSpan(startUTF8: 2, endUTF8: 4), replacement: "y"),
            ])
        }
        // "é" spans bytes 1..<3; offset 2 is its continuation byte.
        #expect(throws: SourceEditError.notCharacterBoundary(offset: 2)) {
            try b.apply([SourceEdit(span: SourceSpan(startUTF8: 2, endUTF8: 3), replacement: "x")])
        }
        // "🚀" spans bytes 3..<7.
        #expect(throws: SourceEditError.notCharacterBoundary(offset: 5)) {
            try b.apply([SourceEdit(span: SourceSpan(startUTF8: 5, endUTF8: 7), replacement: "x")])
        }
        #expect(throws: SourceEditError.invalidReplacementUTF8(index: 0)) {
            try b.apply([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 1), replacement: Data([0xFF]))])
        }

        #expect(text(b) == original)
        #expect(b.version == 0)
    }

    @Test func scalarBoundaryEditsOnMultibyteContentWork() throws {
        var b = buffer("hé🚀llo")
        // Replace the whole rocket (bytes 3..<7) with multibyte text.
        _ = try b.apply([SourceEdit(span: SourceSpan(startUTF8: 3, endUTF8: 7), replacement: "日本")])
        #expect(text(b) == "hé日本llo")
    }

    @Test func edgeEditsAndEmptyBatch() throws {
        var b = buffer("abc")
        _ = try b.apply([SourceEdit(span: SourceSpan(startUTF8: 3, endUTF8: 3), replacement: "!")])
        #expect(text(b) == "abc!")
        _ = try b.apply([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 4), replacement: "")])
        #expect(text(b) == "")
        _ = try b.apply([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 0), replacement: "fresh")])
        #expect(text(b) == "fresh")
        let version = b.version
        _ = try b.apply([])
        #expect(b.version == version)
    }

    @Test func adjacentEditsAreLegal() throws {
        var b = buffer("abcdef")
        _ = try b.apply([
            SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 3), replacement: "X"),
            SourceEdit(span: SourceSpan(startUTF8: 3, endUTF8: 6), replacement: "Y"),
        ])
        #expect(text(b) == "XY")
    }

    @Test func invalidUTF8CanonicalizesOnInit() {
        // 0xFF is never valid; lossy decode turns it into U+FFFD (3 bytes).
        let b = SourceBuffer(data: Data([0x61, 0xFF, 0x62]))
        #expect(b.wasCanonicalized)
        #expect(text(b) == "a\u{FFFD}b")
        // Overlong encoding of "/" (0xC0 0xAF) must also be caught.
        let overlong = SourceBuffer(data: Data([0xC0, 0xAF]))
        #expect(overlong.wasCanonicalized)
        // Surrogate half U+D800 encoded as 0xED 0xA0 0x80.
        let surrogate = SourceBuffer(data: Data([0xED, 0xA0, 0x80]))
        #expect(surrogate.wasCanonicalized)
        let valid = buffer("héllo 🚀 日本")
        #expect(!valid.wasCanonicalized)
    }

    @Test func validateRaisesApplyErrorsWithoutMutating() throws {
        let b = buffer("hé🚀llo")
        #expect(throws: SourceEditError.notCharacterBoundary(offset: 2)) {
            try b.validate([SourceEdit(span: SourceSpan(startUTF8: 2, endUTF8: 3), replacement: "x")])
        }
        #expect(throws: SourceEditError.overlappingEdits(index: 1)) {
            try b.validate([
                SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 3), replacement: "x"),
                SourceEdit(span: SourceSpan(startUTF8: 1, endUTF8: 3), replacement: "y"),
            ])
        }
        // A valid batch validates cleanly and — being non-mutating — leaves
        // bytes and version untouched.
        try b.validate([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 1), replacement: "H")])
        #expect(text(b) == "hé🚀llo")
        #expect(b.version == 0)
    }

    @Test func replaceAllBumpsVersion() throws {
        var b = buffer("old")
        let version = b.version
        b.replaceAll(with: Data("new".utf8))
        #expect(text(b) == "new")
        #expect(b.version == version + 1)
    }

    @Test func fuzzAgainstNaiveStringReplacement() throws {
        // Multibyte-rich source so random offsets exercise boundary snapping.
        let alphabet = ["a", "b", "\n", " ", "é", "🚀", "日", "#", "`", "*"]
        for seed in UInt64(1)...8 {
            var rng = SeededRandom(seed: seed)
            var source = (0..<rng.int(in: 20..<200)).map { _ in
                alphabet[rng.int(in: 0..<alphabet.count)]
            }.joined()
            var b = buffer(source)
            var expectedVersion: UInt64 = 0

            for _ in 0..<40 {
                let bytes = Array(source.utf8)
                // Draw non-overlapping spans on scalar boundaries: snap random
                // offsets down to boundaries, then sort and dedupe.
                var offsets: Set<Int> = []
                for _ in 0..<rng.int(in: 2..<8) {
                    var offset = rng.int(in: 0..<bytes.count + 1)
                    while offset > 0, offset < bytes.count, bytes[offset] & 0xC0 == 0x80 {
                        offset -= 1
                    }
                    offsets.insert(offset)
                }
                let cuts = offsets.sorted()
                var edits: [SourceEdit] = []
                var i = 0
                while i + 1 < cuts.count {
                    // Use every other gap so edits never overlap.
                    let replacement = (0..<rng.int(in: 0..<4)).map { _ in
                        alphabet[rng.int(in: 0..<alphabet.count)]
                    }.joined()
                    edits.append(SourceEdit(
                        span: SourceSpan(startUTF8: cuts[i], endUTF8: cuts[i + 1]),
                        replacement: replacement
                    ))
                    i += 2
                }
                guard !edits.isEmpty else { continue }

                let expected = naiveApply(source, edits)
                _ = try b.apply(edits)
                expectedVersion += 1
                #expect(text(b) == expected, "seed \(seed)")
                #expect(b.version == expectedVersion, "seed \(seed)")
                source = expected
            }
        }
    }
}

@Suite struct ParserSpanOffsetTests {
    @Test func spanOffsetRebasesAllSpans() {
        let chunk = "# Head\n\npara *em* text\n\n```swift\nlet x = 1\n```\n"
        let offset = 1000
        let plain = parseMarkdown(chunk)
        let rebased = parseMarkdown(chunk, spanOffset: offset)
        #expect(plain.blocks.count == rebased.blocks.count)
        for (a, b) in zip(plain.blocks, rebased.blocks) {
            #expect(b.span.startUTF8 == a.span.startUTF8 + offset)
            #expect(b.span.endUTF8 == a.span.endUTF8 + offset)
        }
        // Code content spans (byte-verified against the chunk) rebase too.
        if case .codeBlock(_, _, let plainContent) = plain.blocks[2].kind,
           case .codeBlock(_, _, let rebasedContent) = rebased.blocks[2].kind {
            #expect(plainContent != nil)
            #expect(rebasedContent?.startUTF8 == plainContent!.startUTF8 + offset)
            #expect(rebasedContent?.endUTF8 == plainContent!.endUTF8 + offset)
        } else {
            Issue.record("expected code blocks at index 2")
        }
    }

    @Test func idBaseKeepsBlockIDsUniqueAcrossParses() {
        let first = parseMarkdown("one\n\ntwo\n")
        let base = (first.blocks.map(\.id.rawValue).max() ?? 0) + 1
        let second = parseMarkdown("three\n", mintingIDsFrom: base)
        let all = first.blocks.map(\.id) + second.blocks.map(\.id)
        #expect(Set(all).count == all.count)
        #expect(second.blocks.first!.id.rawValue >= base)
    }
}
