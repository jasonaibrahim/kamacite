import AppKit
import VWCore
import VWEditCore
import VWViewer

// The edit server: the app's first true IPC surface. A unix domain socket
// speaking newline-delimited JSON (VWEditCore.Wire) lets an external agent
// edit the in-memory buffer of any open document, watch the preview update
// live, and commit explicitly. Raw BSD sockets + DispatchSource — the same
// dependency-free mental model as the CLI's blocking client, none of
// NWListener's unix-endpoint quirks.
//
// Threading: accept + read + write live on a serial utility queue owned by
// the nonisolated Transport; framing and JSON decode happen there too (a
// 32MB edit must not parse on main). Each connection's decoded requests flow
// through an AsyncStream consumed by one main-actor Task — per-connection
// FIFO by construction (async verbs are awaited before the next request),
// cross-connection serialization by the main actor, which is also where
// every engine mutation must land.
final class EditServer {
    static let shared = EditServer()

    private var transport: EditServerTransport?

    /// Bind and listen. Called AFTER first present — launch-opens run before
    /// applicationDidFinishLaunching and the cold-open gate has ~100ms of
    /// headroom; the listener must stay out of the measured window. Never
    /// started in bench mode: a bench instance beside the user's resident
    /// app must not steal the live socket.
    func start() {
        guard transport == nil else { return }
        let path = SocketPath.resolve()

        // Stale-socket protocol: a live connect means another instance owns
        // it (this instance stays a plain viewer); refused/absent means a
        // crash left the file behind — reclaim it.
        if FileManager.default.fileExists(atPath: path) {
            if unixConnect(path: path).map({ close($0); return true }) ?? false {
                return
            }
            unlink(path)
        }

        do {
            try SocketPath.prepareDirectory(for: path)
        } catch {
            NSLog("kamacite edit server: cannot create socket directory: \(error)")
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking listener: the accept drain loop must end with
        // EWOULDBLOCK, not park the transport queue forever.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        guard withUnixAddress(path: path, { pointer, size in
            bind(fd, pointer, size)
        }) == 0, listen(fd, 16) == 0 else {
            NSLog("kamacite edit server: bind/listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)

        transport = EditServerTransport(listenerFD: fd, socketPath: path) { request in
            await EditServer.shared.handle(request)
        }
    }

    func stop() {
        transport?.shutdown()
        transport = nil
    }

    // MARK: - Dispatch (main actor)

    private func handle(_ request: WireRequest) async -> Data {
        switch request.cmd {
        case "open":
            return handleOpen(request)
        case "commit":
            return await handleCommit(request)
        case "status", "read", "edit", "discard", "debug-dump":
            guard let view = resolveView(request) else {
                return noSuchDoc(request)
            }
            switch request.cmd {
            case "status": return handleStatus(request, view: view)
            case "read": return handleRead(request, view: view)
            case "edit": return handleEdit(request, view: view)
            case "discard": return handleDiscard(request)
            default: return handleDebugDump(request, view: view)
            }
        default:
            return WireResponse.failure(
                id: request.id, code: .unknownCommand, message: "unknown cmd \(request.cmd)"
            )
        }
    }

    private func normalizedDocPath(_ request: WireRequest) -> String? {
        guard let doc = request.doc, doc.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: doc).standardizedFileURL.path
    }

    private func resolveController(_ request: WireRequest) -> DocumentWindowController? {
        guard let path = normalizedDocPath(request) else { return nil }
        return DocumentController.shared.controller(for: URL(fileURLWithPath: path))
    }

    private func resolveView(_ request: WireRequest) -> DocumentEngineView? {
        resolveController(request)?.engineView
    }

    private func noSuchDoc(_ request: WireRequest) -> Data {
        WireResponse.failure(
            id: request.id, code: .noSuchDoc,
            message: "document not open: \(request.doc ?? "(missing doc)")"
        )
    }

    private func docState(_ view: DocumentEngineView) -> [String: Any] {
        [
            "revision": view.revision,
            // byteCount, not editableBytes(): a status must not page-fault a
            // 100MB mmap through the validation scan on the main actor.
            "bytes": view.byteCount,
            "dirty": view.isDirty,
        ]
    }

    private func handleOpen(_ request: WireRequest) -> Data {
        guard let path = normalizedDocPath(request) else {
            return WireResponse.failure(
                id: request.id, code: .invalidRequest, message: "doc must be an absolute path"
            )
        }
        if let existing = DocumentController.shared.controller(for: URL(fileURLWithPath: path)),
           let view = existing.engineView {
            var result = docState(view)
            result["already_open"] = true
            return WireResponse.ok(id: request.id, result: result)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return WireResponse.failure(
                id: request.id, code: .noSuchFile, message: "no such file: \(path)"
            )
        }
        do {
            let controller = try DocumentController.shared.openWindow(url: URL(fileURLWithPath: path))
            guard let view = controller.engineView else {
                return WireResponse.failure(
                    id: request.id, code: .openFailed, message: "window has no engine view"
                )
            }
            var result = docState(view)
            result["already_open"] = false
            return WireResponse.ok(id: request.id, result: result)
        } catch {
            return WireResponse.failure(
                id: request.id, code: .openFailed, message: error.localizedDescription
            )
        }
    }

    private func handleStatus(_ request: WireRequest, view: DocumentEngineView) -> Data {
        var result = docState(view)
        let document = resolveController(request)?.viewedDocument
        result["disk_changed"] = document?.diskChangedExternally ?? false
        if let stamp = document?.diskStamp {
            result["mtime"] = stamp.modificationDate.timeIntervalSince1970
        }
        if request.hash == true {
            result["hash"] = String(format: "%016llx", fnv1a64(view.editableBytes()))
        }
        return WireResponse.ok(id: request.id, result: result)
    }

    private func handleRead(_ request: WireRequest, view: DocumentEngineView) -> Data {
        let bytes = view.editableBytes()
        var slice = bytes
        var range = [0, bytes.count]
        if let requested = request.range {
            guard requested.count == 2, requested[0] >= 0, requested[0] <= requested[1],
                  requested[1] <= bytes.count
            else {
                return WireResponse.failure(
                    id: request.id, code: .invalidRange,
                    message: "range out of bounds", extras: ["bytes": bytes.count]
                )
            }
            slice = bytes.subdata(in: requested[0]..<requested[1])
            range = requested
        }
        guard let text = String(data: slice, encoding: .utf8) else {
            // Mid-scalar cut: the offsets are byte-space, but text rides JSON.
            return WireResponse.failure(
                id: request.id, code: .invalidRange,
                message: "range does not fall on UTF-8 boundaries"
            )
        }
        var result = docState(view)
        result["text"] = text
        result["range"] = range
        return WireResponse.ok(id: request.id, result: result)
    }

    private func handleEdit(_ request: WireRequest, view: DocumentEngineView) -> Data {
        if let asserted = request.revision, asserted != view.revision {
            return revisionMismatch(request, actual: view.revision, asserted: asserted)
        }
        let resolved: [SourceEdit]
        do {
            resolved = try resolveEdits(request.edits ?? [], against: view.editableBytes())
        } catch let error as ResolveError {
            return failure(for: error, id: request.id)
        } catch {
            return WireResponse.failure(id: request.id, code: .invalidRequest, message: "\(error)")
        }
        let outcome: DocumentSession.EditApplyOutcome
        do {
            outcome = try view.applyEdits(resolved)
        } catch let error as SourceEditError {
            return failure(for: error, id: request.id)
        } catch {
            return WireResponse.failure(id: request.id, code: .invalidRequest, message: "\(error)")
        }
        var result = docState(view)
        result["applied"] = resolved.count
        result["spans"] = postApplySpans(of: resolved)
        // Honesty about the preview: the buffer (and revision) always carry
        // the edit, but a large-document fallback re-derives the screen
        // asynchronously — agents polling a debug-dump should know to wait.
        result["outcome"] = switch outcome {
        case .appliedBounded: "applied"
        case .appliedFullReparse: "applied_full_reparse"
        case .scheduledFullReparse: "preview_pending"
        case .queued: "preview_pending"
        }
        return WireResponse.ok(id: request.id, result: result)
    }

    private func handleCommit(_ request: WireRequest) async -> Data {
        guard let controller = resolveController(request), let view = controller.engineView else {
            return noSuchDoc(request)
        }
        if let asserted = request.revision, asserted != view.revision {
            return revisionMismatch(request, actual: view.revision, asserted: asserted)
        }
        return await withCheckedContinuation { continuation in
            controller.commit(force: request.force == true) { result in
                switch result {
                case .success:
                    continuation.resume(returning: WireResponse.ok(
                        id: request.id, result: self.docState(view)
                    ))
                case .failure(.diskChanged):
                    let document = controller.viewedDocument
                    continuation.resume(returning: WireResponse.failure(
                        id: request.id, code: .diskChanged,
                        message: "file changed on disk since open; pass force to overwrite",
                        extras: [
                            "opened_mtime": document?.diskStamp?.modificationDate.timeIntervalSince1970 as Any? ?? NSNull(),
                            "disk_mtime": document.flatMap { FileStamp(of: $0.url)?.modificationDate.timeIntervalSince1970 } as Any? ?? NSNull(),
                        ]
                    ))
                case .failure(.writeFailed(let message)):
                    continuation.resume(returning: WireResponse.failure(
                        id: request.id, code: .commitFailed, message: message
                    ))
                }
            }
        }
    }

    private func handleDiscard(_ request: WireRequest) -> Data {
        guard let controller = resolveController(request), let view = controller.engineView else {
            return noSuchDoc(request)
        }
        controller.discard()
        return WireResponse.ok(id: request.id, result: docState(view))
    }

    private func handleDebugDump(_ request: WireRequest, view: DocumentEngineView) -> Data {
        guard let path = request.path, path.hasPrefix("/") else {
            return WireResponse.failure(
                id: request.id, code: .invalidRequest, message: "path must be an absolute png path"
            )
        }
        guard view.debugDumpFrame(to: URL(fileURLWithPath: path)) else {
            return WireResponse.failure(
                id: request.id, code: .dumpFailed, message: "offscreen render failed"
            )
        }
        return WireResponse.ok(id: request.id, result: ["path": path])
    }

    private func revisionMismatch(_ request: WireRequest, actual: UInt64, asserted: UInt64) -> Data {
        WireResponse.failure(
            id: request.id, code: .revisionMismatch,
            message: "buffer is at revision \(actual), request asserted \(asserted)",
            extras: ["expected": asserted, "actual": actual]
        )
    }

    private func failure(for error: ResolveError, id: Int?) -> Data {
        switch error {
        case .invalidRequest(let message):
            return WireResponse.failure(id: id, code: .invalidRequest, message: message)
        case .noMatch(let old):
            return WireResponse.failure(
                id: id, code: .noMatch,
                message: "old text not found", extras: ["old": old]
            )
        case .nonUniqueMatch(let old, let count, let offsets):
            return WireResponse.failure(
                id: id, code: .nonUniqueMatch,
                message: "old text occurs \(count) times; add context or pass all:true",
                extras: ["old": old, "count": count, "offsets": offsets]
            )
        case .invalidRange(let start, let end, let bytes):
            return WireResponse.failure(
                id: id, code: .invalidRange,
                message: "range [\(start), \(end)) exceeds \(bytes) bytes",
                extras: ["bytes": bytes]
            )
        }
    }

    private func failure(for error: SourceEditError, id: Int?) -> Data {
        switch error {
        case .spanOutOfBounds(let index):
            return WireResponse.failure(
                id: id, code: .invalidRange, message: "edit \(index) out of bounds",
                extras: ["index": index]
            )
        case .overlappingEdits(let index):
            return WireResponse.failure(
                id: id, code: .overlappingEdits, message: "edit \(index) overlaps another",
                extras: ["index": index]
            )
        case .notCharacterBoundary(let offset):
            return WireResponse.failure(
                id: id, code: .invalidRange,
                message: "offset \(offset) splits a UTF-8 character",
                extras: ["offset": offset]
            )
        case .invalidReplacementUTF8(let index):
            return WireResponse.failure(
                id: id, code: .invalidUTF8, message: "edit \(index) replacement is not valid UTF-8",
                extras: ["index": index]
            )
        }
    }
}

// MARK: - Transport (off-main)

/// Owns the listener fd, the serial queue, and every connection. Nonisolated
/// end to end; the only main-actor touchpoint is the per-connection consumer
/// Task calling `handler`.
nonisolated private final class EditServerTransport: @unchecked Sendable {
    private let listenerFD: Int32
    private let socketPath: String
    private let handler: @MainActor (WireRequest) async -> Data
    private let queue = DispatchQueue(label: "com.xylophonexyz.kamacite.editserver", qos: .utility)
    private var listenerSource: (any DispatchSourceRead)?
    // Guarded by `queue`.
    private var connections: [Int32: Connection] = [:]

    init(listenerFD: Int32, socketPath: String, handler: @escaping @MainActor (WireRequest) async -> Data) {
        self.listenerFD = listenerFD
        self.socketPath = socketPath
        self.handler = handler
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.activate()
        listenerSource = source
    }

    func shutdown() {
        queue.async { [self] in
            listenerSource?.cancel()
            listenerSource = nil
            close(listenerFD)
            for connection in connections.values {
                connection.teardownLocked()
            }
            connections.removeAll()
            unlink(socketPath)
        }
    }

    /// fd ownership + framing + outbound writes for one client. All state
    /// guarded by the transport queue.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        var framer = LineFramer()
        var readSource: (any DispatchSourceRead)?
        let requests: AsyncStream<DecodedRequest>
        let continuation: AsyncStream<DecodedRequest>.Continuation
        /// Guards every write: a consumer Task can outlive the client (its
        /// handler was suspended when the peer vanished), and by then the fd
        /// NUMBER may be a recycled descriptor — another client's socket, or
        /// worse, some unrelated file. Never write through a closed
        /// connection.
        var closed = false
        /// Requests yielded but not yet answered — the backpressure signal.
        var pending = 0

        init(fd: Int32) {
            self.fd = fd
            (requests, continuation) = AsyncStream.makeStream(of: DecodedRequest.self)
        }

        func sendLocked(_ data: Data) {
            guard !closed else { return }
            let intact = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    // The fd is BLOCKING (acceptPending clears the inherited
                    // O_NONBLOCK): a failed write is a dead peer, not EAGAIN.
                    // Treating EAGAIN as gone would silently truncate any
                    // response past the ~8KB unix-socket send buffer.
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            if !intact {
                // Half a line may be on the wire; the stream can never be
                // trusted again. Tear down rather than desync the framing.
                teardownLocked()
            }
        }

        func teardownLocked() {
            guard !closed else { return }
            closed = true
            continuation.finish()
            // Per libdispatch rules the fd must stay valid until the source's
            // cancellation completes; the cancel handler owns the close. A
            // suspended source (backpressure) must be resumed before cancel.
            if let readSource {
                if pending >= maxPendingRequests { readSource.resume() }
                let fd = self.fd
                readSource.setCancelHandler { close(fd) }
                readSource.cancel()
                self.readSource = nil
            } else {
                close(fd)
            }
        }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else { return }
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            // Accepted sockets INHERIT the listener's O_NONBLOCK on Darwin;
            // sendLocked's correctness depends on blocking semantics.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)
            let connection = Connection(fd: fd)
            connections[fd] = connection
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.readPending(connection)
            }
            source.activate()
            connection.readSource = source
            startConsumer(for: connection)
        }
    }

    private func readPending(_ connection: Connection) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        let count = read(connection.fd, &buffer, buffer.count)
        guard count > 0 else {
            connections.removeValue(forKey: connection.fd)
            connection.teardownLocked()
            return
        }
        for line in connection.framer.append(Data(buffer[0..<count])) {
            switch line {
            case .line(let data):
                connection.pending += 1
                if connection.pending == maxPendingRequests {
                    connection.readSource?.suspend()
                }
                connection.continuation.yield(decodeWireRequest(data))
            case .tooLarge:
                connection.sendLocked(WireResponse.failure(
                    id: nil, code: .tooLarge,
                    message: "request line exceeds \(connection.framer.maxLineBytes) bytes"
                ))
            }
        }
    }

    private func startConsumer(for connection: Connection) {
        let handler = self.handler
        let queue = self.queue
        Task { @MainActor in
            for await decoded in connection.requests {
                let response: Data
                switch decoded {
                case .invalid(let errorResponse):
                    response = errorResponse
                case .request(let request):
                    response = await handler(request)
                }
                queue.async {
                    connection.sendLocked(response)
                    connection.pending -= 1
                    if connection.pending == maxPendingRequests - 1, !connection.closed {
                        connection.readSource?.resume()
                    }
                }
            }
        }
    }
}

/// Reads pause above this many unanswered requests per connection — a
/// flooding client backs up in its own socket buffer instead of growing an
/// unbounded AsyncStream buffer in the app.
private nonisolated let maxPendingRequests = 64

// MARK: - Single instance

/// Launch Services keeps one instance per app BUNDLE — but a dev build in a
/// workspace and a stale copy in /Applications are two bundles with one
/// bundle ID, so each accumulates its own windows of the same files. The
/// edit socket is the cross-copy rendezvous: a launching instance that finds
/// it owned by a live process forwards its documents through the `open`
/// verb and exits, making "one process" true regardless of which copy or
/// entry point the open came through. Bench instances are exempt (they run
/// beside the resident app by design).
enum SingleInstance {
    static func anotherInstanceOwnsSocket() -> Bool {
        let path = SocketPath.resolve()
        guard FileManager.default.fileExists(atPath: path),
              let fd = unixConnect(path: path) else { return false }
        close(fd)
        return true
    }

    /// Forward document opens to the socket-owning instance. False (the
    /// owner died between probe and forward) means the caller should fall
    /// back to opening locally.
    static func forward(urls: [URL]) -> Bool {
        guard let fd = unixConnect(path: SocketPath.resolve()) else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        for url in urls {
            guard var payload = try? JSONEncoder().encode(
                WireRequest(cmd: "open", doc: url.standardizedFileURL.path)
            ) else { return false }
            payload.append(0x0A)
            let sent = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            // Await the response line: the window must exist before this
            // process exits, or a fast quit could strand the open.
            guard sent, awaitResponseLine(fd) else { return false }
        }
        return true
    }

    /// The forwarded windows opened without stealing focus; a user-initiated
    /// launch expects the app frontmost, so hand focus to the owner.
    static func activateExistingInstance() {
        let ours = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.xylophonexyz.kamacite"
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != ours {
            app.activate()
            return
        }
    }

    private static func awaitResponseLine(_ fd: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return false }
            if buffer[0..<count].contains(0x0A) { return true }
        }
    }
}

// MARK: - Unix socket helpers (shared with the CLI's client by shape, not code)

func withUnixAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let copied = path.withCString { cString -> Bool in
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard path.utf8.count < raw.count else { return false }
            raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                .update(from: cString, count: path.utf8.count + 1)
            return true
        }
    }
    guard copied else { return nil }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

/// Blocking connect; returns the fd or nil.
func unixConnect(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let result = withUnixAddress(path: path) { pointer, size in
        connect(fd, pointer, size)
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// Deterministic content hash for `status --hash` (Hasher is seed-randomized
/// per process; agents want stability across calls).
private func fnv1a64(_ data: Data) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}
