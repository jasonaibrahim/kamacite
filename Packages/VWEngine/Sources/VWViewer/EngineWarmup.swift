import VWRender

/// App-facing warm-up hook. Call from main() before NSApplication spins up:
/// shader compilation (~100ms, out-of-process) then overlaps AppKit init
/// instead of sitting on the first open.
public enum EngineWarmup {
    public static func start() {
        RendererCore.shared.warmUp()
    }
}
