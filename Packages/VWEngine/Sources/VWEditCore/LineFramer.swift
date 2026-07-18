import Foundation

/// Newline framing for the socket byte stream. Bytes arrive in arbitrary
/// chunks; complete LF-terminated lines come out (without the LF; a trailing
/// CR is stripped for telnet-style clients). A line over `maxLineBytes` is
/// reported once as `.tooLarge` and its bytes are discarded until the framer
/// resyncs at the next LF.
public struct LineFramer: Sendable {
    public enum Line: Sendable, Equatable {
        case line(Data)
        case tooLarge
    }

    public let maxLineBytes: Int
    private var buffer = Data()
    private var discardingOversized = false

    public init(maxLineBytes: Int = 32 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    public mutating func append(_ chunk: Data) -> [Line] {
        var lines: [Line] = []
        var remaining = chunk[...]
        while let newlineIndex = remaining.firstIndex(of: 0x0A) {
            let piece = remaining[remaining.startIndex..<newlineIndex]
            remaining = remaining[remaining.index(after: newlineIndex)...]
            if discardingOversized {
                discardingOversized = false // resynced at this LF
                continue
            }
            if buffer.count + piece.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                lines.append(.tooLarge)
                continue
            }
            var line = buffer
            line.append(contentsOf: piece)
            buffer.removeAll(keepingCapacity: true)
            if line.last == 0x0D { line.removeLast() }
            lines.append(.line(line))
        }
        if discardingOversized {
            return lines
        }
        if buffer.count + remaining.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: false)
            discardingOversized = true
            lines.append(.tooLarge)
        } else {
            buffer.append(contentsOf: remaining)
        }
        return lines
    }
}
