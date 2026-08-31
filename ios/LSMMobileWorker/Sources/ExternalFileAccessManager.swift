import Foundation

struct ExternalBookmarkRecord: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let isDirectory: Bool
    let addedAt: Date
    let bookmarkBase64: String
}

@MainActor
final class ExternalFileAccessManager: ObservableObject {
    enum AccessError: LocalizedError {
        case bookmarkNotFound
        case bookmarkInvalid
        case sourceNotFound
        case directoryRequired
        case destinationExists
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .bookmarkNotFound: return "The selected external-file bookmark no longer exists."
            case .bookmarkInvalid: return "The selected external-file bookmark can no longer be resolved."
            case .sourceNotFound: return "The requested sandbox source does not exist."
            case .directoryRequired: return "This action requires a bookmarked directory."
            case .destinationExists: return "The destination already exists and overwrite=false."
            case .accessDenied: return "iOS did not grant access to the selected external item. Re-select it in LSM Worker."
            }
        }
    }

    static let shared = ExternalFileAccessManager()

    @Published private(set) var bookmarks: [ExternalBookmarkRecord] = []

    private let defaultsKey = "mobile.external_file_bookmarks.v1"
    private let fileManager = FileManager.default

    private init() {
        load()
    }

    func add(url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let record = ExternalBookmarkRecord(
            id: UUID().uuidString,
            name: values.name ?? url.lastPathComponent,
            isDirectory: values.isDirectory == true,
            addedAt: Date(),
            bookmarkBase64: data.base64EncodedString()
        )
        bookmarks.removeAll { existing in
            existing.name == record.name && existing.isDirectory == record.isDirectory
        }
        bookmarks.append(record)
        bookmarks.sort { $0.addedAt > $1.addedAt }
        persist()
    }

    func remove(id: String) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func list() -> [String: Any] {
        [
            "items": bookmarks.map { record in
                [
                    "id": record.id,
                    "name": record.name,
                    "type": record.isDirectory ? "directory" : "file",
                    "added_at": ISO8601DateFormatter().string(from: record.addedAt),
                ]
            },
            "count": bookmarks.count,
        ]
    }

    func importToSandbox(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let bookmarkID = arguments["bookmark_id"] as? String else {
            throw MobileActionExecutor.ActionError.missingArgument("bookmark_id")
        }
        let record = try record(id: bookmarkID)
        let source = try resolve(record)
        let accessed = source.startAccessingSecurityScopedResource()
        guard accessed else { throw AccessError.accessDenied }
        defer { source.stopAccessingSecurityScopedResource() }

        let requested = (arguments["destination_path"] as? String) ?? "Imports/\(record.name)"
        let destination = try MobileFileStore.resolve(requested)
        let overwrite = (arguments["overwrite"] as? Bool) ?? false
        if fileManager.fileExists(atPath: destination.path) {
            guard overwrite else { throw AccessError.destinationExists }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        return [
            "bookmark_id": record.id,
            "source_name": record.name,
            "destination_path": MobileFileStore.relativePath(destination),
            "type": record.isDirectory ? "directory" : "file",
            "imported": true,
        ]
    }

    func exportFromSandbox(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let bookmarkID = arguments["bookmark_id"] as? String else {
            throw MobileActionExecutor.ActionError.missingArgument("bookmark_id")
        }
        guard let sourcePath = arguments["source_path"] as? String else {
            throw MobileActionExecutor.ActionError.missingArgument("source_path")
        }
        let record = try record(id: bookmarkID)
        guard record.isDirectory else { throw AccessError.directoryRequired }
        let directory = try resolve(record)
        let accessed = directory.startAccessingSecurityScopedResource()
        guard accessed else { throw AccessError.accessDenied }
        defer { directory.stopAccessingSecurityScopedResource() }

        let source = try MobileFileStore.resolve(sourcePath)
        guard fileManager.fileExists(atPath: source.path) else { throw AccessError.sourceNotFound }
        let requestedName = ((arguments["filename"] as? String) ?? source.lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = requestedName.replacingOccurrences(of: "/", with: "-")
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else {
            throw MobileActionExecutor.ActionError.unsafePath
        }
        let destination = directory.appendingPathComponent(safeName)
        let overwrite = (arguments["overwrite"] as? Bool) ?? false
        if fileManager.fileExists(atPath: destination.path) {
            guard overwrite else { throw AccessError.destinationExists }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return [
            "bookmark_id": record.id,
            "source_path": MobileFileStore.relativePath(source),
            "destination_name": safeName,
            "exported": true,
        ]
    }

    private func record(id: String) throws -> ExternalBookmarkRecord {
        guard let record = bookmarks.first(where: { $0.id == id }) else {
            throw AccessError.bookmarkNotFound
        }
        return record
    }

    private func resolve(_ record: ExternalBookmarkRecord) throws -> URL {
        guard let data = Data(base64Encoded: record.bookmarkBase64) else {
            throw AccessError.bookmarkInvalid
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            let refreshed = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            if let index = bookmarks.firstIndex(where: { $0.id == record.id }) {
                bookmarks[index] = ExternalBookmarkRecord(
                    id: record.id,
                    name: record.name,
                    isDirectory: record.isDirectory,
                    addedAt: record.addedAt,
                    bookmarkBase64: refreshed.base64EncodedString()
                )
                persist()
            }
        }
        return url
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ExternalBookmarkRecord].self, from: data) else {
            bookmarks = []
            return
        }
        bookmarks = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
