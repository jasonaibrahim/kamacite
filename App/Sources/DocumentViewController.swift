import AppKit
import VWStyle
import VWViewer

final class DocumentViewController: NSViewController {
    let document: Document?
    private(set) var engineView: DocumentEngineView?

    init(document: Document?) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("vw builds UI in code; no archives")
    }

    override func loadView() {
        guard let document else {
            // Blank window (bench baseline, open-panel host).
            view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
            return
        }
        let engine = DocumentEngineView(data: document.data, theme: Self.currentTheme())
        engine.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
        engine.baseURL = document.url
        engine.onOpenLink = { url in
            // Markdown links to markdown files stay in vw; everything else
            // goes to the system handler.
            if url.isFileURL,
               ["md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "markdn"]
                   .contains(url.pathExtension.lowercased()) {
                DocumentController.shared.open(url: url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        engineView = engine
        view = engine
    }

    /// Follows the system appearance at open; live flipping is P8.
    private static func currentTheme() -> Theme {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return appearance == .darkAqua ? .dark : .light
    }
}
