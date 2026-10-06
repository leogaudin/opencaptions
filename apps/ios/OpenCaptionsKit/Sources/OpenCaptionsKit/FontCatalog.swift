import Foundation

/// A Google Fonts family, as the font list shows it.
public struct FontFamilyInfo: Codable, Equatable, Sendable, Identifiable {
    public var family: String
    public var category: String
    public var id: String { family }

    public init(family: String, category: String) {
        self.family = family
        self.category = category
    }
}

/// Every Google Fonts family, most popular first, as `apps/api/app/services/fonts.py` lists them
/// for the desktop: fetched once from the same catalog and kept on disk, so the list works
/// offline once it has been seen.
public struct FontCatalog: Sendable {
    public let directory: URL
    private let session: URLSession
    static let url = URL(string: "https://fonts.google.com/metadata/fonts")!

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    private var file: URL { directory.appendingPathComponent("catalog.json") }

    /// The catalog JSON starts with an anti-hijacking prefix, and lists families with their
    /// popularity.
    static func parse(_ body: Data) -> [FontFamilyInfo]? {
        var text = String(decoding: body, as: UTF8.self)
        if text.hasPrefix(")]}'") { text.removeFirst(4) }
        struct Row: Decodable {
            var family: String
            var category: String?
            var popularity: Int?
        }
        struct Catalog: Decodable { var familyMetadataList: [Row] }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: Data(text.utf8)) else { return nil }
        return catalog.familyMetadataList
            .sorted { ($0.popularity ?? .max) < ($1.popularity ?? .max) }
            .map { FontFamilyInfo(family: $0.family, category: $0.category ?? "") }
    }

    /// The families: from disk if seen before, else fetched. Empty if offline and never seen.
    public func families() async -> [FontFamilyInfo] {
        if let data = try? Data(contentsOf: file),
            let kept = try? JSONDecoder().decode([FontFamilyInfo].self, from: data), !kept.isEmpty
        {
            return kept
        }
        var request = URLRequest(url: Self.url)
        request.setValue("OpenCaptions", forHTTPHeaderField: "User-Agent")
        guard let (body, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let families = Self.parse(body), !families.isEmpty
        else { return [] }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(families).write(to: file, options: .atomic)
        return families
    }
}
