import Foundation

/// Arguments the app understands when exec'd directly. Bench runs bypass Launch
/// Services (the file arrives via argv, not an odoc Apple Event) so the app itself is
/// the benchmark subject: `vw --bench file.md` opens, reports, and exits. A bare
/// existing-file argument without --bench opens normally (debugging, scripts).
struct BenchArguments {
    var benchMode = false
    var file: URL?

    static func parse(_ arguments: [String]) -> BenchArguments {
        var result = BenchArguments()
        for argument in arguments.dropFirst() {
            if argument == "--bench" {
                result.benchMode = true
            } else if result.file == nil, !argument.hasPrefix("-") {
                // Only accept paths that actually exist: flag VALUES from
                // launchers (e.g. `-NSDocumentRevisionsDebugMode YES`) must
                // not be mistaken for documents.
                let url = URL(
                    fileURLWithPath: argument,
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                if FileManager.default.fileExists(atPath: url.path) {
                    result.file = url
                }
            }
        }
        return result
    }
}
