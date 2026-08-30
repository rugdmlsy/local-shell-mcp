@preconcurrency import AVFoundation
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

@MainActor
final class MobileMediaProvider {
    enum MediaError: LocalizedError {
        case cameraPermissionRequired
        case photoPermissionRequired
        case foregroundRequired
        case cameraUnavailable
        case captureFailed
        case assetNotFound
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .cameraPermissionRequired: return "Camera permission is required. Grant it from the app first."
            case .photoPermissionRequired: return "Photo Library permission is required. Grant it from the app first."
            case .foregroundRequired: return "Camera capture requires LSM Worker to be in the foreground."
            case .cameraUnavailable: return "The requested camera is unavailable."
            case .captureFailed: return "The camera did not return a usable still image."
            case .assetNotFound: return "The requested photo asset was not found."
            case .exportFailed(let message): return "Photo export failed: \(message)"
            }
        }
    }

    func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    func requestPhotoPermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited { return true }
        if current == .denied || current == .restricted { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status == .authorized || status == .limited)
            }
        }
    }

    func permissionInfo() -> [String: String] {
        [
            "camera": cameraAuthorizationName(AVCaptureDevice.authorizationStatus(for: .video)),
            "photos": photoAuthorizationName(PHPhotoLibrary.authorizationStatus(for: .readWrite)),
        ]
    }

    func capture(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard UIApplication.shared.applicationState == .active else { throw MediaError.foregroundRequired }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw MediaError.cameraPermissionRequired
        }
        let requested = ((arguments["camera"] as? String) ?? "back").lowercased()
        let position: AVCaptureDevice.Position = requested == "front" ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw MediaError.cameraUnavailable
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw MediaError.cameraUnavailable }
        session.addInput(input)
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else { throw MediaError.cameraUnavailable }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        defer { session.stopRunning() }

        let delegate = PhotoCaptureDelegate()
        let data = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
        guard !data.isEmpty else { throw MediaError.captureFailed }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let defaultPath = "Captures/camera-\(formatter.string(from: Date())).jpg"
        let path = (arguments["path"] as? String) ?? defaultPath
        let destination = try MobileFileStore.resolve(path)
        guard destination.standardizedFileURL != MobileFileStore.root.standardizedFileURL else {
            throw MobileFileStore.StoreError.unsafePath
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)

        var result: [String: Any] = [
            "path": MobileFileStore.relativePath(destination),
            "bytes": data.count,
            "mime_type": "image/jpeg",
            "camera": requested == "front" ? "front" : "back",
            "sha256": try MobileFileStore.sha256(destination),
        ]
        if let image = UIImage(data: data) {
            result["width"] = Int(image.size.width * image.scale)
            result["height"] = Int(image.size.height * image.scale)
        }
        return result
    }

    func listPhotos(_ arguments: [String: Any]) throws -> [String: Any] {
        try requirePhotoPermission()
        let requested = (arguments["limit"] as? NSNumber)?.intValue ?? 20
        let limit = min(max(requested, 1), 50)
        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var rows: [[String: Any]] = []
        assets.enumerateObjects { asset, _, _ in
            var row: [String: Any] = [
                "local_identifier": asset.localIdentifier,
                "pixel_width": asset.pixelWidth,
                "pixel_height": asset.pixelHeight,
                "favorite": asset.isFavorite,
            ]
            if let date = asset.creationDate {
                row["created_at"] = ISO8601DateFormatter().string(from: date)
            }
            rows.append(row)
        }
        return ["items": rows, "count": rows.count, "limited_access": PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited]
    }

    func exportPhoto(_ arguments: [String: Any]) async throws -> [String: Any] {
        try requirePhotoPermission()
        guard let identifier = arguments["local_identifier"] as? String, !identifier.isEmpty else {
            throw MobileActionExecutor.ActionError.missingArgument("local_identifier")
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { throw MediaError.assetNotFound }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { [.photo, .fullSizePhoto, .alternatePhoto].contains($0.type) }) ?? resources.first else {
            throw MediaError.assetNotFound
        }

        let safeName = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
        let defaultPath = "Photos/\(UUID().uuidString.prefix(8))-\(safeName)"
        let path = (arguments["path"] as? String) ?? defaultPath
        let destination = try MobileFileStore.resolve(path)
        guard destination.standardizedFileURL != MobileFileStore.root.standardizedFileURL else {
            throw MobileFileStore.StoreError.unsafePath
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = (arguments["allow_network"] as? Bool) ?? false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: MediaError.exportFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return [
            "path": MobileFileStore.relativePath(destination),
            "bytes": bytes,
            "sha256": try MobileFileStore.sha256(destination),
            "mime_type": UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream",
            "original_filename": safeName,
            "pixel_width": asset.pixelWidth,
            "pixel_height": asset.pixelHeight,
        ]
    }

    private func requirePhotoPermission() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw MediaError.photoPermissionRequired }
    }

    private func cameraAuthorizationName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    private func photoAuthorizationName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    var continuation: CheckedContinuation<Data, Error>?

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: MobileMediaProvider.MediaError.captureFailed)
            return
        }
        continuation.resume(returning: data)
    }
}
