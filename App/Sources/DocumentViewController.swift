import AppKit

final class DocumentViewController: NSViewController {
    let document: Document?

    init(document: Document?) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("vw builds UI in code; no archives")
    }

    override func loadView() {
        // Placeholder surface — replaced by VWViewer.DocumentEngineView when the
        // Metal renderer lands (P2).
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
    }
}
