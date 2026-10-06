import Foundation

/// How much room the phone has, as the system counts it for something the user asked for (it
/// includes what it would clear, such as caches, to make space).
public enum DiskSpace {
    public static func available(at url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Whether a file of about `bytes` fits with some room to spare (the estimate is a guess, and the
    /// system needs a little free to keep working).
    public static func fits(_ bytes: Int64, available: Int64?) -> Bool {
        guard let available else { return true }  // unknown: let the save try
        return Int64(Double(bytes) * 1.15) + 100_000_000 <= available
    }
}
