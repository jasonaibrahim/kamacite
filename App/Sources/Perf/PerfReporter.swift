import AppKit
import QuartzCore

/// One open-to-glass measurement. The first trace of the process is "cold" and is
/// attributed to process start (pre-main included); later traces are "warm" and start
/// at open-request arrival.
final class OpenTrace {
    enum Mode: String {
        case cold, warm
    }

    let label: String
    let mode: Mode
    /// When the open request began (trace creation). Phase deltas anchor here; cold
    /// traces additionally report pre-main and main → open, and attribute the total
    /// to process start.
    let openedAt: CFTimeInterval
    var bytes: Int?
    private(set) var marks: [(name: String, at: CFTimeInterval)] = []

    init(label: String, mode: Mode) {
        self.label = label
        self.mode = mode
        self.openedAt = CACurrentMediaTime()
    }

    func mark(_ name: String) {
        marks.append((name, CACurrentMediaTime()))
    }
}

final class PerfReporter {
    static let shared = PerfReporter()

    private var enabled = false
    private var emitJSON = false
    private var benchMode = false
    private var coldTraceTaken = false

    func configure(with bench: BenchArguments) {
        let env = ProcessInfo.processInfo.environment
        benchMode = bench.benchMode
        enabled = benchMode || env["VW_PERF"] == "1"
        emitJSON = benchMode || env["VW_PERF_JSON"] == "1"
    }

    func beginTrace(label: String) -> OpenTrace {
        let mode: OpenTrace.Mode = coldTraceTaken ? .warm : .cold
        coldTraceTaken = true
        return OpenTrace(label: label, mode: mode)
    }

    func openFailed(_ trace: OpenTrace) {
        if benchMode {
            fputs("vw: bench open failed: \(trace.label)\n", stderr)
            exit(1)
        }
    }

    func presented(_ trace: OpenTrace) {
        defer { if benchMode { exit(0) } }
        guard enabled else { return }

        var rows: [(name: String, ms: Double)] = []
        if trace.mode == .cold {
            if let preMain = LaunchClock.shared.preMainMs {
                rows.append(("pre-main", preMain))
            }
            rows.append(("main → open", (trace.openedAt - LaunchClock.shared.mainMediaTime) * 1000))
        }
        var previous = trace.openedAt
        for mark in trace.marks {
            rows.append((mark.name, (mark.at - previous) * 1000))
            previous = mark.at
        }

        let lastAt = trace.marks.last?.at ?? previous
        let firstPixelMs: Double
        switch trace.mode {
        case .cold:
            firstPixelMs = (LaunchClock.shared.preMainMs ?? 0)
                + (lastAt - LaunchClock.shared.mainMediaTime) * 1000
        case .warm:
            firstPixelMs = (lastAt - trace.openedAt) * 1000
        }

        var out = "vw perf  \(trace.mode.rawValue)  \(trace.label)\(sizeSuffix(trace.bytes))\n"
        for row in rows {
            out += "  \(pad(row.name))\(fmt(row.ms)) ms\n"
        }
        out += "  ────────────────────────────\n"
        let basis = trace.mode == .cold ? "(process start → glass)" : "(open → glass)"
        out += "  \(pad("first pixel"))\(fmt(firstPixelMs)) ms   \(basis)\n"
        fputs(out, stderr)

        if emitJSON {
            var fields: [(String, String)] = [
                ("mode", jsonString(trace.mode.rawValue)),
                ("file", jsonString(trace.label)),
            ]
            if let bytes = trace.bytes {
                fields.append(("bytes", String(bytes)))
            }
            for row in rows {
                fields.append((jsonKey(row.name), String(format: "%.2f", row.ms)))
            }
            fields.append(("first_pixel_ms", String(format: "%.2f", firstPixelMs)))
            let json = "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
            fputs("VWPERF \(json)\n", stderr)
        }
    }

    private func pad(_ name: String) -> String {
        name.count >= 18 ? name + " " : name + String(repeating: " ", count: 18 - name.count)
    }

    private func fmt(_ ms: Double) -> String {
        String(format: "%8.1f", ms)
    }

    private func sizeSuffix(_ bytes: Int?) -> String {
        guard let bytes else { return "" }
        if bytes >= 1_000_000 {
            return String(format: " (%.1f MB)", Double(bytes) / 1_000_000)
        }
        return String(format: " (%.1f KB)", Double(bytes) / 1_000)
    }

    private func jsonKey(_ name: String) -> String {
        let sanitized = name.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(sanitized).split(separator: "_").joined(separator: "_") + "_ms"
    }

    private func jsonString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
