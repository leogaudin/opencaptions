import Foundation

public enum HDRTransfer: String, Codable, Sendable {
    case pq
    case hlg
}

/// What `project.json` holds, in the API's `ProjectStatus` shape (the extra
/// `hdr_transfer` is the phone's: a server ignores a field it does not know).
public struct Project: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var transcript: Transcript?
    public var styleConfig: StyleConfig
    /// Global caption timing offset in ms; positive shows captions later.
    public var captionOffsetMs: Int
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var videoFps: Double?
    public var videoDuration: Double?
    public var hdrTransfer: HDRTransfer?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), title: String, transcript: Transcript? = nil, styleConfig: StyleConfig,
        captionOffsetMs: Int = 0, videoWidth: Int? = nil, videoHeight: Int? = nil,
        videoFps: Double? = nil, videoDuration: Double? = nil, hdrTransfer: HDRTransfer? = nil,
        createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.styleConfig = styleConfig
        self.captionOffsetMs = captionOffsetMs
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFps = videoFps
        self.videoDuration = videoDuration
        self.hdrTransfer = hdrTransfer
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, transcript
        case styleConfig = "style_config"
        case captionOffsetMs = "caption_offset_ms"
        case videoWidth = "video_width"
        case videoHeight = "video_height"
        case videoFps = "video_fps"
        case videoDuration = "video_duration"
        case hdrTransfer = "hdr_transfer"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]  // compact: written at every save, read by the list
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
