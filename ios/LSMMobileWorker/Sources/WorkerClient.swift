import Foundation
import SwiftUI
import UIKit

struct WorkerSessionSettings {
    let pollTimeout: TimeInterval
    let heartbeatInterval: TimeInterval
}

enum WorkerClientError: LocalizedError {
    case invalidServer
    case invalidResponse
    case controller(String)
    case missingInvite
    case unsupportedUpgrade

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "The controller URL is invalid."
        case .invalidResponse: return "The controller returned an invalid response."
        case .controller(let message): return message
        case .missingInvite: return "Enter a fresh LSM remote-worker invite code to pair this device."
        case .unsupportedUpgrade: return "The controller requested a Python worker upgrade, which is not valid for the native iOS worker."
        }
    }
}

@MainActor
struct LSMHTTPClient {
    func register(server: String, invite: String, name: String) async throws -> (WorkerIdentity, WorkerSessionSettings) {
        let payload: [String: Any] = [
            "invite": invite,
            "name": name,
            "workdir": "Documents/LSM",
            "capabilities": MobileActionExecutor.capabilities,
            "info": MobileActionExecutor.workerInfo(),
        ]
        let data = try await post(server: server, path: "/remote/register", payload: payload, token: nil, timeout: 30)
        guard let token = data["token"] as? String,
              let actualName = data["name"] as? String else {
            throw WorkerClientError.invalidResponse
        }
        return (
            WorkerIdentity(server: normalizeServer(server), name: actualName, token: token),
            settings(from: data)
        )
    }

    func resume(identity: WorkerIdentity) async throws -> WorkerSessionSettings {
        let payload: [String: Any] = [
            "name": identity.name,
            "workdir": "Documents/LSM",
            "capabilities": MobileActionExecutor.capabilities,
            "info": MobileActionExecutor.workerInfo(),
        ]
        let data = try await post(
            server: identity.server,
            path: "/remote/resume",
            payload: payload,
            token: identity.token,
            timeout: 30
        )
        return settings(from: data)
    }

    func poll(identity: WorkerIdentity, pollTimeout: TimeInterval) async throws -> [String: Any] {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let payload: [String: Any] = [
            "protocol_version": 2,
            "worker_version": "\(appVersion)-ios",
            "supports_self_update": false,
            "poll_timeout_s": min(max(pollTimeout, 5), 20),
            "info": MobileActionExecutor.resourceSnapshot(),
        ]
        return try await post(
            server: identity.server,
            path: "/remote/poll",
            payload: payload,
            token: identity.token,
            timeout: min(max(pollTimeout + 12, 20), 40)
        )
    }

    func heartbeat(identity: WorkerIdentity, jobID: String?) async throws -> [String: Any] {
        var payload: [String: Any] = ["info": MobileActionExecutor.resourceSnapshot()]
        if let jobID { payload["job_id"] = jobID }
        return try await post(
            server: identity.server,
            path: "/remote/heartbeat",
            payload: payload,
            token: identity.token,
            timeout: 15
        )
    }

    func submit(identity: WorkerIdentity, payload: [String: Any]) async throws {
        _ = try await post(
            server: identity.server,
            path: "/remote/result",
            payload: payload,
            token: identity.token,
            timeout: 30
        )
    }

    private func settings(from data: [String: Any]) -> WorkerSessionSettings {
        WorkerSessionSettings(
            pollTimeout: (data["poll_timeout_s"] as? NSNumber)?.doubleValue ?? 20,
            heartbeatInterval: (data["heartbeat_interval_s"] as? NSNumber)?.doubleValue ?? 10
        )
    }

    private func post(
        server: String,
        path: String,
        payload: [String: Any],
        token: String?,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let base = normalizeServer(server)
        guard let url = URL(string: base + path), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw WorkerClientError.invalidServer
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WorkerClientError.invalidResponse
        }
        let object = try JSONSerialization.jsonObject(with: body)
        guard let envelope = object as? [String: Any] else {
            throw WorkerClientError.invalidResponse
        }
        let message = envelope["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        guard (200..<300).contains(http.statusCode), envelope["ok"] as? Bool == true else {
            throw WorkerClientError.controller(message)
        }
        guard let data = envelope["data"] as? [String: Any] else {
            return [:]
        }
        return data
    }

    private func normalizeServer(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

@MainActor
final class WorkerViewModel: ObservableObject {
    @Published var server: String
    @Published var workerName: String
    @Published var invite = ""
    @Published private(set) var status = "Disconnected"
    @Published private(set) var detail = ""
    @Published private(set) var connected = false
    @Published private(set) var paired = false
    @Published private(set) var lastAction = "None"

    private let http = LSMHTTPClient()
    let executor = MobileActionExecutor()
    private var identity: WorkerIdentity?
    private var connectionTask: Task<Void, Never>?
    private var sessionSettings = WorkerSessionSettings(pollTimeout: 20, heartbeatInterval: 10)

    init() {
        server = UserDefaults.standard.string(forKey: "controller.server") ?? "https://mcp.xycdev.com"
        workerName = UserDefaults.standard.string(forKey: "worker.name") ?? "morrow-iphone"
        if let data = try? KeychainStore.load(),
           let saved = try? JSONDecoder().decode(WorkerIdentity.self, from: data) {
            identity = saved
            server = saved.server
            workerName = saved.name
            paired = true
        }
    }

    func startIfConfigured() {
        guard paired, connectionTask == nil else { return }
        connect()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active, paired, connectionTask == nil {
            connect()
        }
    }

    func connect() {
        guard connectionTask == nil else { return }
        UserDefaults.standard.set(server, forKey: "controller.server")
        UserDefaults.standard.set(workerName, forKey: "worker.name")
        status = "Connecting"
        detail = ""
        connectionTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        connected = false
        status = "Disconnected"
        detail = "The app remains paired and will reconnect when requested."
    }

    func unpair() {
        disconnect()
        KeychainStore.clear()
        identity = nil
        paired = false
        invite = ""
        detail = "Pairing identity removed from Keychain."
    }

    func requestNotificationPermission() async {
        do {
            let granted = try await executor.requestNotificationPermission()
            detail = granted ? "Notification permission granted." : "Notification permission was not granted."
        } catch {
            detail = error.localizedDescription
        }
    }

    func requestLocationPermission() {
        executor.requestLocationPermission()
        detail = "Location permission requested."
    }

    private func runConnectionLoop() async {
        defer {
            connectionTask = nil
            connected = false
            if Task.isCancelled { status = "Disconnected" }
        }

        do {
            if identity == nil {
                guard !invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkerClientError.missingInvite
                }
                let result = try await http.register(server: server, invite: invite, name: workerName)
                identity = result.0
                sessionSettings = result.1
                try persistIdentity(result.0)
                paired = true
                workerName = result.0.name
                server = result.0.server
                invite = ""
            } else if let identity {
                sessionSettings = try await http.resume(identity: identity)
            }

            connected = true
            status = "Online"
            detail = "Connected to LSM controller. Keep the app active for continuous polling."

            var retryDelay: UInt64 = 1
            while !Task.isCancelled {
                guard let identity else { return }
                do {
                    let payload = try await http.poll(identity: identity, pollTimeout: sessionSettings.pollTimeout)
                    if let timeout = (payload["poll_timeout_s"] as? NSNumber)?.doubleValue {
                        sessionSettings = WorkerSessionSettings(
                            pollTimeout: timeout,
                            heartbeatInterval: sessionSettings.heartbeatInterval
                        )
                    }
                    if let upgrade = payload["upgrade"] as? [String: Any], upgrade["required"] as? Bool == true {
                        throw WorkerClientError.unsupportedUpgrade
                    }
                    if let job = payload["job"] as? [String: Any] {
                        try await handle(job: job, identity: identity)
                    }
                    retryDelay = 1
                    connected = true
                    status = "Online"
                } catch is CancellationError {
                    return
                } catch {
                    connected = false
                    status = "Reconnecting"
                    detail = error.localizedDescription
                    try? await Task.sleep(for: .seconds(Double(retryDelay)))
                    retryDelay = min(retryDelay * 2, 30)
                }
            }
        } catch {
            status = "Error"
            detail = error.localizedDescription
            if case WorkerClientError.controller(let message) = error,
               message.localizedCaseInsensitiveContains("identity") {
                KeychainStore.clear()
                identity = nil
                paired = false
            }
        }
    }

    private func handle(job: [String: Any], identity: WorkerIdentity) async throws {
        guard let jobID = job["id"] as? String else { return }
        if let expires = (job["expires_at"] as? NSNumber)?.doubleValue,
           expires > 0,
           expires < Date().timeIntervalSince1970 {
            try await http.submit(identity: identity, payload: [
                "job_id": jobID,
                "ok": false,
                "error": "TimeoutError",
                "message": "remote job expired before execution",
            ])
            return
        }

        let tool = job["tool"] as? String ?? ""
        let args = job["args"] as? [String: Any] ?? [:]
        lastAction = (args["action"] as? String) ?? tool

        let heartbeat = Task { [http, sessionSettings] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(2, sessionSettings.heartbeatInterval)))
                if Task.isCancelled { return }
                _ = try? await http.heartbeat(identity: identity, jobID: jobID)
            }
        }
        defer { heartbeat.cancel() }

        do {
            let result = try await executor.execute(tool: tool, args: args)
            try await http.submit(identity: identity, payload: [
                "job_id": jobID,
                "ok": true,
                "data": result,
            ])
        } catch {
            try await http.submit(identity: identity, payload: [
                "job_id": jobID,
                "ok": false,
                "error": String(describing: type(of: error)),
                "message": error.localizedDescription,
            ])
        }
    }

    private func persistIdentity(_ identity: WorkerIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        try KeychainStore.save(data)
    }
}
