import CryptoKit
import Foundation

struct MobileTransferExecutor {
    enum TransferError: LocalizedError {
        case unsupportedTool(String)
        case missingArgument(String)
        case unsafeTransferURL
        case invalidExpectedMetadata
        case chunkTooLarge
        case sizeMismatch
        case hashMismatch
        case destinationExists
        case invalidControllerResponse

        var errorDescription: String? {
            switch self {
            case .unsupportedTool(let tool): return "Unsupported mobile transfer tool: \(tool)"
            case .missingArgument(let name): return "Missing required argument: \(name)"
            case .unsafeTransferURL: return "Transfer URLs must belong to the paired LSM controller transfer endpoint."
            case .invalidExpectedMetadata: return "The transfer metadata is invalid."
            case .chunkTooLarge: return "The transfer chunk exceeds the 4 MiB mobile limit."
            case .sizeMismatch: return "The transferred file size does not match the controller metadata."
            case .hashMismatch: return "The transferred file SHA-256 does not match the controller metadata."
            case .destinationExists: return "The destination exists and overwrite is disabled."
            case .invalidControllerResponse: return "The transfer endpoint returned an invalid response."
            }
        }
    }

    private let maxChunkBytes = 4 * 1024 * 1024

    func execute(tool: String, args: [String: Any], controllerServer: String) async throws -> Any {
        switch tool {
        case "transfer_stat":
            guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
            return try MobileFileStore.stat(path, includeSHA256: (args["sha256"] as? Bool) ?? true)
        case "transfer_upload_url":
            return try await uploadChunk(args, controllerServer: controllerServer)
        case "transfer_download_url":
            return try await downloadFile(args, controllerServer: controllerServer)
        default:
            throw TransferError.unsupportedTool(tool)
        }
    }

    private func transferURL(_ raw: String, controllerServer: String) throws -> URL {
        guard let url = URL(string: raw),
              let server = URL(string: controllerServer),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              scheme == server.scheme?.lowercased(),
              url.host?.lowercased() == server.host?.lowercased(),
              effectivePort(url) == effectivePort(server),
              url.path.hasPrefix("/remote/transfer/") else {
            throw TransferError.unsafeTransferURL
        }
        return url
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private func uploadChunk(_ args: [String: Any], controllerServer: String) async throws -> [String: Any] {
        guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
        guard let rawURL = args["url"] as? String else { throw TransferError.missingArgument("url") }
        guard let total = (args["expected_bytes"] as? NSNumber)?.intValue,
              let expectedHash = args["expected_sha256"] as? String else {
            throw TransferError.invalidExpectedMetadata
        }
        let offset = (args["offset"] as? NSNumber)?.intValue ?? 0
        let chunkSize = (args["chunk_size"] as? NSNumber)?.intValue ?? 1024 * 1024
        guard total >= 0, offset >= 0, offset <= total, chunkSize > 0 else {
            throw TransferError.invalidExpectedMetadata
        }
        guard chunkSize <= maxChunkBytes else { throw TransferError.chunkTooLarge }

        let source = try MobileFileStore.resolve(path)
        let stat = try MobileFileStore.stat(path, includeSHA256: offset == 0)
        guard stat["type"] as? String == "file",
              (stat["size"] as? Int) == total else { throw TransferError.sizeMismatch }
        if offset == 0, (stat["sha256"] as? String)?.lowercased() != expectedHash.lowercased() {
            throw TransferError.hashMismatch
        }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let count = min(chunkSize, total - offset)
        let data = try handle.read(upToCount: count) ?? Data()
        let end = offset + data.count

        let url = try transferURL(rawURL, controllerServer: controllerServer)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = min(max((args["timeout_s"] as? NSNumber)?.doubleValue ?? 60, 10), 300)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-Chunk-SHA256")
        if total > 0 {
            guard !data.isEmpty else { throw TransferError.sizeMismatch }
            request.setValue("bytes \(offset)-\(end - 1)/\(total)", forHTTPHeaderField: "Content-Range")
        }
        request.httpBody = data
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["ok"] as? Bool == true,
              let result = object["data"] as? [String: Any] else {
            throw TransferError.invalidControllerResponse
        }
        var output = result
        output["offset"] = offset
        output["chunk_bytes"] = data.count
        output["chunk_size"] = chunkSize
        return output
    }

    private func downloadFile(_ args: [String: Any], controllerServer: String) async throws -> [String: Any] {
        guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
        guard let rawURL = args["url"] as? String else { throw TransferError.missingArgument("url") }
        guard let expectedBytes = (args["expected_bytes"] as? NSNumber)?.intValue,
              expectedBytes >= 0,
              let expectedHash = args["expected_sha256"] as? String else {
            throw TransferError.invalidExpectedMetadata
        }
        let overwrite = (args["overwrite"] as? Bool) ?? true
        let destination = try MobileFileStore.resolve(path)
        guard destination.standardizedFileURL != MobileFileStore.root.standardizedFileURL else {
            throw MobileFileStore.StoreError.unsafePath
        }
        if FileManager.default.fileExists(atPath: destination.path), !overwrite {
            throw TransferError.destinationExists
        }
        let url = try transferURL(rawURL, controllerServer: controllerServer)
        var request = URLRequest(url: url)
        request.timeoutInterval = min(max((args["timeout_s"] as? NSNumber)?.doubleValue ?? 60, 10), 300)

        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TransferError.invalidControllerResponse
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? -1
        guard bytes == expectedBytes else { throw TransferError.sizeMismatch }
        guard try MobileFileStore.sha256(temporary).lowercased() == expectedHash.lowercased() else {
            throw TransferError.hashMismatch
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return [
            "path": MobileFileStore.relativePath(destination),
            "bytes": bytes,
            "sha256": expectedHash.lowercased(),
            "transport": "http-stream",
        ]
    }
}
