import AppKit
import VWViewer

// Must be the first statement in the process: every perf number is measured from here
// (pre-main is reconstructed from the kernel's exec timestamp).
LaunchClock.markMain()

// Shader compilation runs out-of-process; kicking it now overlaps it with all
// of AppKit's spin-up so the first open never waits on the compiler.
EngineWarmup.start()

let benchArguments = BenchArguments.parse(CommandLine.arguments)
PerfReporter.shared.configure(with: benchArguments)

let app = NSApplication.shared
let appDelegate = AppDelegate(bench: benchArguments)
app.delegate = appDelegate  // NSApplication.delegate is weak; this binding must outlive run()
app.run()
