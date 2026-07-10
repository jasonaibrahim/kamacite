import Darwin
import QuartzCore

/// Process-launch timestamps. All in-process marks use the CACurrentMediaTime (mach)
/// clock; pre-main is reconstructed from the kernel's exec timestamp — the only
/// pre-main measurement available without dyld hooks, and the scriptable substitute
/// for Instruments' App Launch template.
final class LaunchClock {
    static let shared = LaunchClock()

    /// CACurrentMediaTime at the first statement of main.swift.
    let mainMediaTime: CFTimeInterval

    /// Milliseconds spent before user code ran (dyld, runtime, framework
    /// initializers); nil if the sysctl fails.
    let preMainMs: Double?

    /// Call as the first statement of main.swift.
    static func markMain() {
        _ = shared
    }

    private init() {
        mainMediaTime = CACurrentMediaTime()
        if let processStart = Self.processStartWallTime() {
            preMainMs = max(0, (Date().timeIntervalSince1970 - processStart) * 1000)
        } else {
            preMainMs = nil
        }
    }

    private static func processStartWallTime() -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }
}
