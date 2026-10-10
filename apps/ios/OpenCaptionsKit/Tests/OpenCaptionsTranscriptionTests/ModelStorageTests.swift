import Foundation
import Testing
@testable import OpenCaptionsKit
@testable import OpenCaptionsTranscription

@Suite struct ModelStorageTests {
    /// A downloaded model as WhisperKit leaves it: a folder with compiled Core ML parts in it.
    func fakeModel(_ id: String, in root: URL, bytes: Int) throws -> WhisperKitTranscriber {
        let transcriber = WhisperKitTranscriber(modelsDirectory: root)
        let variant = try #require(SpeechModels.model(id)).variant
        let part = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)/Encoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: part.appendingPathComponent("weights.bin"))
        return transcriber
    }

    @Test func aModelIsDownloadedMeasuredAndDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oc-models-\(UUID())")
        let transcriber = try fakeModel("small", in: root, bytes: 12_345)
        #expect(transcriber.isDownloaded("small"))
        #expect(!transcriber.isDownloaded("large-v3-turbo"))
        #expect(transcriber.sizeOnDisk("small") == 12_345)
        #expect(transcriber.sizeOnDisk("large-v3-turbo") == 0)
        try transcriber.delete("small")
        #expect(!transcriber.isDownloaded("small"))
        #expect(transcriber.sizeOnDisk("small") == 0)
        try transcriber.delete("small")  // nothing to delete is not an error
    }
}
