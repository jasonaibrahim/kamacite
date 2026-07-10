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
        let trace = PerfReporter.shared.beginTrace(label: url.lastPathComponent)
        let document: Document
        do {
            document = try Document(url: url)
        } catch {
            PerfReporter.shared.openFailed(trace)
            presentOpenFailure(url: url, error: error)
            return
        }
        trace.bytes = document.data.count
        trace.mark("read")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        show(DocumentWindowController(document: document), trace: trace)
    }

    /// Bench baseline: an empty window with no document — measures the shell alone.
    func openBlankWindow() {
        let trace = PerfReporter.shared.beginTrace(label: "(blank)")
        show(DocumentWindowController(document: nil), trace: trace)
    }

    private func show(_ controller: DocumentWindowController, trace: OpenTrace) {
        windowControllers.append(controller)
        trace.mark("window")
        // CATransaction completion is the closest first-present proxy without Metal;
        // replaced by MTLDrawable.addPresentedHandler when the renderer lands (P2).
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            trace.mark("present")
            PerfReporter.shared.presented(trace)
        }
        controller.showWindow(nil)
        CATransaction.commit()
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
