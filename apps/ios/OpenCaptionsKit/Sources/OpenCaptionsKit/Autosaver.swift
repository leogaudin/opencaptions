import Foundation

/// Saves a moment after the last change, as the web editor does (800 ms): there is
/// no Save button. `flush` saves at once if anything is pending, for when the app
/// goes to the background.
@MainActor
public final class Autosaver {
    private let delay: Duration
    private let save: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var dirty = false

    public init(delay: Duration = .milliseconds(800), save: @escaping @MainActor () async -> Void) {
        self.delay = delay
        self.save = save
    }

    /// Something changed; save once it has been quiet for the delay.
    public func schedule() {
        dirty = true
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    public func flush() async {
        task?.cancel()
        task = nil
        guard dirty else { return }
        dirty = false
        await save()
    }
}
