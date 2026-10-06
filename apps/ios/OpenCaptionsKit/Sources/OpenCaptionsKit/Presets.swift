import Foundation

/// A built-in style: `presets.json`, shared with the web app, is its source.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var config: StyleConfig
}

public enum Presets {
    public static func load(from url: URL) throws -> [Preset] {
        try JSONDecoder().decode([Preset].self, from: Data(contentsOf: url))
    }

    /// The presets bundled with the app. The first is the application default.
    public static func builtin(in bundle: Bundle = .main) throws -> [Preset] {
        guard let url = bundle.url(forResource: "presets", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }
}

extension StyleConfig {
    /// Whether this style is the one a preset defines, so the picker can highlight it.
    /// Compares only what a preset defines as its identity (stroke and shadow can be
    /// tweaked without leaving it), as the web does.
    /// Whether this style is the preset's look. Where the caption is and how big it is belong to
    /// the video, not to a look, so they are not compared (see `EditorModel.apply`).
    public func matches(_ preset: Preset) -> Bool {
        let p = preset.config
        return font == p.font && textColor == p.textColor
            && highlightColor == p.highlightColor && background == p.background
            && backgroundColor == p.backgroundColor
            && abs(backgroundOpacity - p.backgroundOpacity) < 0.001
            && animation == p.animation && wordsPerLine == p.wordsPerLine
    }
}
