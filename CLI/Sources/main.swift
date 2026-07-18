import AppKit
import VWEditCore

// The kama CLI. Lives at Kamacite.app/Contents/Helpers/kama and is symlinked onto PATH.
//
// Two personalities:
// - `kama file.md …` — the original viewer path: opens files in the exact app
//   bundle it ships inside via Launch Services, reusing a running instance
//   (that reuse IS the warm-open fast path).
// - `kama <verb> file.md …` — the edit protocol client: one JSON line to the
//   app's unix socket, the response line printed verbatim. Exit codes:
//   0 ok, 1 server-reported error, 2 transport failure, 64 usage.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func locateAppBundle() -> URL? {
    let invoked = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    // …/Kamacite.app/Contents/Helpers/kama → three levels up is the bundle.
    let candidate = invoked
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    if candidate.pathExtension == "app" {
        return candidate
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.xylophonexyz.kamacite")
}

let usage = """
usage: kama [--perf] <file.md> …                    open in the viewer
       kama open <file>                             open via the edit server
       kama status <file> [--hash]
       kama read <file> [--range S:E] [--raw]
       kama edit <file> [--revision N] (--old S --new S [--all] |
                                        --range S:E --text T | --stdin-json)
       kama commit <file> [--revision N] [--force]
       kama discard <file>
       kama debug-dump <file> <out.png>
       kama --version

Edits land in the app's in-memory buffer (live preview); the file on disk
changes only on commit. Responses are JSON lines on stdout.
"""

func standardizedPath(_ argument: String, mustExist: Bool) -> String {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let url = URL(fileURLWithPath: argument, relativeTo: cwd).standardizedFileURL
    if mustExist, !FileManager.default.fileExists(atPath: url.path) {
        fail("kama: no such file: \(argument)", code: 1)
    }
    return url.path
}

func parseByteRange(_ text: String) -> [Int] {
    let parts = text.split(separator: ":")
    guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else {
        fail("kama: --range wants S:E byte offsets", code: 64)
    }
    return [start, end]
}

// MARK: - Verb dispatch

let arguments = Array(CommandLine.arguments.dropFirst())

let verbs: Set<String> = ["open", "status", "read", "edit", "commit", "discard", "debug-dump"]
if let verb = arguments.first, verbs.contains(verb) {
    var rest = Array(arguments.dropFirst())
    guard !rest.isEmpty else { fail(usage, code: 64) }
    let doc = standardizedPath(rest.removeFirst(), mustExist: verb == "open" || verb == "edit")

    var request = WireRequest(cmd: verb, doc: doc)
    var raw = false
    var wireEdits: [WireEdit] = []
    var pendingOld: String?
    var pendingNew: String?
    var pendingAll = false
    var pendingRange: [Int]?
    var pendingText: String?

    var index = 0
    while index < rest.count {
        let argument = rest[index]
        func value(_ flag: String) -> String {
            index += 1
            guard index < rest.count else { fail("kama: \(flag) wants a value", code: 64) }
            return rest[index]
        }
        switch argument {
        case "--revision":
            let text = value("--revision")
            guard let parsed = UInt64(text) else {
                // Silently dropping a malformed CAS token would defeat it.
                fail("kama: --revision wants an integer, got \(text)", code: 64)
            }
            request.revision = parsed
        case "--force": request.force = true
        case "--hash": request.hash = true
        case "--raw": raw = true
        case "--all": pendingAll = true
        case "--old": pendingOld = value("--old")
        case "--new": pendingNew = value("--new")
        case "--text": pendingText = value("--text")
        case "--range":
            let range = parseByteRange(value("--range"))
            if verb == "read" { request.range = range } else { pendingRange = range }
        case "--stdin-json":
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let parsed = try? JSONDecoder().decode([WireEdit].self, from: input) else {
                fail("kama: --stdin-json wants a JSON array of edit objects", code: 64)
            }
            wireEdits.append(contentsOf: parsed)
        default:
            if verb == "debug-dump", request.path == nil {
                request.path = standardizedPath(argument, mustExist: false)
            } else {
                fail("kama: unknown argument \(argument)\n\n\(usage)", code: 64)
            }
        }
        index += 1
    }

    if let old = pendingOld, let new = pendingNew {
        wireEdits.append(WireEdit(old: old, new: new, all: pendingAll ? true : nil))
    } else if pendingOld != nil || pendingNew != nil {
        fail("kama: --old and --new go together", code: 64)
    }
    if let range = pendingRange {
        guard let text = pendingText else { fail("kama: --range wants --text", code: 64) }
        wireEdits.append(WireEdit(range: range, text: text))
    } else if pendingText != nil {
        fail("kama: --text wants --range", code: 64)
    }

    switch verb {
    case "edit":
        guard !wireEdits.isEmpty else {
            fail("kama: edit wants --old/--new, --range/--text, or --stdin-json", code: 64)
        }
        request.edits = wireEdits
    case "debug-dump":
        guard request.path != nil else { fail("kama: debug-dump wants an output png path", code: 64) }
    default:
        break
    }

    // `edit` auto-opens (launching the app if needed); queries never pop UI.
    EditClient.run(request: request, autoOpen: verb == "edit", rawField: raw ? "text" : nil)
}

// MARK: - Viewer path (unchanged behavior)

var perf = false
var paths: [String] = []

for argument in arguments {
    switch argument {
    case "--version":
        guard let appURL = locateAppBundle(),
              let version = Bundle(url: appURL)?
                  .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else {
            fail("kama: cannot locate Kamacite.app to determine version", code: 66)
        }
        print("kama \(version)")
        exit(0)
    case "--perf":
        perf = true
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        paths.append(argument)
    }
}

guard !paths.isEmpty else {
    fail(usage, code: 64)
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let urls: [URL] = paths.map { path in
    let url = URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("kama: no such file: \(path)", code: 1)
    }
    return url
}

guard let appURL = locateAppBundle() else {
    fail("kama: cannot locate Kamacite.app (expected to run from Kamacite.app/Contents/Helpers)", code: 66)
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.addsToRecentItems = true

// An LS-launched app's stderr goes to the unified log, not this terminal —
// so --perf hands the app a file to append timings to, and we tail it.
var perfFileURL: URL?
if perf {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kama-perf-\(ProcessInfo.processInfo.processIdentifier).log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    perfFileURL = url
    // Environment applies only when this open launches a fresh instance.
    configuration.environment = ["VW_PERF": "1", "VW_PERF_FILE": url.path]
}

nonisolated(unsafe) var openError: String?
NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
    openError = error?.localizedDescription
    CFRunLoopStop(CFRunLoopGetMain())
}
// Completion arrives on an arbitrary queue; park the main runloop rather than
// blocking on a semaphore (safe regardless of which queue LS calls back on).
if CFRunLoopRunInMode(.defaultMode, 15, false) != .stopped {
    fail("kama: timed out waiting for Launch Services", code: 65)
}
if let openError {
    fail("kama: \(openError)", code: 65)
}

if let perfFileURL {
    defer { try? FileManager.default.removeItem(at: perfFileURL) }
    // Wait for the app to finish its first present and flush (cold opens run
    // a few hundred ms; poll up to 5s).
    var report = ""
    for _ in 0..<50 {
        report = (try? String(contentsOf: perfFileURL, encoding: .utf8)) ?? ""
        if report.contains("first pixel") { break }
        usleep(100_000)
    }
    if report.contains("first pixel") {
        FileHandle.standardError.write(Data(report.utf8))
    } else {
        FileHandle.standardError.write(Data("""
        kama: --perf timings unavailable — Kamacite was already running, so this open \
        reused the warm instance (its environment was fixed at launch). \
        Quit Kamacite and re-run for a fresh-launch measurement.\n
        """.utf8))
    }
}
exit(0)
