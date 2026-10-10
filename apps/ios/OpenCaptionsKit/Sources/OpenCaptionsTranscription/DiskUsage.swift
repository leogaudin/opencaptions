import Foundation

enum DiskUsage {
    /// The size of everything under `directory`, partial downloads included.
    static func bytes(in directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        return files.reduce(into: Int64(0)) { total, file in
            total += Int64((try? (file as? URL)?.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
    }
}
