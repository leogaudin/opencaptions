import Foundation

/// A built-in style: `presets.json`, shared with the web app, is its source.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var config: StyleConfig
    /// Part of the paid tier (`Entitlements`); false when the file does not say.
    public var pro: Bool

    public init(id: String, name: String, config: StyleConfig, pro: Bool = false) {
        self.id = id
        self.name = name
        self.config = config
        self.pro = pro
    }

    enum CodingKeys: String, CodingKey { case id, name, config, pro }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        config = try c.decode(StyleConfig.self, forKey: .config)
        pro = try c.decodeIfPresent(Bool.self, forKey: .pro) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(config, forKey: .config)
        if pro { try c.encode(true, forKey: .pro) }
    }
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
    /// the video, not to a look, and neither is how many words a line holds, so they are not compared
    /// (see `EditorModel.apply`).
    public func matches(_ preset: Preset) -> Bool {
        let p = preset.config
        return font == p.font && textColor == p.textColor
            && highlightColors == p.highlightColors && background == p.background
            && backgroundColor == p.backgroundColor
            && abs(backgroundOpacity - p.backgroundOpacity) < 0.001
            && animation == p.animation
    }

    /// The style with another background. A background with no opacity would show nothing, so choosing
    /// one gives it a visible opacity; the tiles that show each choice are drawn the same way.
    public func withBackground(_ choice: Background) -> StyleConfig {
        var style = self
        style.background = choice
        if choice != .none, style.backgroundOpacity < 0.05 { style.backgroundOpacity = Self.visibleBackgroundOpacity }
        return style
    }

    public static let visibleBackgroundOpacity = 0.7
}
