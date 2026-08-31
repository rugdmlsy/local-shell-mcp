import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Saving to LSM…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        Task { await processShare() }
    }

    @MainActor
    private func processShare() async {
        do {
            let package = try ShareInboxStore.createPackage()
            var items: [SharedInboxManifest.Item] = []
            let extensionItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
            for extensionItem in extensionItems {
                for provider in extensionItem.attachments ?? [] {
                    if let item = try await capture(provider: provider, packageFiles: package.files) {
                        items.append(item)
                    }
                }
            }
            guard !items.isEmpty else {
                try? FileManager.default.removeItem(at: package.directory)
                throw NSError(domain: "LSMShareExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: "No supported share item was found."])
            }
            let manifest = SharedInboxManifest(id: package.id, createdAt: Date(), items: items)
            try ShareInboxStore.writeManifest(manifest, to: package.directory)
            statusLabel.text = "Saved to LSM."
            if let url = URL(string: "lsmworker://import-share?id=\(package.id)") {
                extensionContext?.open(url) { _ in }
            }
            try? await Task.sleep(for: .milliseconds(250))
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            statusLabel.text = error.localizedDescription
            try? await Task.sleep(for: .seconds(1))
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func capture(provider: NSItemProvider, packageFiles: URL) async throws -> SharedInboxManifest.Item? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try await loadItemURL(provider, typeIdentifier: UTType.fileURL.identifier), url.isFileURL {
                return try copyFile(url, into: packageFiles)
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try await loadItemURL(provider, typeIdentifier: UTType.url.identifier),
           !url.isFileURL {
            return SharedInboxManifest.Item(kind: "url", name: nil, value: url.absoluteString, relativeFile: nil)
        }

        for typeIdentifier in provider.registeredTypeIdentifiers {
            if let type = UTType(typeIdentifier), type.conforms(to: .data) || type.conforms(to: .image) || type.conforms(to: .pdf) {
                if let file = try? await loadFileRepresentation(provider, typeIdentifier: typeIdentifier) {
                    return try copyFile(file, into: packageFiles)
                }
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try await loadText(provider) {
            return SharedInboxManifest.Item(kind: "text", name: nil, value: text, relativeFile: nil)
        }
        return nil
    }

    private func copyFile(_ source: URL, into packageFiles: URL) throws -> SharedInboxManifest.Item {
        let baseName = ShareInboxStore.safeFilename(source.lastPathComponent)
        var destination = packageFiles.appendingPathComponent(baseName)
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let stem = (baseName as NSString).deletingPathExtension
            let ext = (baseName as NSString).pathExtension
            let nextName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            destination = packageFiles.appendingPathComponent(nextName)
            index += 1
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return SharedInboxManifest.Item(
            kind: "file",
            name: destination.lastPathComponent,
            value: nil,
            relativeFile: "files/\(destination.lastPathComponent)"
        )
    }

    private func loadItemURL(_ provider: NSItemProvider, typeIdentifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let text = String(data: data, encoding: .utf8),
                          let url = URL(string: text) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadFileRepresentation(_ provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: NSError(domain: "LSMShareExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Shared file representation was unavailable."]))
                }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let string = item as? String {
                    continuation.resume(returning: string)
                } else if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: attributed.string)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
