import Foundation

@MainActor
final class SharedInboxImporter: ObservableObject {
    static let shared = SharedInboxImporter()

    @Published private(set) var lastImportSummary = ""

    private let fileManager = FileManager.default

    private init() {}

    func importPending() throws -> [String: Any] {
        let incoming = try ShareInboxStore.incomingRoot()
        let packages = try fileManager.contentsOfDirectory(
            at: incoming,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var imported: [[String: Any]] = []
        for package in packages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: package.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            do {
                imported.append(try importPackage(package))
            } catch {
                imported.append([
                    "package_id": package.lastPathComponent,
                    "imported": false,
                    "error": error.localizedDescription,
                ])
            }
        }
        let succeeded = imported.filter { ($0["imported"] as? Bool) == true }.count
        if !imported.isEmpty {
            lastImportSummary = "Imported \(succeeded)/\(imported.count) shared package(s)."
        }
        return ["items": imported, "count": imported.count, "imported_count": succeeded]
    }

    func pendingCount() -> Int {
        guard let root = try? ShareInboxStore.incomingRoot(),
              let urls = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        return urls.count
    }

    private func importPackage(_ package: URL) throws -> [String: Any] {
        let manifest = try ShareInboxStore.readManifest(from: package)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folderName = "Shared/\(formatter.string(from: manifest.createdAt))-\(manifest.id.prefix(8))"
        let destinationRoot = try MobileFileStore.resolve(folderName)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        var outputs: [[String: Any]] = []
        var textIndex = 0
        var urlIndex = 0
        for item in manifest.items {
            switch item.kind {
            case "file":
                guard let relativeFile = item.relativeFile else { continue }
                let source = package.appendingPathComponent(relativeFile).standardizedFileURL
                guard source.path.hasPrefix(package.standardizedFileURL.path + "/") else {
                    throw ShareInboxStore.InboxError.invalidPackage
                }
                let filename = ShareInboxStore.safeFilename(item.name ?? source.lastPathComponent)
                let destination = uniqueDestination(in: destinationRoot, filename: filename)
                try fileManager.copyItem(at: source, to: destination)
                outputs.append(["kind": "file", "path": MobileFileStore.relativePath(destination)])
            case "text":
                textIndex += 1
                let destination = uniqueDestination(in: destinationRoot, filename: "text-\(textIndex).txt")
                try Data((item.value ?? "").utf8).write(to: destination, options: .atomic)
                outputs.append(["kind": "text", "path": MobileFileStore.relativePath(destination)])
            case "url":
                urlIndex += 1
                let destination = uniqueDestination(in: destinationRoot, filename: "url-\(urlIndex).txt")
                try Data((item.value ?? "").utf8).write(to: destination, options: .atomic)
                outputs.append(["kind": "url", "path": MobileFileStore.relativePath(destination)])
            default:
                continue
            }
        }
        let manifestDestination = destinationRoot.appendingPathComponent("share-manifest.json")
        if let data = try? Data(contentsOf: package.appendingPathComponent("manifest.json")) {
            try data.write(to: manifestDestination, options: .atomic)
        }
        try fileManager.removeItem(at: package)
        return [
            "package_id": manifest.id,
            "imported": true,
            "destination": MobileFileStore.relativePath(destinationRoot),
            "items": outputs,
        ]
    }

    private func uniqueDestination(in directory: URL, filename: String) -> URL {
        let base = ShareInboxStore.safeFilename(filename)
        var candidate = directory.appendingPathComponent(base)
        if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
