import CryptoKit
import Foundation

struct MobileFileStore {
    enum StoreError: LocalizedError {
        case unsafePath
        case fileNotFound

        var errorDescription: String? {
            switch self {
            case .unsafePath: return "The requested path escapes the LSM app sandbox."
            case .fileNotFound: return "The requested sandbox file does not exist."
            }
        }
    }

    static let root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LSM", isDirectory: true)

    static func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func resolve(_ relative: String) throws -> URL {
        let standardizedRoot = root.standardizedFileURL
        let clean = relative == "." ? "" : relative
        guard !clean.hasPrefix("/") else { throw StoreError.unsafePath }
        let target = standardizedRoot.appendingPathComponent(clean).standardizedFileURL
        guard target == standardizedRoot || target.path.hasPrefix(standardizedRoot.path + "/") else {
            throw StoreError.unsafePath
        }
        return target
    }

    static func relativePath(_ url: URL) -> String {
        let standardizedRoot = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == standardizedRoot { return "." }
        guard path.hasPrefix(standardizedRoot + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(standardizedRoot.count + 1))
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func stat(_ relative: String, includeSHA256: Bool = true) throws -> [String: Any] {
        let url = try resolve(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw StoreError.fileNotFound
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        var result: [String: Any] = [
            "path": relativePath(url),
            "type": isDirectory.boolValue ? "dir" : "file",
            "size": (attrs[.size] as? NSNumber)?.intValue ?? 0,
        ]
        if !isDirectory.boolValue && includeSHA256 {
            result["sha256"] = try sha256(url)
        }
        return result
    }
}
