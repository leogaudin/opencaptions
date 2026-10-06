import Foundation
import Testing
@testable import OpenCaptionsKit

// MARK: Addresses, links and what is remembered

@Suite struct ServerConnectionTests {
    @Test func anAddressIsMadeIntoAnOriginWithTheRightScheme() {
        #expect(ServerConnection.normalizedURL("captions.example.org")?.absoluteString == "https://captions.example.org")
        #expect(ServerConnection.normalizedURL("192.168.1.20:5173")?.absoluteString == "http://192.168.1.20:5173")
        #expect(ServerConnection.normalizedURL("studio.local")?.absoluteString == "http://studio.local")
        #expect(ServerConnection.normalizedURL("localhost:5173")?.absoluteString == "http://localhost:5173")
        #expect(ServerConnection.normalizedURL("http://a.example.org/projects/3?x=1#y")?.absoluteString == "http://a.example.org")
        #expect(ServerConnection.normalizedURL("  https://a.example.org:8443/api  ")?.absoluteString == "https://a.example.org:8443")
        #expect(ServerConnection.normalizedURL("ftp://a.example.org") == nil)
        #expect(ServerConnection.normalizedURL("   ") == nil)
    }

    @Test func aPairingLinkFromTheWebAppIsRead() throws {
        let link = try #require(URL(string: "opencaptions://connect?url=http%3A%2F%2F192.168.1.20%3A5173&key=oc_abc123&name=Home%20GPU"))
        let connection = try #require(ServerConnection.parse(link: link))
        #expect(connection == ServerConnection(url: URL(string: "http://192.168.1.20:5173")!, key: "oc_abc123", name: "Home GPU"))
        #expect(connection.displayName == "Home GPU")
        let unnamed = try #require(ServerConnection.parse(link: URL(string: "opencaptions://connect?url=https%3A%2F%2Fa.example.org&key=k")!))
        #expect(unnamed.displayName == "a.example.org")
        // Anything else is not ours to act on.
        #expect(ServerConnection.parse(link: URL(string: "opencaptions://connect?url=https%3A%2F%2Fa.example.org")!) == nil, "no key")
        #expect(ServerConnection.parse(link: URL(string: "opencaptions://other?url=https%3A%2F%2Fa.example.org&key=k")!) == nil)
        #expect(ServerConnection.parse(link: URL(string: "https://a.example.org/connect?url=x&key=k")!) == nil)
        #expect(ServerConnection.parse(link: URL(string: "opencaptions://connect?url=javascript%3Aalert(1)&key=k")!) == nil)
    }

    @Test func theServerIsRememberedWithItsKeyKeptApart() throws {
        let suite = "oc-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let settings = ServerSettings(defaults: defaults, secrets: secrets)
        #expect(settings.connection == nil && !settings.useServer)

        let connection = ServerConnection(url: URL(string: "https://a.example.org")!, key: "oc_secret", name: "A")
        settings.save(connection)
        #expect(settings.connection == connection && settings.useServer)
        #expect(defaults.dictionaryRepresentation().values.allSatisfy { ($0 as? String) != "oc_secret" }, "the key is not in preferences")
        #expect(secrets.read("transcription.server.key") == "oc_secret")

        settings.useServer = false
        #expect(settings.connection == connection && !settings.useServer, "connected, but the phone is used")

        settings.disconnect()
        #expect(settings.connection == nil && !settings.useServer)
        #expect(secrets.read("transcription.server.key") == nil)
    }
}

// MARK: A server to talk to

/// Stands in for an OpenCaptions server: answers each request by its path, and keeps what it was sent.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        var method: String
        var path: String
        var authorization: String?
        var body: Data
    }

    nonisolated(unsafe) static var respond: @Sendable (Sent) throws -> (Int, Data) = { _ in (404, Data()) }
    nonisolated(unsafe) private static var log: [Sent] = []
    private static let lock = NSLock()

    static var sent: [Sent] { lock.withLock { log } }
    static func reset(_ respond: @escaping @Sendable (Sent) throws -> (Int, Data)) {
        lock.withLock { log = [] }
        Self.respond = respond
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        } else if let data = request.httpBody {
            body = data
        }
        let sent = Sent(
            method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
        Self.lock.withLock { Self.log.append(sent) }
        do {
            let (status, data) = try Self.respond(sent)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
}

@Suite(.serialized) struct ServerTranscriberTests {
    let connection = ServerConnection(url: URL(string: "https://gpu.example.org")!, key: "oc_secret", name: "Home GPU")

    func transcriber() -> ServerTranscriber {
        ServerTranscriber(connection: connection, session: StubServer.session(), pollInterval: .milliseconds(1))
    }

    /// A clip with sound, as the app would hand over.
    func clip(audio: Bool = true) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        try await SampleVideo.write(to: url, seconds: 1)
        return audio ? try await SampleVideo.addingAudio(to: url, seconds: 1) : url
    }

    /// A well-behaved server: two running polls, then done.
    func happyServer(polls: Int = 2, onSend: @escaping @Sendable (StubServer.Sent) -> Void = { _ in }) throws {
        let capabilities = try fixture("transcription_capabilities")
        let transcript = try fixture("transcript")
        let counter = PollCounter()
        StubServer.reset { sent in
            onSend(sent)
            switch (sent.method, sent.path) {
            case ("GET", "/api/v1/transcription/capabilities"): return (200, capabilities)
            case ("POST", "/api/v1/transcriptions"): return (202, Data(#"{"job_id":"job-1"}"#.utf8))
            case ("GET", "/api/v1/jobs/job-1"):
                let done = counter.next() > polls
                let state = done ? #"{"status":"completed","progress":1.0}"# : #"{"status":"running","progress":0.5,"message":"Transcribing"}"#
                return (200, Data(state.utf8))
            case ("GET", "/api/v1/transcriptions/job-1"): return (200, transcript)
            case ("DELETE", _): return (204, Data())
            default: return (404, Data(#"{"detail":"nothing here"}"#.utf8))
            }
        }
    }

    @Test func aTranscriptionGoesUpIsFollowedFetchedAndForgotten() async throws {
        try happyServer()
        let reported = Reported()
        let transcript = try await transcriber().transcribe(
            source: try await clip(), language: "fr", model: "large-v3"
        ) { fraction, message in reported.add(fraction, message) }

        #expect(transcript == (try Repo.transcript()), "the server's Transcript, decoded as it is")
        let sent = StubServer.sent
        #expect(sent.allSatisfy { $0.authorization == "Bearer oc_secret" })
        #expect(sent.contains { $0.method == "DELETE" && $0.path == "/api/v1/transcriptions/job-1" }, "the server is told to forget it")
        let upload = try #require(sent.first { $0.method == "POST" })
        let body = String(decoding: upload.body, as: UTF8.self)
        #expect(body.contains(#"name="language""#) && body.contains("fr"))
        #expect(body.contains(#"name="model""#) && body.contains("large-v3"), "an offered model is sent")
        #expect(body.contains(#"filename="audio.m4a""#) && body.contains("audio/mp4"))
        #expect(upload.body.count > 1_000, "real audio went up")

        let fractions = reported.fractions
        #expect(fractions == fractions.sorted() && fractions.last == 1)
        #expect(fractions.contains { abs($0 - (0.1 + 0.9 * 0.5)) < 1e-9 }, "the server's progress, mapped after the upload")
        #expect(reported.messages.contains { $0.contains("Home GPU") })
    }

    @Test func aModelTheServerDoesNotOfferIsLeftToIt() async throws {
        try happyServer()
        _ = try await transcriber().transcribe(source: try await clip(), language: nil, model: "tiny") { _, _ in }
        let upload = try #require(StubServer.sent.first { $0.method == "POST" })
        let body = String(decoding: upload.body, as: UTF8.self)
        #expect(!body.contains(#"name="model""#))
        #expect(body.contains("auto"), "no language means detect")
    }

    @Test func eachWayItCanGoWrongIsSaidInWords() async throws {
        let source = try await clip()
        let caps = try fixture("transcription_capabilities")

        StubServer.reset { _ in (401, Data()) }
        await #expect(throws: ServerTranscriptionError.keyRejected) {
            _ = try await transcriber().transcribe(source: source, language: nil, model: "") { _, _ in }
        }

        StubServer.reset { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: ServerTranscriptionError.unreachable(host: "gpu.example.org")) {
            _ = try await transcriber().transcribe(source: source, language: nil, model: "") { _, _ in }
        }

        let newer = String(decoding: caps, as: UTF8.self).replacingOccurrences(of: #""api_version": 1"#, with: #""api_version": 2"#)
        StubServer.reset { _ in (200, Data(newer.utf8)) }
        await #expect(throws: ServerTranscriptionError.incompatible(serverVersion: 2)) {
            _ = try await transcriber().transcribe(source: source, language: nil, model: "") { _, _ in }
        }

        StubServer.reset { sent in
            sent.method == "POST"
                ? (429, Data(#"{"error":"too_many_transcriptions","detail":"2 transcriptions are already running","code":429}"#.utf8))
                : (200, caps)
        }
        await #expect(throws: ServerTranscriptionError.refused("2 transcriptions are already running")) {
            _ = try await transcriber().transcribe(source: source, language: nil, model: "") { _, _ in }
        }

        StubServer.reset { sent in
            switch sent.method {
            case "POST": return (202, Data(#"{"job_id":"job-1"}"#.utf8))
            case "DELETE": return (204, Data())
            default:
                return sent.path.hasSuffix("capabilities")
                    ? (200, caps) : (200, Data(#"{"status":"failed","error":"ffmpeg could not read it"}"#.utf8))
            }
        }
        await #expect(throws: ServerTranscriptionError.failed("ffmpeg could not read it")) {
            _ = try await transcriber().transcribe(source: source, language: nil, model: "") { _, _ in }
        }
        #expect(StubServer.sent.contains { $0.method == "DELETE" }, "a failed job is cleaned up on the server")
    }

    @Test func aVideoWithoutSoundIsNotUploadedAtAll() async throws {
        try happyServer()
        await #expect(throws: TranscriptionError.noAudio) {
            _ = try await transcriber().transcribe(source: try await clip(audio: false), language: nil, model: "") { _, _ in }
        }
        #expect(StubServer.sent.isEmpty)
    }

    @Test func cancellingStopsPollingAndTellsTheServerToForget() async throws {
        try happyServer(polls: 10_000)
        let source = try await clip()
        let task = Task {
            try await transcriber().transcribe(source: source, language: nil, model: "") { _, _ in }
        }
        // Wait until it is polling, then cancel.
        for _ in 0..<2000 where !StubServer.sent.contains(where: { $0.path.hasSuffix("jobs/job-1") }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        for _ in 0..<400 where !StubServer.sent.contains(where: { $0.method == "DELETE" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(StubServer.sent.contains { $0.method == "DELETE" && $0.path.hasSuffix("transcriptions/job-1") })
    }

    @Test func aServersFullModelListIsNarrowedToThePhonesLadder() throws {
        func caps(models: [String], default defaultModel: String?) throws -> ServerCapabilities {
            let list = models.map { #"{"id":"\#($0)","label":"\#($0.uppercased())","note":""}"# }.joined(separator: ",")
            let json = """
                {"api_version":1,"instance_name":"S","models":[\(list)],"default_model":\(defaultModel.map { "\"\($0)\"" } ?? "null"),
                 "languages":[],"max_upload_mb":1,"max_duration_s":1,"result_ttl_h":1,"hosted_mode":false}
                """
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ServerCapabilities.self, from: Data(json.utf8))
        }
        let everything = ["tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en", "large-v1", "large-v2", "large-v3", "large-v3-turbo", "distil-large-v3"]
        // The phone's own order and short list, whatever the server lists.
        #expect(try caps(models: everything, default: "large-v3-turbo").leanModels.map(\.id) == WhisperModels.all.map(\.id))
        // A server that offers fewer offers fewer.
        #expect(try caps(models: ["base", "large-v3"], default: "base").leanModels.map(\.id) == ["base", "large-v3"])
        // An operator's own default is kept, first, even off the ladder.
        #expect(try caps(models: ["tiny", "my-finetune"], default: "my-finetune").leanModels.map(\.id) == ["my-finetune", "tiny"])
        // A hosted server fixes the model and lists none.
        #expect(try caps(models: [], default: nil).leanModels.isEmpty)
    }

    @Test func theServersCapabilitiesAreReadFromTheSharedFixture() async throws {
        try happyServer()
        let caps = try await transcriber().capabilities()
        #expect(caps.instanceName == "Home GPU" && caps.apiVersion == ServerTranscriber.apiVersion)
        #expect(caps.models.map(\.id) == ["large-v3-turbo", "large-v3"] && caps.defaultModel == "large-v3-turbo")
        #expect(caps.maxUploadMb == 2048 && caps.maxDurationS == 3600 && caps.resultTtlH == 24 && !caps.hostedMode)
        // The job the server reports for a transcription has no project.
        let job = try JSONSerialization.jsonObject(with: fixture("transcription_job")) as? [String: Any]
        #expect(job?["status"] as? String == "running" && job?["project_id"] is NSNull)
    }
}

final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Double, String)] = []
    func add(_ fraction: Double, _ message: String) { lock.withLock { items.append((fraction, message)) } }
    var fractions: [Double] { lock.withLock { items.map(\.0) } }
    var messages: [String] { lock.withLock { items.map(\.1) } }
}
