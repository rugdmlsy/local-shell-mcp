import Foundation
import UIKit
import UserNotifications

@MainActor
final class MobileActionExecutor {
    enum ActionError: LocalizedError {
        case unsupportedTool(String)
        case unsupportedAction(String)
        case missingArgument(String)
        case notificationPermissionRequired
        case foregroundRequired
        case unsafeURL
        case unsafePath
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedTool(let tool): return "Unsupported worker tool: \(tool)"
            case .unsupportedAction(let action): return "Unsupported mobile action: \(action)"
            case .missingArgument(let name): return "Missing required argument: \(name)"
            case .notificationPermissionRequired: return "Notification permission is required. Grant it from the app first."
            case .foregroundRequired: return "This action requires the LSM Worker app to be in the foreground."
            case .unsafeURL: return "Only HTTP and HTTPS URLs may be opened by the mobile worker."
            case .unsafePath: return "The requested path escapes the LSM app sandbox."
            case .fileTooLarge: return "The requested file exceeds the mobile worker size limit."
            }
        }
    }

    static let capabilities: [String] = {
        var values = [
            "mobile",
            "mobile.device_info",
            "mobile.battery",
            "mobile.notifications",
            "mobile.location",
            "mobile.open_url",
            "mobile.files",
            "mobile.file_transfer",
            "mobile.background_refresh",
            "mobile.camera",
            "mobile.photos",
            "mobile.network",
            "mobile.approval",
            "mobile.external_files",
            "mobile.clipboard",
        ]
        #if LSM_PUSH_NOTIFICATIONS
        values.append("mobile.background_wake")
        #endif
        #if LSM_SHARE_EXTENSION
        values.append("mobile.share_extension")
        #endif
        return values
    }()

    private let locationProvider = LocationProvider()
    private let mediaProvider = MobileMediaProvider()
    private let networkProvider = MobileNetworkProvider()
    private let transferExecutor = MobileTransferExecutor()
    private let externalFiles = ExternalFileAccessManager.shared
    private let clipboard = MobileClipboardProvider.shared
    private let fileManager = FileManager.default
    private let maxReadBytes = 512 * 1024
    private let maxWriteBytes = 5 * 1024 * 1024

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        try? MobileFileStore.ensureRoot()
    }

    static var filesRoot: URL { MobileFileStore.root }

    static func workerInfo() -> [String: Any] {
        let process = ProcessInfo.processInfo
        return [
            "hostname": process.hostName,
            "user": "mobile",
            "cwd": "Documents/LSM",
            "workdir": "Documents/LSM",
            "platform": "ios",
            "system": UIDevice.current.systemName,
            "release": UIDevice.current.systemVersion,
            "model": UIDevice.current.model,
            "cpu_count": process.processorCount,
            "memory_total_bytes": NSNumber(value: process.physicalMemory),
            "worker_kind": "native-ios",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
        ]
    }

    static func resourceSnapshot() -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return [
            "battery_percent": level < 0 ? NSNull() : Int(level * 100),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "app_state": appStateName(UIApplication.shared.applicationState),
        ]
    }

    func requestNotificationPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func requestLocationPermission() {
        locationProvider.requestPermission()
    }

    func requestCameraPermission() async -> Bool {
        await mediaProvider.requestCameraPermission()
    }

    func requestPhotoPermission() async -> Bool {
        await mediaProvider.requestPhotoPermission()
    }

    func execute(tool: String, args: [String: Any], controllerServer: String) async throws -> Any {
        if tool != "mobile_action" {
            return try await transferExecutor.execute(tool: tool, args: args, controllerServer: controllerServer)
        }
        guard let action = args["action"] as? String else {
            throw ActionError.missingArgument("action")
        }
        let arguments = args["arguments"] as? [String: Any] ?? [:]

        switch action {
        case "capabilities":
            return await capabilityInfo()
        case "device_info":
            return Self.workerInfo().merging(Self.resourceSnapshot()) { _, new in new }
        case "battery":
            return batteryInfo()
        case "notify":
            return try await notify(arguments)
        case "location":
            return try await location()
        case "open_url":
            return try await openURL(arguments)
        case "list_files":
            return try listFiles(arguments)
        case "read_text":
            return try readText(arguments)
        case "write_text":
            return try writeText(arguments)
        case "delete_file":
            return try deleteFile(arguments)
        case "camera_capture":
            return try await mediaProvider.capture(arguments)
        case "photos_list":
            return try mediaProvider.listPhotos(arguments)
        case "photos_export":
            return try await mediaProvider.exportPhoto(arguments)
        case "network_status":
            return networkProvider.status()
        case "network_history":
            return networkProvider.historyInfo()
        case "dns_probe":
            return try await networkProvider.dnsProbe(arguments)
        case "tcp_probe":
            return try await networkProvider.tcpProbe(arguments)
        case "tls_probe":
            return try await networkProvider.tlsProbe(arguments)
        case "http_probe":
            return try await networkProvider.httpProbe(arguments)
        case "bookmarks_list":
            return externalFiles.list()
        case "bookmark_import":
            return try externalFiles.importToSandbox(arguments)
        case "bookmark_export":
            return try externalFiles.exportFromSandbox(arguments)
        case "clipboard_status":
            return clipboard.status()
        case "clipboard_write":
            return try clipboard.write(arguments)
        case "clipboard_read":
            return try clipboard.read()
        #if LSM_SHARE_EXTENSION
        case "shared_inbox_import":
            return try SharedInboxImporter.shared.importPending()
        #endif
        case "approval_prompt":
            let decision = try await ApprovalPromptCoordinator.shared.prompt(arguments)
            return [
                "request_id": decision.requestID,
                "approved": decision.approved,
                "decision": decision.approved ? "approved" : "rejected",
                "responded_at": ISO8601DateFormatter().string(from: decision.respondedAt),
            ]
        default:
            throw ActionError.unsupportedAction(action)
        }
    }

    private func capabilityInfo() async -> [String: Any] {
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        var permissions: [String: String] = [
            "notifications": notificationAuthorizationName(notificationSettings.authorizationStatus),
            "location": locationProvider.authorizationStatusName(),
        ]
        for (key, value) in mediaProvider.permissionInfo() {
            permissions[key] = value
        }
        var result: [String: Any] = [
            "capabilities": Self.capabilities,
            "files_root": "Documents/LSM",
            "permissions": permissions,
            "background_wake": PushRegistrationStore.status(),
            "external_files": externalFiles.list(),
            "clipboard": clipboard.status(),
        ]
        #if LSM_SHARE_EXTENSION
        result["share_inbox_pending"] = SharedInboxImporter.shared.pendingCount()
        #endif
        return result
    }

    private func batteryInfo() -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return [
            "percent": level < 0 ? NSNull() : Int(level * 100),
            "state": batteryStateName(UIDevice.current.batteryState),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        ]
    }

    private func notify(_ arguments: [String: Any]) async throws -> [String: Any] {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ActionError.notificationPermissionRequired
        }
        let title = (arguments["title"] as? String) ?? "LSM"
        let body = (arguments["body"] as? String) ?? "Remote action completed."
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let identifier = "lsm-\(UUID().uuidString)"
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        return ["scheduled": true, "identifier": identifier]
    }

    private func location() async throws -> [String: Any] {
        let value = try await locationProvider.currentLocation()
        return [
            "latitude": value.coordinate.latitude,
            "longitude": value.coordinate.longitude,
            "horizontal_accuracy_m": value.horizontalAccuracy,
            "altitude_m": value.altitude,
            "timestamp": ISO8601DateFormatter().string(from: value.timestamp),
        ]
    }

    private func openURL(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard UIApplication.shared.applicationState == .active else {
            throw ActionError.foregroundRequired
        }
        guard let raw = arguments["url"] as? String, let url = URL(string: raw) else {
            throw ActionError.missingArgument("url")
        }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ActionError.unsafeURL
        }
        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
        return ["opened": opened, "url": raw]
    }

    private func listFiles(_ arguments: [String: Any]) throws -> [String: Any] {
        let relative = (arguments["path"] as? String) ?? "."
        let directory = try resolve(relative)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ["path": relative, "items": []]
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let items: [[String: Any]] = try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            var row: [String: Any] = [
                "name": url.lastPathComponent,
                "path": relativePath(url),
                "type": values.isDirectory == true ? "directory" : "file",
            ]
            if let size = values.fileSize { row["bytes"] = size }
            if let modified = values.contentModificationDate {
                row["modified_at"] = ISO8601DateFormatter().string(from: modified)
            }
            return row
        }
        return ["path": relative, "items": items]
    }

    private func readText(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let path = arguments["path"] as? String else {
            throw ActionError.missingArgument("path")
        }
        let url = try resolve(path)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard bytes <= maxReadBytes else { throw ActionError.fileTooLarge }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return ["path": relativePath(url), "bytes": data.count, "text": text]
    }

    private func writeText(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let path = arguments["path"] as? String else {
            throw ActionError.missingArgument("path")
        }
        guard let text = arguments["text"] as? String else {
            throw ActionError.missingArgument("text")
        }
        let data = Data(text.utf8)
        guard data.count <= maxWriteBytes else { throw ActionError.fileTooLarge }
        let url = try resolve(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return ["path": relativePath(url), "bytes": data.count, "written": true]
    }

    private func deleteFile(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let path = arguments["path"] as? String else {
            throw ActionError.missingArgument("path")
        }
        let url = try resolve(path)
        guard url.standardizedFileURL != Self.filesRoot.standardizedFileURL else {
            throw ActionError.unsafePath
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return ["path": relativePath(url), "deleted": true]
    }

    private func resolve(_ relative: String) throws -> URL {
        let root = Self.filesRoot.standardizedFileURL
        let clean = relative == "." ? "" : relative
        guard !clean.hasPrefix("/") else { throw ActionError.unsafePath }
        let target = root.appendingPathComponent(clean).standardizedFileURL
        guard target == root || target.path.hasPrefix(root.path + "/") else {
            throw ActionError.unsafePath
        }
        return target
    }

    private func relativePath(_ url: URL) -> String {
        let root = Self.filesRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root { return "." }
        return String(path.dropFirst(root.count + 1))
    }

    private func notificationAuthorizationName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    private static func appStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
