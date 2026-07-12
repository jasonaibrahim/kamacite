import AppKit

// P1 spike entry point.
//   text-on-gpu                 windowed side-by-side vs NSTextView
//   text-on-gpu --smoke         windowed, auto-quits after 2s (CI/sanity)
//   text-on-gpu --dump [dir]    headless PNG dumps + parity stats, exits

let arguments = CommandLine.arguments

if let dumpIndex = arguments.firstIndex(of: "--dump") {
    let next = dumpIndex + 1
    let directory = next < arguments.count && !arguments[next].hasPrefix("-")
        ? arguments[next]
        : "Spikes/TextOnGPU/out"
    do {
        try runDump(outputDirectory: directory)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("dump failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = SpikeAppDelegate(smokeTest: arguments.contains("--smoke"))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
