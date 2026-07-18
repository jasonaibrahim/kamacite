import Foundation

// The edit-server wire protocol: newline-delimited JSON over a unix domain
// socket. Requests decode with Codable (fixed shape); responses build as
// dictionaries (their shape varies per verb) — both sides of the same line
// format the kama CLI prints verbatim.

/// One request line. Unknown fields are ignored (forward compatibility).
public struct WireRequest: Codable, Sendable {
    public var id: Int?
    public var cmd: String
    /// Canonical absolute file path addressing the document.
    public var doc: String?
    /// Optimistic-concurrency assert for `edit`/`commit`.
    public var revision: UInt64?
    public var edits: [WireEdit]?
    /// Resolve and validate the batch, report would-be spans and context,
    /// apply NOTHING. The agent's look-before-you-leap.
    public var preview: Bool?
    /// Byte range for `read`: [start, end).
    public var range: [Int]?
    public var force: Bool?
    public var hash: Bool?
    /// Destination for `debug-dump`.
    public var path: String?

    public init(
        id: Int? = nil, cmd: String, doc: String? = nil, revision: UInt64? = nil,
        edits: [WireEdit]? = nil, range: [Int]? = nil, force: Bool? = nil,
        hash: Bool? = nil, path: String? = nil
    ) {
        self.id = id
        self.cmd = cmd
        self.doc = doc
        self.revision = revision
        self.edits = edits
        self.range = range
        self.force = force
        self.hash = hash
        self.path = path
    }
}

/// One edit in a batch, three shapes:
/// - `{"range":[s,e),"text":…}` — raw byte-range replacement.
/// - `{"old":…,"new":…,"all"?:bool,"expect"?:int}` — find/replace; `expect`
///   asserts the total occurrence count (the guard against a stale mental
///   model of how many matches remain).
/// - `{"at":[s,e),"old":…,"new":…}` — VERIFIED splice: replace the bytes at
///   `at`, which must equal `old`. Byte-range precision plus content
///   verification; a previous response's `spans` are safe addresses here.
public struct WireEdit: Codable, Sendable, Equatable {
    public var range: [Int]?
    public var text: String?
    public var old: String?
    public var new: String?
    public var all: Bool?
    public var expect: Int?
    public var at: [Int]?

    public init(range: [Int]? = nil, text: String? = nil) {
        self.range = range
        self.text = text
    }

    public init(old: String, new: String, all: Bool? = nil, expect: Int? = nil) {
        self.old = old
        self.new = new
        self.all = all
        self.expect = expect
    }

    public init(at: [Int], old: String, new: String) {
        self.at = at
        self.old = old
        self.new = new
    }
}

/// Stable error codes — the agent-facing contract.
public enum WireErrorCode: String, Sendable {
    case parseError = "parse_error"
    case tooLarge = "too_large"
    case unknownCommand = "unknown_command"
    case invalidRequest = "invalid_request"
    case noSuchFile = "no_such_file"
    case openFailed = "open_failed"
    case noSuchDoc = "no_such_doc"
    case invalidUTF8 = "invalid_utf8"
    case noMatch = "no_match"
    case nonUniqueMatch = "non_unique_match"
    case invalidRange = "invalid_range"
    case overlappingEdits = "overlapping_edits"
    case revisionMismatch = "revision_mismatch"
    case spanMismatch = "span_mismatch"
    case expectationFailed = "expectation_failed"
    case diskChanged = "disk_changed"
    case commitFailed = "commit_failed"
    case dumpFailed = "dump_failed"
}

/// Response construction. Output is one JSON line, LF-terminated.
public enum WireResponse {
    public static func ok(id: Int?, result: [String: Any]) -> Data {
        encode(["id": id as Any? ?? NSNull(), "ok": true, "result": result])
    }

    public static func failure(
        id: Int?, code: WireErrorCode, message: String, extras: [String: Any] = [:]
    ) -> Data {
        var error: [String: Any] = ["code": code.rawValue, "message": message]
        for (key, value) in extras { error[key] = value }
        return encode(["id": id as Any? ?? NSNull(), "ok": false, "error": error])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":{"code":"parse_error","message":"unencodable response"}}"#.utf8)
        data.append(0x0A)
        return data
    }
}

public enum DecodedRequest: Sendable {
    case request(WireRequest)
    /// The line didn't decode; carry the ready-to-send error response.
    case invalid(response: Data)
}

/// Decode one request line. nil id in the error path means the line was
/// unparseable before an id could be read.
public func decodeWireRequest(_ line: Data) -> DecodedRequest {
    do {
        return .request(try JSONDecoder().decode(WireRequest.self, from: line))
    } catch {
        // Best-effort id recovery so the client can correlate the failure.
        let id = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])
            .flatMap { $0["id"] as? Int }
        return .invalid(response: WireResponse.failure(
            id: id, code: .parseError, message: "\(error)"
        ))
    }
}
