import Foundation

/// Arguments the app understands when exec'd directly. Bench runs bypass Launch
/// Services (the file arrives via argv, not an odoc Apple Event) so the app itself is
/// the benchmark subject: `vw --bench file.md` opens, reports, and exits.
struct BenchArguments {
    var benchMode = false
    var file: URL?

    static func parse(_ arguments: [String]) -> BenchArguments {
        var result = BenchArguments()
        for argument in arguments.dropFirst() {
            if argument == "--bench" {
                result.benchMode = true
            } else if result.benchMode, result.file == nil, !argument.hasPrefix("-") {
                result.file = URL(
                    fileURLWithPath: argument,
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
            }
            // Anything else (e.g. Xcode's -NSDocumentRevisionsDebugMode YES) is ignored.
        }
        return result
    }
}
