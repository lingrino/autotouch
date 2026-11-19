import Foundation
import os

/// Unified logging. Read with:
///   /usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.lingrino.autotouch"'
enum Log {
    static let logger = Logger(subsystem: "com.lingrino.autotouch", category: "autotouch")
    static func info(_ s: String) { logger.notice("\(s, privacy: .public)") }
    static func error(_ s: String) { logger.error("\(s, privacy: .public)") }
}

/// Monotonic nanoseconds (CLOCK_UPTIME_RAW).
@inline(__always) func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Process resource readings for the status line.
enum Diagnostics {
    /// Physical memory footprint in MB (what Activity Monitor calls "Memory").
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Total CPU time (user + system) used so far, in seconds.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}
