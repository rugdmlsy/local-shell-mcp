import Foundation

struct SharedInboxManifest: Codable {
    struct Item: Codable {
        let kind: String
        let name: String?
        let value: String?
        let relativeFile: String?
    }

    let id: String
    let createdAt: Date
    let items: [Item]
}

enum ShareInboxStore {
    enum InboxError: LocalizedError {
        case appGroupUnavailable
        case invalidPackage

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "The Share Extension requires an App Group-enabled LSM Worker build."
            case .invalidPackage:
                return "The shared inbox package is invalid."
            }
        }
    }

    static let appGroupID = "group.com.xycdev.lsmmobileworker"
    static let incomingDirectoryName = "Incoming"

    static func container() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw InboxError.appGroupUnavailable
        }
        return url
    }

    static func incomingRoot() throws -> URL {
        let root = try container().appendingPathComponent(incomingDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func createPackage() throws -> (id: String, directory: URL, files: URL) {
        let id = UUID().uuidString
        let directory = try incomingRoot().appendingPathComponent(id, isDirectory: true)
        let files = directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        return (id, directory, files)
    }

    static func writeManifest(_ manifest: SharedInboxManifest, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func readManifest(from directory: URL) throws -> SharedInboxManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SharedInboxManifest.self, from: data)
    }

    static func safeFilename(_ raw: String, fallback: String = "shared-item") -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = fallback }
        for character in ["/", "\\", ":"] {
            value = value.replacingOccurrences(of: character, with: "-")
        }
        while value.hasPrefix(".") { value.removeFirst() }
        if value.isEmpty { value = fallback }
        return String(value.prefix(180))
    }
}
