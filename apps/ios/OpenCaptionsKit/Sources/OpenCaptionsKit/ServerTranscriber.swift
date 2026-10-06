import AVFoundation
import Foundation

/// What a server says about itself: GET /api/v1/transcription/capabilities.
public struct ServerCapabilities: Decodable, Equatable, Sendable {
    public struct Model: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var note: String?

        public init(id: String, label: String, note: String?) {
            self.id = id
            self.label = label
            self.note = note
        }
    }

    /// The models worth offering on a phone: the server's, narrowed to the same short ladder the phone
    /// offers for its own (a server lists everything faster-whisper knows), in that order, plus the
    /// server's own default when it is something else (an operator's choice).
    public var leanModels: [Model] {
        let ladder = WhisperModels.all.map(\.id)
        let byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lean = ladder.compactMap { byID[$0] }
        if let id = defaultModel, !ladder.contains(id) {
            lean.insert(byID[id] ?? Model(id: id, label: id, note: nil), at: 0)
        }
        return lean
    }

    public var apiVersion: Int
    public var instanceName: String
    public var models: [Model]
    public var defaultModel: String?
    public var maxUploadMb: Int
    public var maxDurationS: Int
    public var resultTtlH: Int
    public var hostedMode: Bool
}

/// Why a server could not be used, in words a person can act on.
public enum ServerTranscriptionError: Error, Equatable, Sendable, LocalizedError {
    case unreachable(host: String)
    case keyRejected
    case incompatible(serverVersion: Int)
    case refused(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host): "Could not reach \(host). Check the address and your connection."
        case .keyRejected: "The server did not accept the key. It may have been revoked: make a new one."
        case .incompatible(let v):
            "The server speaks transcription version \(v), and this app speaks \(ServerTranscriber.apiVersion). Update the older one."
        case .refused(let why): why
        case .failed(let why): "The server could not transcribe it: \(why)"
        }
    }
}

/// Transcribes on an OpenCaptions backend through its transcription API: the audio goes up, the job is
/// watched, the `Transcript` comes back in the schema this app already uses.
///
/// Only the audio is sent, as AAC (about a megabyte a minute), and the server deletes it when the job
/// ends. The upload and the wait happen while the app is open; leaving the screen mid-upload loses it.
public struct ServerTranscriber: Transcriber {
    /// The transcription API version this app speaks.
    public static let apiVersion = 1

    public let connection: ServerConnection
    private let session: URLSession
    private let pollInterval: Duration

    public init(connection: ServerConnection, session: URLSession = .shared, pollInterval: Duration = .milliseconds(1500)) {
        self.connection = connection
        self.session = session
        self.pollInterval = pollInterval
    }

    // MARK: Talking to the server

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: connection.url.appendingPathComponent("api/v1/\(path)"))
        request.httpMethod = method
        request.setValue("Bearer \(connection.key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// The server's own words for an error response, else its status.
    private static func message(from data: Data, status: Int) -> String {
        struct Body: Decodable { var detail: String? }
        if let body = try? JSONDecoder().decode(Body.self, from: data), let detail = body.detail { return detail }
        return "HTTP \(status)"
    }

    private func send(_ request: URLRequest, body fileURL: URL? = nil, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) =
                if let fileURL { try await session.upload(for: request, fromFile: fileURL, delegate: delegate) }
                else { try await session.data(for: request, delegate: delegate) }
            guard let http = response as? HTTPURLResponse else { throw ServerTranscriptionError.failed("no answer") }
            if http.statusCode == 401 { throw ServerTranscriptionError.keyRejected }
            return (data, http)
        } catch let error as URLError where error.code != .cancelled {
            throw ServerTranscriptionError.unreachable(host: connection.url.host ?? connection.url.absoluteString)
        }
    }

    /// What the server offers, and a check that it speaks this version.
    public func capabilities() async throws -> ServerCapabilities {
        let (data, http) = try await send(request("transcription/capabilities"))
        guard http.statusCode == 200 else {
            throw ServerTranscriptionError.refused(Self.message(from: data, status: http.statusCode))
        }
        let capabilities = try decoder().decode(ServerCapabilities.self, from: data)
        guard capabilities.apiVersion == Self.apiVersion else {
            throw ServerTranscriptionError.incompatible(serverVersion: capabilities.apiVersion)
        }
        return capabilities
    }

    // MARK: Transcriber

    public func transcribe(
        source: URL, language: String?, model: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Transcript {
        let name = connection.displayName
        progress(0, "Preparing the audio…")
        let audio = try await AudioExport.m4a(from: source)
        defer { try? FileManager.default.removeItem(at: audio) }

        let capabilities = try await capabilities()
        try Task.checkCancellation()

        // A model id means something to the server that lists it: send ours only if it offers it.
        let offered = capabilities.models.contains { $0.id == model }
        progress(0.02, "Uploading to \(name)…")
        let jobID = try await upload(audio, language: language, model: offered ? model : nil) { fraction in
            progress(0.02 + 0.08 * fraction, "Uploading to \(name)…")
        }
        do {
            try await wait(for: jobID, serverName: name, progress: progress)
            let transcript = try await fetch(jobID)
            await forget(jobID)
            guard !transcript.segments.isEmpty else { throw TranscriptionError.noSpeech }
            progress(1, "Done")
            return transcript
        } catch {
            await forget(jobID)  // cancelled, failed or lost: the server need not keep it
            throw error
        }
    }

    private func upload(
        _ audio: URL, language: String?, model: String?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let boundary = "oc-\(UUID().uuidString)"
        let body = try MultipartFile.make(
            boundary: boundary, fields: ["language": language ?? "auto"].merging(model.map { ["model": $0] } ?? [:]) { a, _ in a },
            file: (field: "audio", name: "audio.m4a", type: "audio/mp4", url: audio))
        defer { try? FileManager.default.removeItem(at: body) }
        var request = request("transcriptions", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await send(request, body: body, delegate: UploadProgress(progress))
        guard http.statusCode == 202 else {
            throw ServerTranscriptionError.refused(Self.message(from: data, status: http.statusCode))
        }
        struct Created: Decodable { var jobId: String }
        return try decoder().decode(Created.self, from: data).jobId
    }

    private func wait(
        for jobID: String, serverName: String, progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        struct Job: Decodable {
            var status: String
            var progress: Double?
            var message: String?
            var error: String?
        }
        while true {
            try Task.checkCancellation()
            let (data, http) = try await send(request("jobs/\(jobID)"))
            guard http.statusCode == 200 else {
                throw ServerTranscriptionError.failed(Self.message(from: data, status: http.statusCode))
            }
            let job = try decoder().decode(Job.self, from: data)
            switch job.status {
            case "completed": return
            case "failed", "cancelled": throw ServerTranscriptionError.failed(job.error ?? job.message ?? job.status)
            default: progress(0.1 + 0.9 * (job.progress ?? 0), job.message ?? "Transcribing on \(serverName)…")
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func fetch(_ jobID: String) async throws -> Transcript {
        let (data, http) = try await send(request("transcriptions/\(jobID)"))
        guard http.statusCode == 200 else {
            throw ServerTranscriptionError.failed(Self.message(from: data, status: http.statusCode))
        }
        return try JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Tells the server to delete the job. Best effort, and it must run even when this task was cancelled.
    private func forget(_ jobID: String) async {
        let request = request("transcriptions/\(jobID)", method: "DELETE")
        let session = session
        await Task.detached { _ = try? await session.data(for: request) }.value
    }
}

/// Reports how much of an upload has left the phone.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}

enum AudioExport {
    /// The audio of a video (or audio) file as AAC in an .m4a, which is what gets uploaded.
    static func m4a(from source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw TranscriptionError.noAudio }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ServerTranscriptionError.failed("the audio could not be prepared")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("oc-audio-\(UUID().uuidString).m4a")
        do {
            try await export.export(to: output, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw ServerTranscriptionError.failed("the audio could not be prepared: \(error.localizedDescription)")
        }
        return output
    }
}

/// A multipart/form-data body written to a file, so a long recording is uploaded from disk and never
/// held in memory next to its copy.
enum MultipartFile {
    static func make(
        boundary: String, fields: [String: String], file: (field: String, name: String, type: String, url: URL)
    ) throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("oc-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        func write(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        try write(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\r\nContent-Type: \(file.type)\r\n\r\n"
        )
        let input = try FileHandle(forReadingFrom: file.url)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try handle.write(contentsOf: chunk) }
        try write("\r\n--\(boundary)--\r\n")
        return output
    }
}
