import CoreTransferable
import OpenCaptionsKit
import UniformTypeIdentifiers

/// The captions as an SRT or VTT file, written (by the engine) only when the share sheet asks for it.
struct SubtitleFile: Transferable {
    let format: SubtitleFormat
    let write: @Sendable (SubtitleFormat) async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            SentTransferredFile(try await file.write(file.format))
        }
    }
}
