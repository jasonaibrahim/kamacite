import AppKit
import VWStyle
import VWViewer

final class DocumentViewController: NSViewController {
    let document: Document?
    private(set) var engineView: DocumentEngineView?
    private var checkedForMermaid = false

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
        engine.diagramRenderer = MermaidRenderer.shared
        engineView = engine
        view = engine
    }

    /// Post-present, off the first-frame path: if the document contains a
    /// mermaid fence, pre-warm the WebKit rasterizer so the first visible
    /// diagram pays only its own render. The byte scan runs off-main — the
    /// data may be a 100MB mmap.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !checkedForMermaid, let document else { return }
        checkedForMermaid = true
        Task.detached(priority: .utility) { [data = document.data] in
            guard data.range(of: Data("```mermaid".utf8)) != nil else { return }
            await MermaidRenderer.shared.warmUp()
        }
    }

    /// Follows the system appearance at open; live flipping is P8.
    private static func currentTheme() -> Theme {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return appearance == .darkAqua ? .dark : .light
    }
}
