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
