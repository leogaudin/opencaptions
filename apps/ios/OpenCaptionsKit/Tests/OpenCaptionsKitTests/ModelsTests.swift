import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct ModelsTests {
    @Test func theFixtureDecodesAndRoundTrips() throws {
        let t = try Repo.transcript()
        #expect(t.segments.count == 2)
        #expect(t.words.map(\.text) == ["one", "two", "three", "four"])
        #expect(t.languageDetection == .auto)
        let again = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t))
        #expect(again == t)
    }

    @Test func aMissingConfidenceDefaultsToOne() throws {
        let json = #"{"text":"hi","start":0,"end":1}"#
        let w = try JSONDecoder().decode(Word.self, from: Data(json.utf8))
        #expect(w.confidence == 1)
    }

    @Test func theKeysAreTheAPIsSnakeCase() throws {
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Repo.transcript())) as? [String: Any]
        #expect(Set(json?.keys ?? [:].keys) == ["schema_version", "language", "language_detection", "duration", "segments"])
        let style = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Repo.defaultStyle())) as? [String: Any]
        #expect(style?["words_per_line"] as? Int == 3)
        #expect(style?["highlight_color"] as? String == "#FFDD00")
    }

    @Test func thePresetsAreTheSharedFile() throws {
        let presets = try Presets.load(from: Repo.presets)
        #expect(presets.map(\.id).first == "builtin:classic")
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.count >= 3)
        let again = try JSONDecoder().decode([Preset].self, from: JSONEncoder().encode(presets))
        #expect(again == presets)
    }

    @Test func aPresetIsRecognisedByItsIdentityFieldsOnly() throws {
        let presets = try Presets.load(from: Repo.presets)
        var style = presets[1].config
        #expect(style.matches(presets[1]) && !style.matches(presets[0]))
        style.strokeWidth += 3
        style.shadowBlur += 5
        #expect(style.matches(presets[1]), "stroke and shadow are tweakable within a preset")
        style.fontSize += 1
        #expect(!style.matches(presets[1]))
    }

    @Test func aProjectIsInTheAPIsShapeAndRoundTrips() throws {
        let project = Project(
            title: "clip", transcript: try Repo.transcript(), styleConfig: try Repo.defaultStyle(),
            captionOffsetMs: 250, videoWidth: 1080, videoHeight: 1920, videoFps: 30,
            videoDuration: 4, hdrTransfer: .hlg,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try Project.encoder.encode(project)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["caption_offset_ms"] as? Int == 250)
        #expect(object?["created_at"] as? String == "2023-11-14T22:13:20Z")
        #expect(object?["style_config"] != nil)
        #expect(try Project.decoder.decode(Project.self, from: data) == project)
    }
}
