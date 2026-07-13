import AppKit

// The kama CLI. Lives at Kamacite.app/Contents/Helpers/kama and is symlinked onto PATH.
//
// Opens files in the exact app bundle it ships inside — self-locating, so multiple
// installed copies (DerivedData build + /Applications) never ambiguate — and reuses a
// running instance via Launch Services. That reuse IS the warm-open fast path.

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

var perf = false
var paths: [String] = []

for argument in CommandLine.arguments.dropFirst() {
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
        print("""
        usage: kama [--perf] <file.md> …
               kama --version

          --perf   print open/render phase timings to stderr (fresh launch only)
        """)
        exit(0)
    default:
        paths.append(argument)
    }
}

guard !paths.isEmpty else {
    fail("usage: kama [--perf] <file.md> …", code: 64)
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
