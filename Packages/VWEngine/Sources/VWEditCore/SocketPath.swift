import Foundation

/// The socket rendezvous: a path both the app (server) and the kama CLI
/// (client) compute independently, with no discovery round-trip.
public enum SocketPath {
    /// `$KAMACITE_SOCKET` override (test isolation) → Application Support →
    /// `$TMPDIR` when the App Support path would overflow sun_path (104
    /// bytes on macOS, absurd home directories only).
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["KAMACITE_SOCKET"], !override.isEmpty {
            return override
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Kamacite/kama.sock").path
        if appSupport.utf8.count < 104 {
            return appSupport
        }
        return (environment["TMPDIR"].map { $0 as NSString }?
            .appendingPathComponent("kamacite.sock"))
            ?? "/tmp/kamacite-\(getuid()).sock"
    }

    /// Create the socket's parent directory, private to the user.
    public static func prepareDirectory(for path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
