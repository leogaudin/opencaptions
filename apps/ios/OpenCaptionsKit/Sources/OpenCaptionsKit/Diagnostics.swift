import Darwin
import Foundation

/// A small log kept on the device (`diagnostics.log`, trimmed when it grows), so a crash that
/// leaves no report can still be explained: the long jobs write their milestones here, and an
/// uncaught Objective-C exception writes its reason before the app dies.
public enum Diagnostics {
    private static let lock = NSLock()
    private static let limit = 200_000

    public static var fileURL: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("diagnostics.log")
    }

    public static func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > limit {
            try? FileManager.default.removeItem(at: url)  // old news; start again
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Writes an uncaught Objective-C exception (AVFoundation raises them) to the log before the
    /// app is killed by it.
    public static func recordUncaughtExceptions() {
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.log(
                "UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "?")\n"
                    + exception.callStackSymbols.prefix(25).joined(separator: "\n"))
        }
    }

    /// The app's memory footprint in megabytes, as the system counts it against its limit.
    public static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
    }
}
