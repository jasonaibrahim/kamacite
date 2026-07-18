import AppKit
import UniformTypeIdentifiers

/// Lightweight document controller — deliberately not NSDocument: its async,
/// file-coordinated open path (multiple runloop hops, filecoordinationd IPC) fights the
/// content-before-visibility first frame. The model stays UI-free so a future editing
/// version can adopt NSDocument (or not) without rework. Open Recent works without it
/// via NSDocumentController.shared's recents list.
final class DocumentController: NSObject {
    static let shared = DocumentController()

    private(set) var windowControllers: [DocumentWindowController] = []

    var hasWindows: Bool { !windowControllers.isEmpty }

    func open(urls: [URL]) {
        for url in urls { open(url: url) }
    }

    func open(url: URL) {
        do {
            try openWindow(url: url)
        } catch {
            presentOpenFailure(url: url, error: error)
        }
    }

    /// The one open path, UI-error-free so the edit server can catch into a
    /// structured error instead of an alert.
    @discardableResult
    func openWindow(url: URL) throws -> DocumentWindowController {
        // One window per document: re-opening (Finder, CLI, recents) focuses
        // the existing window instead of duplicating it.
        if let existing = controller(for: url) {
            existing.showWindow(nil)
            return existing
        }

        let trace = PerfReporter.shared.beginTrace(label: url.lastPathComponent)
        let document: Document
        do {
            document = try Document(url: url)
        } catch {
            PerfReporter.shared.openFailed(trace)
            throw error
        }
        trace.bytes = document.data.count
        trace.mark("read")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let controller = DocumentWindowController(document: document)
        show(controller, trace: trace)
        return controller
    }

    /// Window viewing the given file, matched by path OR file identity —
    /// standardizedFileURL doesn't resolve symlinks, so the same inode
    /// reached through two spellings must not get two windows. Identity is
    /// resolved fresh on both sides at comparison time (a commit's atomic
    /// rename changes the inode; caching would go stale).
    func controller(for url: URL) -> DocumentWindowController? {
        let standardized = url.standardizedFileURL.path
        let identity = fileIdentity(url)
        return windowControllers.first { controller in
            guard let documentURL = controller.viewedDocument?.url else { return false }
            if documentURL.standardizedFileURL.path == standardized { return true }
            guard let identity, let documentIdentity = fileIdentity(documentURL) else { return false }
            return identity.isEqual(documentIdentity)
        }
    }

    private func fileIdentity(_ url: URL) -> (NSCopying & NSSecureCoding & NSObjectProtocol)? {
        // Resolve symlinks first: resource values describe the item AT the
        // URL, and a symlink's own identifier is not its target's.
        (try? url.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }

    /// Bench baseline: an empty window with no document — measures the shell alone.
    func openBlankWindow() {
        let trace = PerfReporter.shared.beginTrace(label: "(blank)")
        show(DocumentWindowController(document: nil), trace: trace)
    }

    private func show(_ controller: DocumentWindowController, trace: OpenTrace) {
        windowControllers.append(controller)
        trace.mark("window")

        if let engineView = controller.engineView {
            // Content before visibility: the engine parses, lays out, encodes,
            // and presents within the current transaction; the window's first
            // on-screen commit already contains rendered markdown. The glass
            // timestamp comes from MTLDrawable.addPresentedHandler.
            engineView.prepareFirstFrame(
                mark: { trace.mark($0) },
                presented: { presentedTime in
                    Task { @MainActor in
                        trace.mark("present", at: presentedTime)
                        PerfReporter.shared.presented(trace)
                    }
                }
            )
            controller.showWindow(nil)
        } else {
            // Blank window (bench baseline): CATransaction completion stays the
            // present proxy — there is no drawable to ask.
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                trace.mark("present")
                PerfReporter.shared.presented(trace)
            }
            controller.showWindow(nil)
            CATransaction.commit()
        }
    }

    func remove(_ controller: DocumentWindowController) {
        windowControllers.removeAll { $0 === controller }
    }

    @objc func openDocument(_ sender: Any?) {
        showOpenPanel()
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openableTypes
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(urls: panel.urls)
        }
    }

    private static let openableTypes: [UTType] = {
        var types = ["md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "markdn"]
            .compactMap { UTType(filenameExtension: $0) }
        types.append(.plainText)
        return types
    }()

    private func presentOpenFailure(url: URL, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Can’t open “\(url.lastPathComponent)”"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
