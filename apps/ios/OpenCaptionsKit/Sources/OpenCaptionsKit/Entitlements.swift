import Foundation

/// What a free build of the app may do, and what Pro adds. The one place the limits are written:
/// the screens ask it what to lock, and the save asks it to bring the options within bounds (a
/// remembered choice or a stale screen cannot get past a screen that locks it).
///
/// The engine and everything else is open source and not gated by this; it only decides what this
/// app offers. Builds from source are `.pro`; an App Store build starts `.free` (see `AppModel`).
/// The Kit's own words for the screen (errors, what a long job says it is doing), in the user's
/// language. For the targets that sit beside the Kit and cannot reach its bundle.
public enum KitStrings {
    public static func localized(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: .module)
    }
}

public struct Entitlements: Equatable, Sendable {
    public var isPro: Bool

    public static let free = Entitlements(isPro: false)
    public static let pro = Entitlements(isPro: true)

    /// The mark a free tier's videos carry, preview and save alike.
    public static let watermarkText = "Made with OpenCaptions"
    /// Free videos go up to this short side (1080p) and this frame rate.
    public static let freeShortSide = 1080
    public static let freeFrameRate = 30.0
    /// The one speech model Pro unlocks: the slower, larger Large v3. Large v3 Turbo, almost as good,
    /// is free.
    public static let proModelIDs: Set<String> = ["large-v3"]

    public init(isPro: Bool) { self.isPro = isPro }

    public var watermark: String? { isPro ? nil : Self.watermarkText }

    public func locks(preset: Preset) -> Bool { !isPro && preset.pro }

    public func locks(model id: String) -> Bool { !isPro && Self.proModelIDs.contains(id) }

    /// Whether saving at this size is Pro: its short side is above 1080 pixels.
    public func locks(resolution: ExportOptions.Resolution, for project: Project) -> Bool {
        guard !isPro, let width = project.videoWidth, let height = project.videoHeight else { return false }
        let size = ExportOptions(resolution: resolution).outputSize(width: width, height: height)
        return min(size.width, size.height) > Self.freeShortSide
    }

    /// Whether saving at this frame rate is Pro: it is above 30.
    public func locks(frameRate: ExportOptions.FrameRate, for project: Project) -> Bool {
        !isPro && (frameRate.value ?? project.videoFps ?? 30) > Self.freeFrameRate + 0.5
    }

    /// Whether keeping an HDR video HDR is Pro (a standard video is not).
    public func locksHDR(for project: Project) -> Bool { !isPro && project.hdrTransfer != nil }

    /// The options a save may use: those asked for, brought within what this tier has, and the mark
    /// of a free one.
    public func limit(_ options: ExportOptions, for project: Project) -> ExportOptions {
        var options = options
        if locks(resolution: options.resolution, for: project) { options.resolution = .p1080 }
        if locks(frameRate: options.frameRate, for: project) { options.frameRate = .fps30 }
        if locksHDR(for: project) { options.keepHDR = false }
        options.watermark = watermark
        return options
    }
}
