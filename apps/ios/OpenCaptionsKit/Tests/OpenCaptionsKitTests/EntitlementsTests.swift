import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct EntitlementsTests {
    func project(width: Int, height: Int, fps: Double, hdr: HDRTransfer? = nil) throws -> Project {
        Project(
            title: "x", transcript: try Repo.transcript(), styleConfig: try Repo.defaultStyle(), videoWidth: width,
            videoHeight: height, videoFps: fps, videoDuration: 10, hdrTransfer: hdr)
    }

    @Test func aFreeSaveIsBroughtWithin1080pAnd30fpsWithoutHDRAndIsMarked() throws {
        let big = try project(width: 2160, height: 3840, fps: 60, hdr: .hlg)
        let asked = ExportOptions(codec: .hevc, resolution: .original, keepHDR: true, frameRate: .fps60)
        let free = Entitlements.free.limit(asked, for: big)
        #expect(free.resolution == .p1080 && free.frameRate == .fps30 && !free.keepHDR)
        #expect(free.codec == .hevc, "what is not limited stays")
        #expect(free.watermark == Entitlements.watermarkText)
        let pro = Entitlements.pro.limit(asked, for: big)
        #expect(pro.resolution == .original && pro.frameRate == .fps60 && pro.keepHDR && pro.watermark == nil)
    }

    @Test func aFreeSaveOfAnOrdinaryVideoIsLeftAloneExceptForTheMark() throws {
        let p = try project(width: 1080, height: 1920, fps: 30)
        let free = Entitlements.free.limit(ExportOptions(), for: p)
        #expect(free.resolution == .original && free.frameRate == .original && free.keepHDR)
        #expect(free.watermark != nil)
    }

    @Test func theSourcesOwnFrameRateIsLockedWhenAbove30AndTheSizeWhenAbove1080p() throws {
        let p = try project(width: 1080, height: 1920, fps: 60)
        #expect(Entitlements.free.locks(frameRate: .original, for: p), "a 60 fps source as it is")
        #expect(Entitlements.free.locks(frameRate: .fps60, for: p))
        #expect(!Entitlements.free.locks(frameRate: .fps30, for: p))
        let uhd = try project(width: 3840, height: 2160, fps: 24)
        #expect(Entitlements.free.locks(resolution: .original, for: uhd))
        #expect(!Entitlements.free.locks(resolution: .p1080, for: uhd))
        #expect(!Entitlements.free.locks(resolution: .original, for: try project(width: 1920, height: 1080, fps: 24)))
        #expect(!Entitlements.pro.locks(resolution: .original, for: uhd))
        #expect(Entitlements.free.limit(ExportOptions(), for: uhd).outputSize(width: 3840, height: 2160) == (1920, 1080))
    }

    @Test func largeV3IsProAndTheTurboIsNot() {
        #expect(Entitlements.free.locks(model: "large-v3"))
        #expect(!Entitlements.free.locks(model: "large-v3-turbo"))
        #expect(!Entitlements.pro.locks(model: "large-v3"))
        #expect(WhisperModels.model("large-v3") != nil, "and it is a model there is")
    }

    @Test func presetsSayWhichArePro() throws {
        let presets = try Presets.load(from: Repo.presets)
        #expect(presets.first?.pro == false, "the default is free")
        #expect(presets.contains { $0.pro } && presets.contains { !$0.pro })
        let pro = try #require(presets.first { $0.pro })
        #expect(Entitlements.free.locks(preset: pro) && !Entitlements.pro.locks(preset: pro))
        let again = try JSONDecoder().decode([Preset].self, from: JSONEncoder().encode(presets))
        #expect(again == presets)
    }

    @Test func aMarkedSaveIsAnotherFile() throws {
        let p = try project(width: 1080, height: 1920, fps: 30)
        #expect(ExportKey.hash(for: p, options: ExportOptions()) != ExportKey.hash(for: p, options: ExportOptions(watermark: "x")))
    }
}
