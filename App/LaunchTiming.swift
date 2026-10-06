import Darwin
import Foundation

enum LaunchTiming {
    /// Milliseconds since this process started, from the kernel's process start time.
    static func millisecondsSinceProcessStart() -> Int {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let startDate = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        return Int(Date().timeIntervalSince(startDate) * 1000)
    }
}
