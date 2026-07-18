import Foundation

// Commit's disk half. The original file may be mmap'd by this process
// (Document.data is .mappedIfSafe) and by others: writing MUST be a fresh
// temp file + rename so the old inode survives for live mappings — an
// in-place truncate-and-write turns every mapped read into a SIGBUS.

public enum AtomicWriteError: Error {
    case writeFailed(String)
    case renameFailed(String)
}

/// stat() the interesting bits for external-change detection.
public struct FileStamp: Equatable, Sendable {
    public var modificationDate: Date
    public var size: Int

    public init(modificationDate: Date, size: Int) {
        self.modificationDate = modificationDate
        self.size = size
    }

    public init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        self.modificationDate = date
        self.size = size
    }
}

/// Write `data` over `url` atomically: temp in the SAME directory (same
/// volume ⇒ rename(2) is atomic), permissions copied from the original,
/// fsync before rename. Returns the new stamp.
@discardableResult
public func atomicWrite(_ data: Data, to url: URL) throws -> FileStamp {
    let directory = url.deletingLastPathComponent()
    let tempURL = directory.appendingPathComponent(
        ".\(url.lastPathComponent).kamacite-tmp-\(UUID().uuidString.prefix(8))"
    )
    let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]

    do {
        try data.write(to: tempURL, options: [])
        if let permissions {
            try? FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: tempURL.path
            )
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.synchronize()
        try handle.close()
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
        throw AtomicWriteError.writeFailed("\(error)")
    }

    guard rename(tempURL.path, url.path) == 0 else {
        let message = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: tempURL)
        throw AtomicWriteError.renameFailed(message)
    }
    return FileStamp(of: url) ?? FileStamp(modificationDate: Date(), size: data.count)
}
