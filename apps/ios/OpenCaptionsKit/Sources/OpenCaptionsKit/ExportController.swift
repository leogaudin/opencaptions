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
    @ObservationIgnored private let run: Run
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(run: @escaping Run) {
        self.run = run
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public func start(project: Project, source: URL) {
        guard !isRunning else { return }
        state = .running(fraction: 0)
        let run = run
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.state = .running(fraction: fraction)
            }
        }
        task = Task { [weak self] in
            do {
                let url = try await run(project, source, report)
                self?.state = .done(url)
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        task?.cancel()
        state = .idle
    }

    public func dismiss() {
        if !isRunning { state = .idle }
    }
}
