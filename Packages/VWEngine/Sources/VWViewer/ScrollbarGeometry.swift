import CoreGraphics

/// Pure knob math for the overlay scrollbar — kept AppKit-free so it's
/// unit-testable. All values in view points, y-down.
struct ScrollbarGeometry {
    static let normalWidth: CGFloat = 6
    static let expandedWidth: CGFloat = 9
    static let edgeInset: CGFloat = 3
    static let endInset: CGFloat = 4
    static let minKnobHeight: CGFloat = 24
    /// Hover zone measured from the right edge.
    static let hotZoneWidth: CGFloat = 18

    let trackRect: CGRect
    let knobRect: CGRect
    /// Scroll points per knob point — converts knob drags to scroll offsets.
    let scrollPerKnobPoint: CGFloat

    /// nil when the content fits (no scrolling, no scrollbar).
    init?(
        viewSize: CGSize,
        contentHeight: CGFloat,
        scrollOffset: CGFloat,
        maxScroll: CGFloat,
        expanded: Bool
    ) {
        guard maxScroll > 0.5, viewSize.height > Self.minKnobHeight + Self.endInset * 2 else {
            return nil
        }

        let width = expanded ? Self.expandedWidth : Self.normalWidth
        let trackHeight = viewSize.height - Self.endInset * 2

        // Knob height is proportional to the visible fraction, floored so it
        // stays grabbable on huge documents.
        let visibleFraction = min(1, viewSize.height / max(contentHeight, 1))
        var knobHeight = max(Self.minKnobHeight, trackHeight * visibleFraction)

        // Rubber-band overscroll compresses the knob against the end,
        // exactly like system scrollers.
        let overshoot: CGFloat
        if scrollOffset < 0 {
            overshoot = -scrollOffset
        } else if scrollOffset > maxScroll {
            overshoot = scrollOffset - maxScroll
        } else {
            overshoot = 0
        }
        knobHeight = max(Self.minKnobHeight * 0.5, knobHeight - overshoot)

        let knobRange = trackHeight - knobHeight
        let ratio = min(1, max(0, maxScroll > 0 ? scrollOffset / maxScroll : 0))
        let knobY = Self.endInset + knobRange * ratio

        trackRect = CGRect(
            x: viewSize.width - Self.hotZoneWidth,
            y: 0,
            width: Self.hotZoneWidth,
            height: viewSize.height
        )
        knobRect = CGRect(
            x: viewSize.width - width - Self.edgeInset,
            y: knobY,
            width: width,
            height: knobHeight
        )
        scrollPerKnobPoint = knobRange > 0 ? maxScroll / knobRange : 0
    }

    /// Scroll offset that centers the knob at `y` (jump-to-spot track clicks).
    func scrollOffsetCenteringKnob(atY y: CGFloat, maxScroll: CGFloat) -> CGFloat {
        let knobRange = trackRect.height - Self.endInset * 2 - knobRect.height
        guard knobRange > 0 else { return 0 }
        let targetKnobY = y - knobRect.height / 2 - Self.endInset
        return min(max(0, targetKnobY / knobRange * maxScroll), maxScroll)
    }
}
