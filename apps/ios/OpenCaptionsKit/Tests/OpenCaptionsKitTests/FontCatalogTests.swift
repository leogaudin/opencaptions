import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct FontCatalogTests {
    @Test func theCatalogIsParsedMostPopularFirstWithoutItsPrefix() throws {
        let body = Data(
            #")]}'{"familyMetadataList":[{"family":"Zilla","category":"Serif","popularity":9},{"family":"Anton","category":"Sans Serif","popularity":2},{"family":"NoRank"}]}"#.utf8)
        let families = try #require(FontCatalog.parse(body))
        #expect(families.map(\.family) == ["Anton", "Zilla", "NoRank"])
        #expect(families[2].category == "")
        #expect(FontCatalog.parse(Data("not json".utf8)) == nil)
    }

    @Test func aSeenCatalogWorksOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oc-fonts-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kept = [FontFamilyInfo(family: "Anton", category: "Sans Serif")]
        try JSONEncoder().encode(kept).write(to: dir.appendingPathComponent("catalog.json"))
        #expect(await FontCatalog(directory: dir).families() == kept)
    }
}
