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
