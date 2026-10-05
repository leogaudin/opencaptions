import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct StorageTests {
    func store() -> ProjectStore {
        ProjectStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString)"))
    }

    func project(_ title: String, created: TimeInterval = 1_700_000_000) throws -> Project {
        Project(
            title: title, transcript: try Repo.transcript(), styleConfig: try Repo.defaultStyle(),
            createdAt: Date(timeIntervalSince1970: created))
    }

    @Test func aProjectSavesAndLoadsBack() throws {
        let store = store()
        let saved = try store.save(try project("clip"))
        #expect(try store.load(saved.id) == saved)
        #expect(saved.updatedAt >= saved.createdAt)
    }

    @Test func aSaveIsAtomicAndLeavesNoTemporaryFiles() throws {
        let store = store()
        var p = try project("clip")
        for n in 0..<5 {
            p.title = "clip \(n)"
            p = try store.save(p)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: p.id).path)
        #expect(files == ["project.json"])
        #expect(try store.load(p.id).title == "clip 4")
    }

    @Test func theListIsNewestFirstAndHidesWhatItCannotRead() throws {
        let store = store()
        let old = try store.save(try project("old", created: 1_600_000_000))
        let new = try store.save(try project("new", created: 1_700_000_000))
        let broken = UUID()
        try FileManager.default.createDirectory(at: store.directory(for: broken), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.directory(for: broken).appendingPathComponent("project.json"))
        try FileManager.default.createDirectory(
            at: store.root.appendingPathComponent("stray-folder"), withIntermediateDirectories: true)
        #expect(store.list().map(\.id) == [new.id, old.id])
    }

    @Test func aProjectIsDeletedWithItsFiles() throws {
        let store = store()
        let p = try store.save(try project("gone"))
        try store.delete(p.id)
        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: p.id).path))
    }

    @Test func rendersAreExcludedFromBackup() throws {
        let store = store()
        let p = try store.save(try project("clip"))
        let dir = try store.rendersDirectory(for: p.id)
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func theProbeReadsSizeRateAndDuration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        try await SampleVideo.write(to: url, width: 64, height: 48, seconds: 2, fps: 10)
        let info = try await VideoProbe.probe(url)
        #expect((info.width, info.height) == (64, 48))
        #expect(abs(info.fps - 10) < 0.5)
        #expect(abs(info.duration - 2) < 0.2)
        #expect(info.hdr == nil)
    }

    @Test func theProbeReportsTheSizeAsDisplayedAfterRotation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        try await SampleVideo.write(to: url, width: 64, height: 48, rotation: .pi / 2)
        let info = try await VideoProbe.probe(url)
        #expect((info.width, info.height) == (48, 64), "a portrait phone clip")
    }

    @Test func importingCopiesTheClipInAndReadsItsMetadata() async throws {
        let store = store()
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).MOV")
        try await SampleVideo.write(to: clip)
        let p = try await store.importVideo(from: clip, title: "My clip", style: try Repo.defaultStyle())
        try FileManager.default.removeItem(at: clip)  // the original is gone; the project survives
        #expect(p.videoWidth == 64 && p.videoHeight == 48)
        let source = try #require(store.sourceURL(for: p.id))
        #expect(source.lastPathComponent == "source.mov")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try store.load(p.id) == p)
    }

    @Test func aFailedImportLeavesNothingBehind() async throws {
        let store = store()
        let notVideo = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        try Data("hello".utf8).write(to: notVideo)
        await #expect(throws: (any Error).self) {
            try await store.importVideo(from: notVideo, title: "x", style: Repo.defaultStyle())
        }
        #expect(store.list().isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
        #expect(left.isEmpty)
    }
}
