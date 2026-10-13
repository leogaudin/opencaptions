import Foundation
#if os(iOS)
    import BackgroundTasks
#endif

/// A long job (a transcription, a save) that carries on when the user leaves the app, with the system's own
/// progress card on the lock screen and in the Dynamic Island (iOS 26's `BGContinuedProcessingTask`, what
/// other apps use for an upload). Where that does not exist the job is inert: it needs the app on the
/// screen, as it always has, and nothing here changes how it runs.
///
/// Begin one from what the user just did (the system only runs it for a job they started with the app in
/// front), report how far it is, and end it. The system can also end it (its card has a cancel button, and
/// it stops work that stalls or needs the memory): `onStop` is then how the job hears of it.
@MainActor
public final class BackgroundJob {
    /// Whether this system runs jobs in the background.
    public static var isSupported: Bool {
        #if os(iOS)
            if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Whether the system accepted this job, so it keeps running if the app leaves the screen.
    public private(set) var continuesInBackground = false

    private var fraction = 0.0
    private var subtitle: String
    private let title: String
    private var onStop: (@MainActor () -> Void)?
    private var ended = false
    #if os(iOS)
        private var task: AnyObject?
    #endif

    private init(title: String, subtitle: String, onStop: @escaping @MainActor () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.onStop = onStop
    }

    /// Starts a job. `title` and `subtitle` are what the card says until it is updated.
    public static func begin(
        title: String, subtitle: String, onStop: @escaping @MainActor () -> Void
    ) -> BackgroundJob {
        let job = BackgroundJob(title: title, subtitle: subtitle, onStop: onStop)
        #if os(iOS)
            if #available(iOS 26.0, *) { job.submit() }
        #endif
        return job
    }

    /// How far the job is (0 to 1), and optionally what it is doing now.
    public func update(fraction: Double, subtitle: String? = nil) {
        guard !ended else { return }
        self.fraction = min(1, max(0, fraction))
        if let subtitle { self.subtitle = subtitle }
        #if os(iOS)
            if #available(iOS 26.0, *) { show() }
        #endif
    }

    /// The job is over, done or not.
    public func end(success: Bool) {
        guard !ended else { return }
        ended = true
        onStop = nil
        continuesInBackground = false
        #if os(iOS)
            if #available(iOS 26.0, *) { complete(success: success) }
        #endif
    }

    /// The system ended the job (the user cancelled it from the card, or it ran out of time or memory).
    private func stopped() {
        guard !ended else { return }
        let stop = onStop
        end(success: false)
        stop?()
    }
}

#if os(iOS)
    /// The tasks the system hands to a handler are not `Sendable`; this moves one to the main actor, where they are used.
    private struct TaskBox: @unchecked Sendable {
        let task: BGTask
    }

    @available(iOS 26.0, *)
    extension BackgroundJob {
        /// The identifiers are permitted in the Info.plist by their prefix.
        private static let prefix = "org.leogaudin.opencaptions.job."

        private func submit() {
            let identifier = Self.prefix + UUID().uuidString
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                let box = TaskBox(task: task)
                MainActor.assumeIsolated { self.attach(box.task) }
            }
            guard registered else { return }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            // Run now or not at all: a job that waited in a queue would start after the user had stopped caring.
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                continuesInBackground = true
            } catch {
                continuesInBackground = false
            }
        }

        private func attach(_ task: BGTask) {
            guard let task = task as? BGContinuedProcessingTask else { return }
            guard !ended else {
                task.setTaskCompleted(success: false)
                return
            }
            self.task = task
            task.progress.totalUnitCount = 1000
            task.expirationHandler = {
                MainActor.assumeIsolated { self.stopped() }
            }
            show()
        }

        private func show() {
            guard let task = task as? BGContinuedProcessingTask else { return }
            task.progress.completedUnitCount = Int64(fraction * 1000)
            if task.subtitle != subtitle { task.updateTitle(title, subtitle: subtitle) }
        }

        private func complete(success: Bool) {
            guard let task = task as? BGContinuedProcessingTask else { return }
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
            self.task = nil
        }
    }
#endif
