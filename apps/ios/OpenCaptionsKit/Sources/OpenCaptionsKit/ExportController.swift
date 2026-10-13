import Foundation
import Observation

public enum ExportState: Equatable, Sendable {
    case idle
    case running(fraction: Double)
    case done(URL)
    case failed(String)
}

/// One export at a time, with progress and cancel, for a view to show.
@MainActor @Observable
public final class ExportController {
    public typealias Run = @Sendable (
        _ project: Project, _ source: URL, _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    public private(set) var state: ExportState = .idle
    /// When the running export began, for an estimate of how long it has left.
    public private(set) var startedAt: Date?
    @ObservationIgnored private let run: Run
    @ObservationIgnored private let stallLimit: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastProgress = ContinuousClock.now
    @ObservationIgnored private var job: BackgroundJob?

    /// `stallLimit` is how long an export may go without any progress before it is stopped:
    /// a file is never worth waiting on forever if something has stopped moving.
    public init(stallLimit: Duration = .seconds(90), run: @escaping Run) {
        self.stallLimit = stallLimit
        self.run = run
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Whether the system lets the save go on if the app leaves the screen.
    public var continuesInBackground: Bool { job?.continuesInBackground == true }

    public func start(project: Project, source: URL) {
        guard !isRunning else { return }
        state = .running(fraction: 0)
        startedAt = Date()
        lastProgress = .now
        let run = run
        // The save goes on if the user leaves the app, with progress on the lock screen where iOS allows it.
        job = BackgroundJob.begin(
            title: String(localized: "Saving your video", bundle: .module), subtitle: "OpenCaptions",
            onStop: { [weak self] in self?.cancel() })
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.lastProgress = .now
                self.state = .running(fraction: fraction)
                self.job?.update(fraction: fraction)
            }
        }
        watchdog?.cancel()
        watchdog = Task { [weak self, stallLimit] in
            while !Task.isCancelled {
                try? await Task.sleep(for: min(stallLimit, .seconds(5)))
                guard let self, self.isRunning else { return }
                if ContinuousClock.now - self.lastProgress > stallLimit {
                    self.task?.cancel()
                    self.state = .failed(String(localized: "It stopped making progress, so it was stopped. Please try again.", bundle: .module))
                    self.endJob(success: false)
                    return
                }
            }
        }
        task = Task { [weak self] in
            do {
                let url = try await run(project, source, report)
                guard self?.isRunning == true else { return }  // stopped by the watchdog meanwhile
                self?.watchdog?.cancel()
                self?.state = .done(url)
                self?.endJob(success: true)
            } catch is CancellationError {
                if self?.isRunning == true { self?.state = .idle }
                self?.endJob(success: false)
            } catch {
                if self?.isRunning == true { self?.state = .failed(error.localizedDescription) }
                self?.endJob(success: false)
            }
        }
    }

    /// Stops the running export for a reason the user should read (the app left the screen).
    public func interrupt(_ reason: String) {
        guard isRunning else { return }
        task?.cancel()
        watchdog?.cancel()
        state = .failed(reason)
        endJob(success: false)
    }

    public func cancel() {
        task?.cancel()
        watchdog?.cancel()
        state = .idle
        endJob(success: false)
    }

    private func endJob(success: Bool) {
        job?.end(success: success)
        job = nil
    }

    public func dismiss() {
        if !isRunning { state = .idle }
    }
}
