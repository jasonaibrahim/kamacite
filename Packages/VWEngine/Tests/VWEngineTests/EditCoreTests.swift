import Foundation
import Testing
import VWCore
@testable import VWEditCore

@Suite struct LineFramerTests {
    @Test func linesSplitAcrossChunksReassemble() {
        var framer = LineFramer()
        #expect(framer.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = framer.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines == [.line(Data("{\"a\":1}".utf8)), .line(Data("{\"b\":2}".utf8))])
        #expect(framer.append(Data(":3}\n".utf8)) == [.line(Data("{\"c\":3}".utf8))])
    }

    @Test func crlfTolerated() {
        var framer = LineFramer()
        #expect(framer.append(Data("hello\r\n".utf8)) == [.line(Data("hello".utf8))])
    }

    @Test func oversizedLineDropsAndResyncs() {
        var framer = LineFramer(maxLineBytes: 8)
        let lines = framer.append(Data("0123456789ABCDEF\nok\n".utf8))
        #expect(lines == [.tooLarge, .line(Data("ok".utf8))])
        // Oversized accumulation without a newline reports once, then resyncs.
        var slow = LineFramer(maxLineBytes: 8)
        #expect(slow.append(Data("0123456".utf8)).isEmpty)
        #expect(slow.append(Data("89AB".utf8)) == [.tooLarge])
        #expect(slow.append(Data("CDEF".utf8)).isEmpty) // still discarding
        #expect(slow.append(Data("GH\nfine\n".utf8)) == [.line(Data("fine".utf8))])
    }
}

@Suite struct WireTests {
    @Test func decodesEveryVerbShapeAndIgnoresUnknownFields() {
        let line = Data("""
        {"id":7,"cmd":"edit","doc":"/tmp/x.md","revision":3,"edits":[{"old":"a","new":"b"},{"range":[0,2],"text":"hi\\nthere"}],"future_field":true}
        """.utf8)
        guard case .request(let request) = decodeWireRequest(line) else {
            Issue.record("expected decode")
            return
        }
        #expect(request.id == 7)
        #expect(request.cmd == "edit")
        #expect(request.revision == 3)
        #expect(request.edits?.count == 2)
        #expect(request.edits?[0].old == "a")
        #expect(request.edits?[1].range == [0, 2])
        #expect(request.edits?[1].text == "hi\nthere")
    }

    @Test func unparseableLineYieldsParseErrorWithRecoveredID() throws {
        guard case .invalid(let response) = decodeWireRequest(Data("{\"id\":9,\"cmd\":42}".utf8)) else {
            Issue.record("expected invalid")
            return
        }
        let object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        #expect(object["ok"] as? Bool == false)
        #expect(object["id"] as? Int == 9)
        #expect((object["error"] as? [String: Any])?["code"] as? String == "parse_error")
    }

    @Test func responsesAreSingleTerminatedLines() throws {
        let ok = WireResponse.ok(id: 1, result: ["revision": 2, "dirty": true])
        #expect(ok.last == 0x0A)
        #expect(ok.dropLast().firstIndex(of: 0x0A) == nil)
        let object = try JSONSerialization.jsonObject(with: ok.dropLast()) as! [String: Any]
        #expect(object["ok"] as? Bool == true)
        #expect((object["result"] as? [String: Any])?["revision"] as? Int == 2)

        let failure = WireResponse.failure(
            id: nil, code: .revisionMismatch, message: "stale",
            extras: ["expected": 1, "actual": 2]
        )
        let failureObject = try JSONSerialization.jsonObject(with: failure.dropLast()) as! [String: Any]
        #expect(failureObject["id"] is NSNull)
        let error = failureObject["error"] as! [String: Any]
        #expect(error["code"] as? String == "revision_mismatch")
        #expect(error["expected"] as? Int == 1)
    }
}

@Suite struct EditResolverTests {
    private let data = Data("alpha beta gamma beta tail".utf8)

    @Test func uniqueFindReplaceResolves() throws {
        let edits = try resolveEdits([WireEdit(old: "alpha", new: "OMEGA")], against: data)
        #expect(edits == [SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 5), replacement: "OMEGA")])
    }

    @Test func nonUniqueMatchReportsCountAndOffsets() {
        #expect(throws: ResolveError.nonUniqueMatch(old: "beta", count: 2, offsets: [6, 17])) {
            try resolveEdits([WireEdit(old: "beta", new: "x")], against: data)
        }
    }

    @Test func replaceAllResolvesEveryOccurrence() throws {
        let edits = try resolveEdits([WireEdit(old: "beta", new: "x", all: true)], against: data)
        #expect(edits.map(\.span.startUTF8) == [6, 17])
    }

    @Test func noMatchAndEmptyOldReject() {
        #expect(throws: ResolveError.noMatch(old: "zeta")) {
            try resolveEdits([WireEdit(old: "zeta", new: "x")], against: data)
        }
        #expect(throws: ResolveError.self) {
            try resolveEdits([WireEdit(old: "", new: "x")], against: data)
        }
        #expect(throws: ResolveError.self) {
            try resolveEdits([], against: data)
        }
    }

    @Test func rangeEditsValidateBounds() throws {
        let ok = try resolveEdits([WireEdit(range: [3, 3], text: "ins")], against: data)
        #expect(ok == [SourceEdit(span: SourceSpan(startUTF8: 3, endUTF8: 3), replacement: "ins")])
        #expect(throws: ResolveError.invalidRange(start: 0, end: 999, bytes: data.count)) {
            try resolveEdits([WireEdit(range: [0, 999], text: "x")], against: data)
        }
        #expect(throws: ResolveError.self) {
            try resolveEdits([WireEdit(range: [5], text: "x")], against: data)
        }
        // Mixed shapes in one edit reject.
        var malformed = WireEdit(range: [0, 1], text: "x")
        malformed.old = "y"
        #expect(throws: ResolveError.self) {
            try resolveEdits([malformed], against: data)
        }
    }

    @Test func occurrencesAreNonOverlapping() {
        #expect(occurrences(of: Data("aa".utf8), in: Data("aaaa".utf8)) == [0, 2])
        #expect(occurrences(of: Data("".utf8), in: Data("x".utf8)) == [])
    }

    @Test func postApplySpansAccountForEarlierDeltas() {
        let edits = [
            SourceEdit(span: SourceSpan(startUTF8: 10, endUTF8: 12), replacement: "wide-open"),
            SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 4), replacement: "x"),
        ]
        // Ascending: [0,4)→"x" (delta -3), then [10,12)→"wide-open" at 7.
        #expect(postApplySpans(of: edits) == [[0, 1], [7, 16]])
    }
}

@Suite struct SocketPathTests {
    @Test func envOverrideWins() {
        #expect(SocketPath.resolve(environment: ["KAMACITE_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
    }

    @Test func defaultLandsInApplicationSupport() {
        let path = SocketPath.resolve(environment: [:])
        #expect(path.hasSuffix("Kamacite/kama.sock"))
        #expect(path.utf8.count < 104)
    }
}

@Suite struct AtomicWriteTests {
    @Test func writeReplacesInodeAndPreservesPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kamacite-aw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("original".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let inodeBefore = (try FileManager.default.attributesOfItem(atPath: url.path))[.systemFileNumber] as! Int

        let stamp = try atomicWrite(Data("replaced".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("replaced".utf8))
        #expect(stamp.size == 8)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.systemFileNumber] as! Int != inodeBefore) // fresh inode: old mmaps live on
        #expect((attributes[.posixPermissions] as! NSNumber).intValue == 0o640)
        // No temp litter.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["doc.md"])
    }

    @Test func writeToMissingDirectoryFailsCleanly() {
        let url = URL(fileURLWithPath: "/nonexistent-kamacite-dir/doc.md")
        #expect(throws: AtomicWriteError.self) {
            try atomicWrite(Data("x".utf8), to: url)
        }
    }
}
