import Foundation
import VWLayout
import VWParse
import VWStyle

/// Owns one document's pipeline state: bytes → ContentTree → FlatDocument →
/// LazyLayout. Parse/flatten happen once; layout is viewport-lazy and reflows
/// on width/scale changes. All main-actor.
@MainActor
public final class DocumentSession {
    public let data: Data
    public private(set) var theme: Theme
    public private(set) var fonts: FontTable
    public private(set) var document: FlatDocument?
    public private(set) var layout: LazyLayout?

    /// Fired when async work (syntax highlighting) changed content that's
    /// already on glass — the view re-renders.
    public var onContentUpdate: (() -> Void)?
    private var highlightRequested: Set<Int> = []

    public init(data: Data, theme: Theme) {
        self.data = data
        self.theme = theme
        self.fonts = FontTable(metrics: theme.metrics)
    }

    /// Parse/flatten once, then create (or reflow) the lazy layout. `mark`
    /// receives "parse"/"style"/"estimate" on the passes that ran.
    public func prepare(contentWidth: CGFloat, scale: CGFloat, mark: ((String) -> Void)? = nil) {
        if document == nil {
            let tree = parseMarkdown(data: data)
            mark?("parse")
            document = flatten(tree)
            mark?("style")
        }
        guard let document else { return }

        if let layout {
            layout.reflow(contentWidth: contentWidth, scale: scale)
        } else {
            layout = LazyLayout(
                document: document, fonts: fonts, metrics: theme.metrics,
                contentWidth: contentWidth, scale: scale
            )
            mark?("estimate")
        }
    }

    // MARK: - Async syntax highlighting

    /// Kick off highlighting for any visible code blocks that haven't been
    /// done yet. Lexing runs detached (user-sanctioned async — first paint
    /// shows plain code); results are color-only, so applying them re-shapes
    /// one block without moving layout.
    public func requestHighlights(for blocks: [BlockLayout]) {
        guard let document else { return }
        for placed in blocks where placed.kind == .codeBlock {
            let index = placed.flatIndex
            guard !highlightRequested.contains(index),
                  document.blocks.indices.contains(index) else { continue }
            let block = document.blocks[index]
            guard let language = block.codeLanguage, !language.isEmpty,
                  let plainRun = block.runs.first, block.runs.count == 1
            else {
                highlightRequested.insert(index)
                continue
            }
            highlightRequested.insert(index)
            let code = plainRun.text
            // The plain run's span is the byte-verified content span; tokens
            // inherit exact sub-spans so partial source copy stays byte-exact.
            let contentSpan = plainRun.span
            Task.detached(priority: .utility) { [weak self] in
                guard let runs = highlightCode(code, language: language, contentSpan: contentSpan) else { return }
                await self?.applyHighlight(index: index, runs: runs)
            }
        }
    }

    private func applyHighlight(index: Int, runs: [StyledRun]) {
        guard document != nil, document!.blocks.indices.contains(index) else { return }
        // Keep the session's copy (selection copy paths) and the layout's copy
        // (shaping) in sync.
        document!.blocks[index].runs = runs
        layout?.replaceRuns(at: index, with: runs)
        onContentUpdate?()
    }

    /// Palette-only theme swap: same metrics ⇒ same layout, pure re-render
    /// (the atlas lazily rasterizes flipped-polarity masks as needed). A theme
    /// with different metrics tears down layout — that's a font-size change,
    /// not an appearance flip.
    public func setTheme(_ newTheme: Theme) {
        let metricsChanged = newTheme.metrics != theme.metrics
        theme = newTheme
        if metricsChanged {
            fonts = FontTable(metrics: newTheme.metrics)
            layout = nil
        }
    }
}
