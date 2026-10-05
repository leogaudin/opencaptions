import Network

/// Whether the current connection is metered (cellular or a hotspot), so a large
/// download can ask first.
public enum NetworkCost {
    public static func isExpensive() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "org.leogaudin.opencaptions.network")
            nonisolated(unsafe) var done = false
            monitor.pathUpdateHandler = { path in
                guard !done else { return }
                done = true
                monitor.cancel()
                continuation.resume(returning: path.isExpensive)
            }
            monitor.start(queue: queue)
        }
    }
}
