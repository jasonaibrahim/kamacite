import AppKit

// The vw CLI. Lives at vw.app/Contents/Helpers/vw and is symlinked onto PATH.
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
    // …/vw.app/Contents/Helpers/vw → three levels up is the bundle.
    let candidate = invoked
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    if candidate.pathExtension == "app" {
        return candidate
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.xylophonexyz.vw")
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
            fail("vw: cannot locate vw.app to determine version", code: 66)
        }
        print("vw \(version)")
        exit(0)
    case "--perf":
        perf = true
    case "--help", "-h":
        print("""
        usage: vw [--perf] <file.md> …
               vw --version

          --perf   print open/render phase timings to stderr (fresh launch only)
        """)
        exit(0)
    default:
        paths.append(argument)
    }
}

guard !paths.isEmpty else {
    fail("usage: vw [--perf] <file.md> …", code: 64)
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let urls: [URL] = paths.map { path in
    let url = URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("vw: no such file: \(path)", code: 1)
    }
    return url
}

guard let appURL = locateAppBundle() else {
    fail("vw: cannot locate vw.app (expected to run from vw.app/Contents/Helpers)", code: 66)
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.addsToRecentItems = true
if perf {
    // Environment applies only when this open launches a fresh instance.
    configuration.environment = ["VW_PERF": "1"]
}

nonisolated(unsafe) var openError: String?
NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
    openError = error?.localizedDescription
    CFRunLoopStop(CFRunLoopGetMain())
}
// Completion arrives on an arbitrary queue; park the main runloop rather than
// blocking on a semaphore (safe regardless of which queue LS calls back on).
if CFRunLoopRunInMode(.defaultMode, 15, false) != .stopped {
    fail("vw: timed out waiting for Launch Services", code: 65)
}
if let openError {
    fail("vw: \(openError)", code: 65)
}
exit(0)
