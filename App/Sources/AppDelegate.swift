import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bench: BenchArguments
    private let recentsDelegate = RecentDocumentsMenuDelegate()

    init(bench: BenchArguments) {
        self.bench = bench
        super.init()
    }

    /// True when another live instance owns the edit socket: this launch
    /// forwards its documents there and exits instead of accumulating a
    /// parallel set of windows (see SingleInstance).
    private var forwardToExistingInstance = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The menu must exist before activation; building it in code is <1ms.
        NSApp.mainMenu = MainMenuBuilder.build(recents: recentsDelegate)
        // One connect() probe (ENOENT in the common case) — cheap enough for
        // the measured cold path, and it must run before any open arrives.
        if !bench.benchMode {
            forwardToExistingInstance = SingleInstance.anotherInstanceOwnsSocket()
        }
    }

    // Files arrive here from Launch Services (Finder, `open`, the vw CLI). For
    // launch-opens this fires BEFORE applicationDidFinishLaunching, so nothing on
    // this path may depend on didFinishLaunching having run.
    func application(_ application: NSApplication, open urls: [URL]) {
        if forwardToExistingInstance {
            if SingleInstance.forward(urls: urls) {
                return // didFinishLaunching terminates this process
            }
            forwardToExistingInstance = false // owner died mid-launch; open locally
        }
        DocumentController.shared.open(urls: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if forwardToExistingInstance {
            if let file = bench.file, !SingleInstance.forward(urls: [file]) {
                // Owner died between probe and forward: serve locally after all.
                forwardToExistingInstance = false
            }
        }
        if forwardToExistingInstance {
            SingleInstance.activateExistingInstance()
            NSApp.terminate(nil)
            return
        }
        if let file = bench.file {
            // Direct-binary open (bench or plain argv) — no odoc event.
            DocumentController.shared.open(urls: [file])
        } else if bench.benchMode {
            DocumentController.shared.openBlankWindow()  // shell-only baseline
        } else if !DocumentController.shared.hasWindows {
            DocumentController.shared.showOpenPanel()
        }
        NSApp.activate()

        // The edit server starts well after first present — the cold-open
        // gate's window must never contain socket setup — and never in bench
        // mode (a bench instance beside the resident app must not steal the
        // live socket).
        if !bench.benchMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                EditServer.shared.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EditServer.shared.stop()
    }

    // Resident process: the next `vw file.md` is an odoc to this instance — the
    // sub-100ms warm-open path. Quit stays explicit (⌘Q).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Quit with uncommitted buffers: the same Commit/Discard/Cancel triad as
    // window close, walked one window at a time; any Cancel keeps the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = DocumentController.shared.windowControllers.filter {
            $0.engineView?.isDirty == true
        }
        guard !dirty.isEmpty else { return .terminateNow }
        promptSequentially(dirty[...])
        return .terminateLater
    }

    private func promptSequentially(_ remaining: ArraySlice<DocumentWindowController>) {
        guard let controller = remaining.first else {
            // The edit server stays live during the prompts: new edits may
            // have dirtied windows (including ones just committed). Re-scan
            // until the set is empty — terminating would silently drop them.
            let dirty = DocumentController.shared.windowControllers.filter {
                $0.engineView?.isDirty == true
            }
            if dirty.isEmpty {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                promptSequentially(dirty[...])
            }
            return
        }
        guard controller.engineView?.isDirty == true else {
            promptSequentially(remaining.dropFirst()) // became clean meanwhile
            return
        }
        controller.showWindow(nil)
        controller.confirmUnsavedChanges { [weak self] proceed in
            if proceed {
                self?.promptSequentially(remaining.dropFirst())
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
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
