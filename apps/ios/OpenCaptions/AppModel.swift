import Foundation
import Observation
import OpenCaptionsKit
import OpenCaptionsTranscription

/// What the whole app shares: where projects live, the presets, the transcriber and
/// the font cache. Per-project state lives in `EditorModel`.
@MainActor @Observable
final class AppModel {
    let store: ProjectStore
    let transcriber: WhisperKitTranscriber
    let fontCache: FontCache
    let fontCatalog: FontCatalog
    /// Tiles of the presets drawn by the engine, made once.
    let presetPreviews = PresetPreviews()
    private(set) var presets: [Preset] = []
    private(set) var projects: [Project] = []
    var errorMessage: String?
    /// One model per open project, kept for the life of the app: a transcription or an
    /// autosave in progress must not end because the user went back to the list.
    @ObservationIgnored private var editors: [UUID: EditorModel] = [:]

    init() {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { fatalError("Application Support is unavailable") }
        store = ProjectStore(root: support.appendingPathComponent("Projects", isDirectory: true))
        // Weights are large and re-downloadable: never in a backup.
        transcriber = WhisperKitTranscriber(modelsDirectory: support.appendingPathComponent("Models", isDirectory: true))
        fontCache = FontCache(directory: support.appendingPathComponent("Fonts", isDirectory: true))
        fontCatalog = FontCatalog(directory: support.appendingPathComponent("Fonts", isDirectory: true))
        presets = (try? Presets.builtin()) ?? []
        Diagnostics.recordUncaughtExceptions()
        Diagnostics.log("launch")
    }

    /// The application default style: the first preset, as on the web.
    var defaultStyle: StyleConfig {
        guard let first = presets.first else { fatalError("presets.json is missing from the app bundle") }
        return first.config
    }

    func bootstrap() async {
        if let fonts = Bundle.main.url(forResource: "fonts", withExtension: nil) {
            _ = try? await CaptionEngine.shared.registerBundledFonts(in: fonts)
        }
        reload()
        #if DEBUG
            await seedForScreenshots()
        #endif
    }

    func editor(for project: Project) -> EditorModel {
        if let existing = editors[project.id] { return existing }
        let model = EditorModel(project: project, store: store)
        editors[project.id] = model
        return model
    }

    /// The model of a project already opened this session, for the list to show its progress.
    func openEditor(for id: UUID) -> EditorModel? { editors[id] }

    func reload() {
        projects = store.list()
    }

    func importVideo(from url: URL, title: String, move: Bool = false) async -> Project? {
        do {
            let project = try await store.importVideo(from: url, title: title, style: defaultStyle, move: move)
            reload()
            return project
        } catch {
            errorMessage = "Could not import that video: \(error.localizedDescription)"
            return nil
        }
    }

    /// Renames a project: through its editor if one is open (which owns the file while it is),
    /// else straight in the store.
    func rename(_ project: Project, to title: String) {
        if let editor = openEditor(for: project.id) {
            editor.rename(to: title)
        } else {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != project.title else { return }
            do {
                var stored = try store.load(project.id)
                stored.title = name
                stored.updatedAt = Date()
                _ = try store.save(stored)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        reload()
    }

    func delete(_ project: Project) {
        editors[project.id]?.cancelTranscription()
        editors[project.id] = nil
        do {
            try store.delete(project.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    #if DEBUG
        /// For screenshots on a simulator: `SIMCTL_CHILD_OC_SEED_VIDEO=<clip>` (and
        /// `OC_SEED_TRANSCRIPT=<json>`) makes a project from host files on first launch.
        private func seedForScreenshots() async {
            let env = ProcessInfo.processInfo.environment
            guard projects.isEmpty, let video = env["OC_SEED_VIDEO"],
                var project = await importVideo(from: URL(fileURLWithPath: video), title: "Demo clip")
            else { return }
            if let path = env["OC_SEED_TRANSCRIPT"],
                let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
            {
                project.transcript = transcript
                _ = try? store.save(project)
                reload()
            }
        }
    #endif
}
