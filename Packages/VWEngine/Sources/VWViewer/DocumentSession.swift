import Foundation
import VWLayout
import VWParse
import VWStyle

/// Owns one document's pipeline state: bytes → ContentTree → FlatDocument →
/// DocumentLayout. Parse/flatten happen once; layout re-runs per
/// (content width, scale). All on the main actor in P2 — the background
/// prewarmer arrives with lazy layout in P3.
@MainActor
public final class DocumentSession {
    public let data: Data
    public var theme: Theme {
        didSet { fonts = FontTable(metrics: theme.metrics) }
    }
    public private(set) var fonts: FontTable

    private var flat: FlatDocument?
    public private(set) var layout: DocumentLayout?
    private var layoutKey: (width: CGFloat, scale: CGFloat)?

    public init(data: Data, theme: Theme) {
        self.data = data
        self.theme = theme
        self.fonts = FontTable(metrics: theme.metrics)
    }

    /// Idempotent per (width, scale). `mark` receives "parse"/"style"/"layout"
    /// phase names for the perf trace on the first pass.
    public func prepare(contentWidth: CGFloat, scale: CGFloat, mark: ((String) -> Void)? = nil) {
        if flat == nil {
            let tree = parseMarkdown(data: data)
            mark?("parse")
            flat = flatten(tree)
            mark?("style")
        }
        guard let flat else { return }

        if let key = layoutKey, key.width == contentWidth, key.scale == scale {
            return
        }
        layout = layoutDocument(
            flat, fonts: fonts, metrics: theme.metrics,
            contentWidth: contentWidth, scale: scale
        )
        layoutKey = (contentWidth, scale)
        mark?("layout")
    }

    /// Force the next prepare() to re-run layout (theme/font changes).
    public func invalidateLayout() {
        layoutKey = nil
    }
}
