import Foundation
import Observation
import SwiftUI

public enum SaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}

public enum TranscriptionState: Equatable, Sendable {
    case idle
    case running(fraction: Double, message: String)
    case failed(String)
}

/// One open project: its transcript and style, what is selected, saving and
/// transcribing. The views draw it and report gestures; every transcript edit is the
/// engine's, run one at a time so a quick drag cannot lose an update.
@MainActor @Observable
public final class EditorModel {
    /// The shortest and longest the caption offset may be, as the API's bounds.
    public static let offsetRangeMs = -2000...2000

    public private(set) var project: Project
    /// The captions as the timeline shows them (times with the offset applied).
    public private(set) var lines: [CaptionLine] = []
    /// `from` of the selected caption line.
    public var selectedLine: Int?
    public private(set) var saveState: SaveState = .idle
    public private(set) var transcription: TranscriptionState = .idle

    /// What undo and redo move between: the parts of a project a viewer edits (not the title).
    private struct Snapshot: Equatable {
        var transcript: Transcript?
        var style: StyleConfig
        var offsetMs: Int
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// Changes of one kind this close together (a slider dragged, an edge dragged) are one step.
    public var historyWindow: TimeInterval = 1.0
    @ObservationIgnored private var lastRecord: (key: String, at: Date)?

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let engine: CaptionEngine
    @ObservationIgnored private var autosaver: Autosaver?
    @ObservationIgnored private var queue: [(key: String?, edit: (Transcript) async throws -> Transcript)] = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?

    public init(project: Project, store: ProjectStore, engine: CaptionEngine = .shared) {
        self.project = project
        self.store = store
        self.engine = engine
        autosaver = Autosaver(save: { [weak self] in await self?.save() })
        Task { await refreshLines() }
    }

    public var transcript: Transcript? { project.transcript }

    public var isTranscribing: Bool {
        if case .running = transcription { return true }
        return false
    }

    // MARK: Undo and redo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private var snapshot: Snapshot {
        Snapshot(transcript: project.transcript, style: project.styleConfig, offsetMs: project.captionOffsetMs)
    }

    /// Called just before a change: remembers how things were, unless this continues a change of
    /// the same `key` made a moment ago. A new change ends what could be redone.
    private func record(_ key: String) {
        let now = Date()
        if let last = lastRecord, last.key == key, now.timeIntervalSince(last.at) < historyWindow {
            lastRecord = (key, now)
            return
        }
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastRecord = (key, now)
    }

    /// A key that is its own step, never merged with its neighbours.
    private func step() -> String { "step-\(UUID().uuidString)" }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    private func restore(_ state: Snapshot) {
        queue.removeAll()  // edits still waiting were made against the state being left
        project.transcript = state.transcript
        project.styleConfig = state.style
        project.captionOffsetMs = state.offsetMs
        lastRecord = nil
        selectedLine = nil
        changed()
    }

    // MARK: Saving

    /// Something changed: stamp it and schedule a save. The timeline's lines are worked out again only
    /// when what changed can alter them (the words, how many go on a line, the timing offset): a drag
    /// or a colour must not make the engine lay out the whole transcript again.
    private func changed(affectsLines: Bool = true) {
        project.updatedAt = Date()
        autosaver?.schedule()
        if affectsLines { Task { await refreshLines() } }
    }

    private func save() async {
        saveState = .saving
        do {
            project = try store.save(project)
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    /// Saves now if anything is pending: the app is going to the background.
    public func flush() async {
        await autosaver?.flush()
    }

    // MARK: Captions

    public func refreshLines() async {
        guard let transcript = project.transcript else {
            lines = []
            return
        }
        let wanted = (transcript, project.styleConfig.wordsPerLine, project.captionOffsetMs)
        if let cut = try? await engine.lines(wanted.0, wordsPerLine: wanted.1, offsetMs: wanted.2),
            wanted.0 == project.transcript, wanted.1 == project.styleConfig.wordsPerLine,
            wanted.2 == project.captionOffsetMs
        {
            lines = cut
        }
    }

    // MARK: Edits (the engine's, one at a time)

    /// Queues an edit. A queued edit with the same `key` is replaced by the newer one,
    /// so a drag that outpaces the engine commits only where it is now.
    private func enqueue(key: String? = nil, _ edit: @escaping (Transcript) async throws -> Transcript) {
        if let key, let last = queue.last, last.key == key { queue.removeLast() }
        queue.append((key, edit))
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                guard let current = self.project.transcript else { continue }
                if let edited = try? await next.edit(current) {
                    self.record(next.key ?? self.step())
                    self.project.transcript = edited
                    self.changed()
                }
            }
            self?.runner = nil
        }
    }

    /// Resolves once every queued edit has been applied.
    public func settled() async {
        while let runner { await runner.value }
        await refreshLines()
    }

    /// Sets one word's text (empty deletes the word; spaces inside stay, as the engine decides).
    public func setWord(index: Int, text: String) {
        let engine = engine
        enqueue { try await engine.setWord($0, index: index, text: text) }
    }

    /// Moves one edge of a word to `time` as shown, stopping at its neighbours.
    public func retime(index: Int, edge: CaptionEdge, time: Double) {
        let (engine, offset) = (engine, project.captionOffsetMs)
        enqueue(key: "retime-\(index)-\(edge)") {
            try await engine.retimeWord($0, index: index, edge: edge, time: time, offsetMs: offset)
        }
    }

    // MARK: Title

    /// Renames the project. Whitespace around the name goes, and a blank name is not a name: the
    /// old one stays. Returns whether it changed.
    @discardableResult
    public func rename(to title: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != project.title else { return false }
        project.title = name
        changed(affectsLines: false)
        return true
    }

    // MARK: Style

    public func updateStyle(_ change: (inout StyleConfig) -> Void) {
        updateStyle(as: "style", change)
    }

    /// `key` says what kind of change this is, so that a run of the same kind is one undo step.
    private func updateStyle(as key: String, _ change: (inout StyleConfig) -> Void) {
        var style = project.styleConfig
        change(&style)
        guard style != project.styleConfig else { return }
        let affectsLines = style.wordsPerLine != project.styleConfig.wordsPerLine
        record(key)
        project.styleConfig = style
        changed(affectsLines: affectsLines)
    }

    /// A binding to one style field, for a control.
    public func binding<T>(_ keyPath: WritableKeyPath<StyleConfig, T>) -> Binding<T> {
        Binding(
            get: { self.project.styleConfig[keyPath: keyPath] },
            set: { value in self.updateStyle { $0[keyPath: keyPath] = value } })
    }

    /// Applies a preset's look. The position, the size and the words per line stay as the user set
    /// them: a preset is a look (font, colours, background, animation), and changing it must not move
    /// the caption the user placed, resize what they sized or cut the lines differently.
    public func apply(_ preset: Preset) {
        updateStyle(as: step()) {
            let (x, y, size, words) = ($0.positionX, $0.positionY, $0.fontSize, $0.wordsPerLine)
            $0 = preset.config
            ($0.positionX, $0.positionY, $0.fontSize, $0.wordsPerLine) = (x, y, size, words)
        }
    }

    /// What a drag and a pinch settle on, in one change: where the caption is (kept in the frame) and
    /// how big (within the range a pinch and the slider reach). Either may be nil.
    public func adjustCaption(position: (x: Double, y: Double)?, fontSize: Int?) {
        updateStyle(as: step()) {
            if let position {
                $0.positionX = min(1, max(0, position.x))
                $0.positionY = min(1, max(0, position.y))
            }
            if let fontSize {
                $0.fontSize = Int(min(CaptionGestures.fontSizeRange.upperBound, max(CaptionGestures.fontSizeRange.lowerBound, Double(fontSize))))
            }
        }
    }

    public func setPosition(x: Double, y: Double) {
        updateStyle(as: "position") {
            $0.positionX = min(1, max(0, x))
            $0.positionY = min(1, max(0, y))
        }
    }

    public func setOffset(ms: Int) {
        let clamped = min(Self.offsetRangeMs.upperBound, max(Self.offsetRangeMs.lowerBound, ms))
        guard clamped != project.captionOffsetMs else { return }
        record("offset")
        project.captionOffsetMs = clamped
        changed()  // the offset moves every line
    }

    // MARK: Transcription

    public func startTranscription(with transcriber: any Transcriber, model: String, language: String?) {
        guard !isTranscribing, let source = store.sourceURL(for: project.id) else { return }
        transcription = .running(fraction: 0, message: String(localized: "Starting…", bundle: .module))
        let report: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
            Task { @MainActor in
                guard let self, self.isTranscribing else { return }
                self.transcription = .running(fraction: fraction, message: message)
            }
        }
        transcriptionTask = Task { [weak self] in
            do {
                let transcript = try await transcriber.transcribe(
                    source: source, language: language, model: model, progress: report)
                try Task.checkCancellation()
                if let self { self.record(self.step()) }
                self?.project.transcript = transcript
                self?.transcription = .idle
                self?.selectedLine = nil
                self?.changed()
            } catch is CancellationError {
                self?.transcription = .idle
            } catch {
                self?.transcription = .failed(error.localizedDescription)
            }
        }
    }

    /// Clears a failure once the user has seen it.
    public func dismissTranscriptionFailure() {
        if case .failed = transcription { transcription = .idle }
    }

    public func cancelTranscription() {
        transcriptionTask?.cancel()
        transcription = .idle
    }
}
