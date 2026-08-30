import CryptoKit
import Foundation

final class MobileTransferExecutor {
    enum TransferError: LocalizedError {
        case unsupportedTool(String)
        case missingArgument(String)
        case unsafeTransferURL
        case invalidExpectedMetadata
        case invalidTransferID
        case invalidOffset
        case invalidBase64
        case chunkTooLarge
        case nonSequentialChunk
        case sizeMismatch
        case hashMismatch
        case destinationExists
        case destinationIsDirectory
        case invalidControllerResponse

        var errorDescription: String? {
            switch self {
            case .unsupportedTool(let tool): return "Unsupported mobile transfer tool: \(tool)"
            case .missingArgument(let name): return "Missing required argument: \(name)"
            case .unsafeTransferURL: return "Transfer URLs must belong to the paired LSM controller transfer endpoint."
            case .invalidExpectedMetadata: return "The transfer metadata is invalid."
            case .invalidTransferID: return "The transfer ID is invalid or no longer active."
            case .invalidOffset: return "The transfer offset must be non-negative."
            case .invalidBase64: return "The transfer chunk is not valid base64."
            case .chunkTooLarge: return "The transfer chunk exceeds the 4 MiB mobile limit."
            case .nonSequentialChunk: return "Mobile transfer chunks must arrive sequentially without gaps or overlap."
            case .sizeMismatch: return "The transferred file size does not match the controller metadata."
            case .hashMismatch: return "The transferred file SHA-256 does not match the controller metadata."
            case .destinationExists: return "The destination exists and overwrite is disabled."
            case .destinationIsDirectory: return "The transfer destination is a directory."
            case .invalidControllerResponse: return "The transfer endpoint returned an invalid response."
            }
        }
    }

    private struct WriteSession {
        let id: String
        let destination: URL
        let temporary: URL
        let overwrite: Bool
        let expectedBytes: Int?
        var bytesReceived: Int
    }

    private let maxChunkBytes = 4 * 1024 * 1024
    private var writeSessions: [String: WriteSession] = [:]

    func execute(tool: String, args: [String: Any], controllerServer: String) async throws -> Any {
        switch tool {
        case "transfer_stat":
            guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
            return try MobileFileStore.stat(path, includeSHA256: (args["sha256"] as? Bool) ?? true)
        case "transfer_read_chunk":
            return try readChunk(args)
        case "transfer_begin_write":
            return try beginWrite(args)
        case "transfer_write_chunk":
            return try writeChunk(args)
        case "transfer_finish_write":
            return try finishWrite(args)
        case "transfer_abort_write":
            return try abortWrite(args)
        case "transfer_upload_url":
            return try await uploadChunk(args, controllerServer: controllerServer)
        case "transfer_download_url":
            return try await downloadFile(args, controllerServer: controllerServer)
        default:
            throw TransferError.unsupportedTool(tool)
        }
    }

    private func readChunk(_ args: [String: Any]) throws -> [String: Any] {
        guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
        let offset = (args["offset"] as? NSNumber)?.intValue ?? 0
        guard offset >= 0 else { throw TransferError.invalidOffset }
        let requested = (args["chunk_size"] as? NSNumber)?.intValue ?? 1024 * 1024
        guard requested > 0 else { throw TransferError.invalidExpectedMetadata }
        let chunkSize = min(requested, maxChunkBytes)

        let source = try MobileFileStore.resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw MobileFileStore.StoreError.fileNotFound
        }
        guard !isDirectory.boolValue else { throw TransferError.destinationIsDirectory }
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard offset <= size else { throw TransferError.invalidOffset }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: chunkSize) ?? Data()
        return [
            "path": MobileFileStore.relativePath(source),
            "offset": offset,
            "bytes": data.count,
            "size": size,
            "eof": offset + data.count >= size,
            "sha256": sha256(data),
            "data_b64": data.base64EncodedString(),
        ]
    }

    private func beginWrite(_ args: [String: Any]) throws -> [String: Any] {
        guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
        let overwrite = (args["overwrite"] as? Bool) ?? true
        let expectedBytes = (args["expected_bytes"] as? NSNumber)?.intValue
        if let expectedBytes, expectedBytes < 0 { throw TransferError.invalidExpectedMetadata }

        let destination = try MobileFileStore.resolve(path)
        guard destination.standardizedFileURL != MobileFileStore.root.standardizedFileURL else {
            throw MobileFileStore.StoreError.unsafePath
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue { throw TransferError.destinationIsDirectory }
        if exists && !overwrite { throw TransferError.destinationExists }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let transferID = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).local-shell-mcp-transfer-\(transferID).tmp"
        )
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data()) else {
            throw TransferError.invalidTransferID
        }
        writeSessions[transferID] = WriteSession(
            id: transferID,
            destination: destination,
            temporary: temporary,
            overwrite: overwrite,
            expectedBytes: expectedBytes,
            bytesReceived: 0
        )
        return [
            "path": MobileFileStore.relativePath(destination),
            "temp_path": MobileFileStore.relativePath(temporary),
            "transfer_id": transferID,
            "created": !exists,
            "expected_bytes": expectedBytes.map { $0 } ?? NSNull(),
        ]
    }

    private func writeChunk(_ args: [String: Any]) throws -> [String: Any] {
        guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
        guard let transferID = args["transfer_id"] as? String else {
            throw TransferError.missingArgument("transfer_id")
        }
        guard let offset = (args["offset"] as? NSNumber)?.intValue else {
            throw TransferError.missingArgument("offset")
        }
        guard offset >= 0 else { throw TransferError.invalidOffset }
        guard let encoded = args["data_b64"] as? String else {
            throw TransferError.missingArgument("data_b64")
        }
        guard let data = Data(base64Encoded: encoded) else { throw TransferError.invalidBase64 }
        guard data.count <= maxChunkBytes else { throw TransferError.chunkTooLarge }
        guard var session = writeSessions[transferID] else { throw TransferError.invalidTransferID }
        let destination = try MobileFileStore.resolve(path)
        guard destination.standardizedFileURL == session.destination.standardizedFileURL else {
            throw TransferError.invalidTransferID
        }
        guard offset == session.bytesReceived else { throw TransferError.nonSequentialChunk }
        if let expected = session.expectedBytes, offset + data.count > expected {
            throw TransferError.sizeMismatch
        }
        let digest = sha256(data)
        if let expectedHash = args["expected_sha256"] as? String,
           digest.lowercased() != expectedHash.lowercased() {
            throw TransferError.hashMismatch
        }

        let handle = try FileHandle(forWritingTo: session.temporary)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        session.bytesReceived += data.count
        writeSessions[transferID] = session
        return [
            "path": MobileFileStore.relativePath(session.destination),
            "temp_path": MobileFileStore.relativePath(session.temporary),
            "offset": offset,
            "bytes": data.count,
            "sha256": digest,
        ]
    }

    private func finishWrite(_ args: [String: Any]) throws -> [String: Any] {
        guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
        guard let transferID = args["transfer_id"] as? String else {
            throw TransferError.missingArgument("transfer_id")
        }
        guard let session = writeSessions[transferID] else { throw TransferError.invalidTransferID }
        let destination = try MobileFileStore.resolve(path)
        guard destination.standardizedFileURL == session.destination.standardizedFileURL else {
            throw TransferError.invalidTransferID
        }
        let explicitExpected = (args["expected_bytes"] as? NSNumber)?.intValue
        let expectedBytes = explicitExpected ?? session.expectedBytes
        if let expectedBytes, expectedBytes < 0 { throw TransferError.invalidExpectedMetadata }
        let attrs = try FileManager.default.attributesOfItem(atPath: session.temporary.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        if let expectedBytes, size != expectedBytes { throw TransferError.sizeMismatch }
        guard size == session.bytesReceived else { throw TransferError.sizeMismatch }

        let expectedHash = args["expected_sha256"] as? String
        let digest = try MobileFileStore.sha256(session.temporary)
        if let expectedHash, digest.lowercased() != expectedHash.lowercased() {
            throw TransferError.hashMismatch
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            if !session.overwrite { throw TransferError.destinationExists }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: session.temporary)
        } else {
            try FileManager.default.moveItem(at: session.temporary, to: destination)
        }
        writeSessions.removeValue(forKey: transferID)
        return [
            "path": MobileFileStore.relativePath(destination),
            "bytes": size,
            "sha256": expectedHash == nil ? NSNull() : digest,
            "completed": true,
        ]
    }

    private func abortWrite(_ args: [String: Any]) throws -> [String: Any] {
        guard let path = args["path"] as? String else { throw TransferError.missingArgument("path") }
        guard let transferID = args["transfer_id"] as? String else {
            throw TransferError.missingArgument("transfer_id")
        }
        let destination = try MobileFileStore.resolve(path)
        guard let session = writeSessions[transferID],
              destination.standardizedFileURL == session.destination.standardizedFileURL else {
            throw TransferError.invalidTransferID
        }
        writeSessions.removeValue(forKey: transferID)
        let existed = FileManager.default.fileExists(atPath: session.temporary.path)
        if existed { try FileManager.default.removeItem(at: session.temporary) }
        return [
            "path": MobileFileStore.relativePath(destination),
            "temp_path": MobileFileStore.relativePath(session.temporary),
            "deleted": existed,
        ]
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
