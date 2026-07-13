import AppKit
import VWViewer

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    // Not named `document`: NSWindowController already owns that property for NSDocument.
    let viewedDocument: Document?

    init(document: Document?) {
        self.viewedDocument = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Restoration reads archives at launch — explicitly off, per the speed budget.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.title = document?.url.lastPathComponent ?? "Kamacite"
        window.representedURL = document?.url
        // Any pixel not yet covered by content is theme-colored, never white.
        window.backgroundColor = .textBackgroundColor
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true
        windowFrameAutosaveName = "kamacite.document"
        window.delegate = self
        contentViewController = DocumentViewController(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("vw builds UI in code; no archives")
    }

    var engineView: DocumentEngineView? {
        (contentViewController as? DocumentViewController)?.engineView
    }

    func windowWillClose(_ notification: Notification) {
        DocumentController.shared.remove(self)
    }
}
