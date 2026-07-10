// VWViewer — the embeddable document surface (lands in P1/P2).
//
// DocumentEngineView (NSView + CAMetalLayer — not MTKView; we control drawable
// timing and presentsWithTransaction), DocumentSession (@MainActor orchestrator),
// NSView displayLink (render-on-change, paused when idle, hot during scroll),
// custom scrollWheel with system momentum + rubber-band + overlay NSScroller.
