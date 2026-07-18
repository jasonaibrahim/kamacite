import AppKit
import VWEditCore

// The client half of the edit protocol: blocking BSD socket, one JSON line
// out, one JSON line back, printed verbatim to stdout (agents parse it; the
// jq-curious pipe it). Exit codes: 0 ok, 1 server-reported error,
// 2 transport failure, 64 usage.

enum EditClient {
    static let receiveTimeout: TimeInterval = 10

    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard copied, withUnsafePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// One request/response round trip over an open fd.
    static func roundTrip(fd: Int32, request: WireRequest) -> Data? {
        guard var payload = try? JSONEncoder().encode(request) else { return nil }
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard sent else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                response.append(contentsOf: buffer[0..<newline])
                return response
            }
            response.append(contentsOf: buffer[0..<count])
        }
    }

    /// Send one request; print the response line; exit accordingly.
    /// `autoOpen` (the `edit` ergonomics): if the socket answers but the doc
    /// isn't open, open it first; if the socket is absent, launch the app via
    /// Launch Services (the existing warm path) and poll-connect.
    /// `rawField` prints just that result field on success (`read --raw`).
    static func run(request: WireRequest, autoOpen: Bool, rawField: String? = nil) -> Never {
        let path = SocketPath.resolve()
        var fd = connect(path: path)

        if fd == nil, autoOpen, let doc = request.doc {
            launchAppAndWait(open: doc)
            for _ in 0..<50 {
                if let connected = connect(path: path) {
                    fd = connected
                    break
                }
                usleep(100_000)
            }
        }
        guard let fd else {
            fail("kama: cannot reach the Kamacite edit server at \(path) — is the app running?", code: 2)
        }
        defer { close(fd) }

        if autoOpen, let doc = request.doc {
            // Idempotent (already_open in the result); FIFO on this
            // connection guarantees it lands before the main request.
            guard let openResponse = roundTrip(
                fd: fd, request: WireRequest(cmd: "open", doc: doc)
            ) else {
                fail("kama: connection dropped during open", code: 2)
            }
            if !isOK(openResponse) {
                emit(openResponse)
                exit(1)
            }
        }

        guard let response = roundTrip(fd: fd, request: request) else {
            fail("kama: connection dropped (server timeout is \(Int(receiveTimeout))s)", code: 2)
        }
        if isOK(response) {
            if let rawField,
               let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
               let value = (object["result"] as? [String: Any])?[rawField] {
                print(value)
            } else {
                emit(response)
            }
            exit(0)
        }
        emit(response)
        exit(1)
    }

    private static func isOK(_ response: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: response)) as? [String: Any])?["ok"] as? Bool == true
    }

    private static func emit(_ response: Data) {
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// The existing LS open path (reuses a running instance or launches one).
    private static func launchAppAndWait(open path: String) {
        guard let appURL = locateAppBundle() else {
            fail("kama: cannot locate Kamacite.app", code: 66)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = true
        nonisolated(unsafe) var openError: String?
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: configuration
        ) { _, error in
            openError = error?.localizedDescription
            CFRunLoopStop(CFRunLoopGetMain())
        }
        if CFRunLoopRunInMode(.defaultMode, 15, false) != .stopped {
            fail("kama: timed out waiting for Launch Services", code: 65)
        }
        if let openError {
            fail("kama: \(openError)", code: 65)
        }
    }
}
