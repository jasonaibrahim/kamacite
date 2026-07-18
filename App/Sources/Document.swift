import Foundation
import VWEditCore

/// A loaded markdown file. UI-free by design: future editing can wrap this same type
/// in an NSDocument subclass, and the engine pipeline consumes it as-is.
///
/// With live editing, `data` is the DISK-TRUTH snapshot (what discard reverts
/// to), never the live buffer — the buffer lives in the engine session, and
/// commit routes through `rebase` so this stays the record of what's on disk.
final class Document {
    let url: URL
    private(set) var data: Data
    /// mtime+size at read/last commit — the external-change tripwire: commit
    /// refuses (without force) when the file moved underneath the buffer.
    private(set) var diskStamp: FileStamp?

    init(url: URL) throws {
        self.url = url
        // mmap: a 100MB file costs page faults on access, not an upfront copy.
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.diskStamp = FileStamp(of: url)
    }

    /// A commit landed: the written bytes are the new disk truth.
    func rebase(to committed: Data, stamp: FileStamp) {
        data = committed
        diskStamp = stamp
    }

    /// Has the file changed on disk since we last read or wrote it?
    var diskChangedExternally: Bool {
        guard let recorded = diskStamp else { return false }
        return FileStamp(of: url) != recorded
    }
}
