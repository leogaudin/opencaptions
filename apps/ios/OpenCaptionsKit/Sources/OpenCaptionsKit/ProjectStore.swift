import Foundation
import OSLog

private let log = Logger(subsystem: "org.leogaudin.opencaptions", category: "storage")

/// Projects are files, because one process reads and writes them. Each lives in
/// `<root>/<id>/`: `project.json`, `source.<ext>` (copied in at import, so a project
/// survives the clip being deleted from Photos) and `renders/` (named by content
/// hash, excluded from backup).
public struct ProjectStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `Application Support/Projects`.
    public static func standard() throws -> ProjectStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ProjectStore(root: support.appendingPathComponent("Projects", isDirectory: true))
    }

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func projectFile(_ id: UUID) -> URL {
        directory(for: id).appendingPathComponent("project.json")
    }

    public func rendersDirectory(for id: UUID) throws -> URL {
        let dir = directory(for: id).appendingPathComponent("renders", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try mutable.setResourceValues(values)
        return dir
    }

    /// The copied-in source video, if the project has one.
    public func sourceURL(for id: UUID) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory(for: id).path)) ?? []
        return files.first { $0.hasPrefix("source.") }.map { directory(for: id).appendingPathComponent($0) }
    }

    public func load(_ id: UUID) throws -> Project {
        try Project.decoder.decode(Project.self, from: Data(contentsOf: projectFile(id)))
    }

    /// Writes atomically (a temporary file, then a rename), so a crash mid-save leaves
    /// the previous version. Returns the project with its `updatedAt` set.
    @discardableResult
    public func save(_ project: Project) throws -> Project {
        // The file keeps whole seconds (ISO 8601), so the value returned is exactly
        // what a later load gives back.
        func whole(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
        var saved = project
        saved.createdAt = whole(project.createdAt)
        saved.updatedAt = whole(Date())
        try FileManager.default.createDirectory(
            at: directory(for: project.id), withIntermediateDirectories: true)
        try Project.encoder.encode(saved).write(to: projectFile(project.id), options: .atomic)
        return saved
    }

    /// Every readable project, newest first. One that cannot be read is hidden and
    /// logged, not a failure of the list.
    public func list() -> [Project] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name in
            guard let id = UUID(uuidString: name) else { return nil }
            do {
                return try load(id)
            } catch {
                log.error("hiding unreadable project \(name, privacy: .public): \(error.localizedDescription)")
                return nil
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }

    /// Copies a video into a new project and reads its size, rate and duration. On any
    /// failure nothing is left behind.
    public func importVideo(from source: URL, title: String, style: StyleConfig) async throws -> Project {
        let id = UUID()
        let dir = directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
            let copy = dir.appendingPathComponent("source.\(ext)")
            try FileManager.default.copyItem(at: source, to: copy)
            let info = try await VideoProbe.probe(copy)
            return try save(
                Project(
                    id: id, title: title, styleConfig: style, videoWidth: info.width,
                    videoHeight: info.height, videoFps: info.fps > 0 ? info.fps : nil,
                    videoDuration: info.duration, hdrTransfer: info.hdr))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }
}
