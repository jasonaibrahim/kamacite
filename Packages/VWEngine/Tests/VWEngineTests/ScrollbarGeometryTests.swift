import CoreGraphics
import Testing
@testable import VWViewer

@Suite struct ScrollbarGeometryTests {
    private let view = CGSize(width: 800, height: 600)

    @Test func hiddenWhenContentFits() {
        let geometry = ScrollbarGeometry(
            viewSize: view, contentHeight: 400, scrollOffset: 0, maxScroll: 0, expanded: false
        )
        #expect(geometry == nil)
    }

    @Test func knobIsProportionalAndTracksScroll() {
        let contentHeight: CGFloat = 2400 // 4 screens
        let maxScroll = contentHeight - view.height
        let top = ScrollbarGeometry(
            viewSize: view, contentHeight: contentHeight, scrollOffset: 0,
            maxScroll: maxScroll, expanded: false
        )!
        // ~1/4 visible → knob ~1/4 of the track.
        #expect(abs(top.knobRect.height - (view.height - 8) / 4) < 2)
        #expect(top.knobRect.minY == ScrollbarGeometry.endInset)
        #expect(top.knobRect.width == ScrollbarGeometry.normalWidth)

        let bottom = ScrollbarGeometry(
            viewSize: view, contentHeight: contentHeight, scrollOffset: maxScroll,
            maxScroll: maxScroll, expanded: true
        )!
        #expect(abs(bottom.knobRect.maxY - (view.height - ScrollbarGeometry.endInset)) < 0.5)
        #expect(bottom.knobRect.width == ScrollbarGeometry.expandedWidth)

        let middle = ScrollbarGeometry(
            viewSize: view, contentHeight: contentHeight, scrollOffset: maxScroll / 2,
            maxScroll: maxScroll, expanded: false
        )!
        let expectedMid = (top.knobRect.minY + bottom.knobRect.minY) / 2
        #expect(abs(middle.knobRect.minY - expectedMid) < 1)
    }

    @Test func hugeDocumentKnobFloorsAtMinimum() {
        let geometry = ScrollbarGeometry(
            viewSize: view, contentHeight: 1_000_000, scrollOffset: 0,
            maxScroll: 999_400, expanded: false
        )!
        #expect(geometry.knobRect.height == ScrollbarGeometry.minKnobHeight)
    }

    @Test func overscrollCompressesKnob() {
        let contentHeight: CGFloat = 2400
        let maxScroll = contentHeight - view.height
        let resting = ScrollbarGeometry(
            viewSize: view, contentHeight: contentHeight, scrollOffset: 0,
            maxScroll: maxScroll, expanded: false
        )!
        let rubberBanded = ScrollbarGeometry(
            viewSize: view, contentHeight: contentHeight, scrollOffset: -40,
            maxScroll: maxScroll, expanded: false
        )!
        #expect(rubberBanded.knobRect.height < resting.knobRect.height)
        // Pinned to the top while overscrolling past it.
        #expect(rubberBanded.knobRect.minY == ScrollbarGeometry.endInset)
    }

    @Test func dragConversionRoundTrips() {
        let contentHeight: CGFloat = 6000
        let maxScroll = contentHeight - view.height
        let geometry = ScrollbarGeometry(
            viewSize: view, contentHeight: contentHeight, scrollOffset: 0,
            maxScroll: maxScroll, expanded: false
        )!
        // Moving the knob through its whole range covers the whole document.
        let knobRange = view.height - ScrollbarGeometry.endInset * 2 - geometry.knobRect.height
        #expect(abs(knobRange * geometry.scrollPerKnobPoint - maxScroll) < 0.5)
    }

    @Test func jumpToSpotCentersKnob() {
        let contentHeight: CGFloat = 6000
        let maxScroll = contentHeight - view.height
        let geometry = ScrollbarGeometry(
            viewSize: view, contentHeight: contentHeight, scrollOffset: 0,
            maxScroll: maxScroll, expanded: false
        )!
        let middle = geometry.scrollOffsetCenteringKnob(atY: view.height / 2, maxScroll: maxScroll)
        #expect(abs(middle - maxScroll / 2) < maxScroll * 0.02)
        #expect(geometry.scrollOffsetCenteringKnob(atY: 0, maxScroll: maxScroll) == 0)
        #expect(geometry.scrollOffsetCenteringKnob(atY: view.height, maxScroll: maxScroll) == maxScroll)
    }
}
