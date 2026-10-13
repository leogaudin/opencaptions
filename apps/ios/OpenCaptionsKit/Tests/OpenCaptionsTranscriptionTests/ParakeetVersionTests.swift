import FluidAudio
import Testing
@testable import OpenCaptionsKit
@testable import OpenCaptionsTranscription

struct ParakeetVersionTests {
    @Test func eachParakeetModelRunsItsOwnFluidAudioBuild() {
        #expect(ParakeetTranscriber.version(of: SpeechModels.parakeetUltraID) == .ultra)
        #expect(ParakeetTranscriber.version(of: SpeechModels.parakeetReduxID) == .redux)
    }

    @Test func theBuildsKeepTheirDownloadsApart() {
        let folders = [AsrModelVersion.ultra, .redux, .v3].map { AsrModels.defaultCacheDirectory(for: $0) }
        #expect(Set(folders).count == 3, "deleting one must leave the others")
    }
}
