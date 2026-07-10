import Testing
import VWCore

@Test func sourceSpanLength() {
    let span = SourceSpan(startUTF8: 3, endUTF8: 9)
    #expect(span.length == 6)
    #expect(!span.isEmpty)
    #expect(SourceSpan(startUTF8: 4, endUTF8: 4).isEmpty)
}

@Test func textPositionOrdersByBlockThenOffset() {
    let a = TextPosition(blockIndex: 1, utf16Offset: 40)
    let b = TextPosition(blockIndex: 2, utf16Offset: 0)
    let c = TextPosition(blockIndex: 2, utf16Offset: 7)
    #expect(a < b)
    #expect(b < c)
    #expect(!(c < a))
}
