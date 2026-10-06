import Foundation

/// Fetches a Google Fonts family the style asked for and the app does not bundle, as
/// `apps/api/app/services/fonts.py` does for the server: TrueType (the one format the
/// engine reads, and what the CSS API answers a non-browser client with), at the
/// weight nearest 800, kept on disk so it is fetched once.
public struct FontCache: Sendable {
    public let directory: URL
    private let session: URLSession

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    /// Weights tried in order: captions are drawn heavy, and a family that lacks 800
    /// is asked for the next nearest.
    static let weights = [800, 900, 700, 600, 500, 400]

    func file(for family: String) -> URL {
        let slug = family.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        return directory.appendingPathComponent("\(slug).ttf")
    }

    /// The TrueType URL in the CSS the API returns, if there is one.
    static func fontURL(inCSS css: String) -> URL? {
        guard let range = css.range(of: #"url\((https://fonts\.gstatic\.com/[^)]+)\)"#, options: .regularExpression)
        else { return nil }
        let raw = css[range].dropFirst(4).dropLast()
        return URL(string: String(raw))
    }

    /// The family's TrueType bytes: from disk, else fetched and kept. Nil if the family is
    /// unknown or Google cannot be reached; the engine then draws the default face.
    public func data(for family: String) async -> Data? {
        let cached = file(for: family)
        if let data = try? Data(contentsOf: cached), !data.isEmpty { return data }
        for weight in Self.weights {
            guard let data = await fetch(family, weight: weight) else { continue }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: cached, options: .atomic)
            return data
        }
        return nil
    }

    /// A subset of the family that can draw only its own name, a few kilobytes: what a font list
    /// shows each row in. Kept on disk beside the full fonts.
    public func sample(for family: String) async -> URL? {
        let slug = file(for: family).deletingPathExtension().lastPathComponent
        let cached = directory.appendingPathComponent("samples", isDirectory: true).appendingPathComponent("\(slug).ttf")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        for weight in Self.weights {
            guard let data = await fetch(family, weight: weight, text: family) else { continue }
            try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: cached, options: .atomic)) != nil else { return nil }
            return cached
        }
        return nil
    }

    private func fetch(_ family: String, weight: Int, text: String? = nil) async -> Data? {
        var components = URLComponents(string: "https://fonts.googleapis.com/css2")!
        components.queryItems = [URLQueryItem(name: "family", value: "\(family):wght@\(weight)")]
            + (text.map { [URLQueryItem(name: "text", value: $0)] } ?? [])
        guard let cssURL = components.url else { return nil }
        var request = URLRequest(url: cssURL)
        // Not a browser, so the API answers with TrueType rather than woff2.
        request.setValue("OpenCaptions", forHTTPHeaderField: "User-Agent")
        guard let (css, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let url = Self.fontURL(inCSS: String(decoding: css, as: UTF8.self)),
            let (font, fontResponse) = try? await session.data(from: url),
            (fontResponse as? HTTPURLResponse)?.statusCode == 200,
            [Data([0, 1, 0, 0]), Data("OTTO".utf8), Data("true".utf8)].contains(font.prefix(4))
        else { return nil }
        return font
    }
}
