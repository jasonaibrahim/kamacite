import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bench: BenchArguments
    private let recentsDelegate = RecentDocumentsMenuDelegate()

    init(bench: BenchArguments) {
        self.bench = bench
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The menu must exist before activation; building it in code is <1ms.
        NSApp.mainMenu = MainMenuBuilder.build(recents: recentsDelegate)
    }

    // Files arrive here from Launch Services (Finder, `open`, the vw CLI). For
    // launch-opens this fires BEFORE applicationDidFinishLaunching, so nothing on
    // this path may depend on didFinishLaunching having run.
    func application(_ application: NSApplication, open urls: [URL]) {
        DocumentController.shared.open(urls: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let file = bench.file {
            // Direct-binary open (bench or plain argv) — no odoc event.
            DocumentController.shared.open(urls: [file])
        } else if bench.benchMode {
            DocumentController.shared.openBlankWindow()  // shell-only baseline
        } else if !DocumentController.shared.hasWindows {
            DocumentController.shared.showOpenPanel()
        }
        NSApp.activate()
    }

    // Resident process: the next `vw file.md` is an odoc to this instance — the
    // sub-100ms warm-open path. Quit stays explicit (⌘Q).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            DocumentController.shared.showOpenPanel()
            return false
        }
        return true
    }
}
