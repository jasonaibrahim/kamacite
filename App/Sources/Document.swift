import Foundation

/// A loaded markdown file. UI-free by design: future editing can wrap this same type
/// in an NSDocument subclass, and the engine pipeline consumes it as-is.
final class Document {
    let url: URL
    let data: Data

    init(url: URL) throws {
        self.url = url
        // mmap: a 100MB file costs page faults on access, not an upfront copy.
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
