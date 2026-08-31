import Foundation

@MainActor
struct WorkerJobRunner {
    let http: LSMHTTPClient
    let executor: MobileActionExecutor

    func handle(
        job: [String: Any],
        identity: WorkerIdentity,
        heartbeatInterval: TimeInterval = 10,
        onAction: ((String) -> Void)? = nil
    ) async throws {
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
        let action = (args["action"] as? String) ?? tool
        WorkerStatusStore.recordAction(action)
        onAction?(action)

        let work = Task<Any, Error> {
            try await executor.execute(
                tool: tool,
                args: args,
                controllerServer: identity.server
            )
        }
        let heartbeat = Task { [http] in
            while !Task.isCancelled && !work.isCancelled {
                try? await Task.sleep(for: .seconds(max(2, heartbeatInterval)))
                if Task.isCancelled || work.isCancelled { return }
                if let response = try? await http.heartbeat(identity: identity, jobID: jobID),
                   response["cancelled"] as? Bool == true {
                    work.cancel()
                    return
                }
            }
        }
        defer {
            heartbeat.cancel()
            if Task.isCancelled { work.cancel() }
        }

        do {
            let result = try await work.value
            try await http.submit(identity: identity, payload: [
                "job_id": jobID,
                "ok": true,
                "data": result,
            ])
        } catch is CancellationError {
            try? await http.submit(identity: identity, payload: [
                "job_id": jobID,
                "ok": false,
                "error": "CancellationError",
                "message": "remote job was cancelled by the controller",
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
}

@MainActor
final class WorkerBackgroundCoordinator {
    static let shared = WorkerBackgroundCoordinator()

    private let http = LSMHTTPClient()
    private let executor = MobileActionExecutor()

    private init() {}

    func savedIdentity() -> WorkerIdentity? {
        guard let data = try? KeychainStore.load(),
              let identity = try? JSONDecoder().decode(WorkerIdentity.self, from: data) else {
            return nil
        }
        return identity
    }

    func syncPushRegistration(identity: WorkerIdentity) async {
        guard let token = PushRegistrationStore.deviceToken else { return }
        do {
            try await http.registerPushToken(
                identity: identity,
                token: token,
                environment: PushRegistrationStore.environment
            )
            PushRegistrationStore.recordControllerRegistration(success: true, error: nil)
        } catch {
            PushRegistrationStore.recordControllerRegistration(success: false, error: error.localizedDescription)
        }
    }

    func performWake(reason: String, maxDuration: TimeInterval = 22) async -> Int {
        guard let identity = savedIdentity() else {
            WorkerStatusStore.recordConnected(false)
            return 0
        }
        let deadline = Date().addingTimeInterval(min(max(maxDuration, 3), 25))
        do {
            let settings = try await http.resume(identity: identity)
            await syncPushRegistration(identity: identity)
            WorkerStatusStore.recordConnected(true)
            PushRegistrationStore.recordBackgroundWake(reason: reason)
            let runner = WorkerJobRunner(http: http, executor: executor)
            var completed = 0
            while !Task.isCancelled, Date() < deadline, completed < 4 {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 1 { break }
                let payload = try await http.poll(
                    identity: identity,
                    pollTimeout: min(5, max(1, remaining - 1))
                )
                if let upgrade = payload["upgrade"] as? [String: Any],
                   upgrade["required"] as? Bool == true {
                    throw WorkerClientError.unsupportedUpgrade
                }
                guard let job = payload["job"] as? [String: Any] else { break }
                try await runner.handle(
                    job: job,
                    identity: identity,
                    heartbeatInterval: settings.heartbeatInterval
                )
                completed += 1
            }
            WorkerStatusStore.recordConnected(true)
            return completed
        } catch {
            WorkerStatusStore.recordConnected(false)
            WorkerStatusStore.recordError(error.localizedDescription)
            return 0
        }
    }
}

enum WorkerStatusStore {
    private static let defaults = UserDefaults.standard
    private static let connectedKey = "worker.runtime.connected"
    private static let actionKey = "worker.runtime.last_action"
    private static let seenKey = "worker.runtime.last_seen"
    private static let errorKey = "worker.runtime.last_error"

    static func recordConnected(_ connected: Bool) {
        defaults.set(connected, forKey: connectedKey)
        if connected { defaults.set(Date().timeIntervalSince1970, forKey: seenKey) }
    }

    static func recordAction(_ action: String) {
        defaults.set(action, forKey: actionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: seenKey)
    }

    static func recordError(_ error: String) {
        defaults.set(error, forKey: errorKey)
    }

    static var connected: Bool { defaults.bool(forKey: connectedKey) }
    static var lastAction: String { defaults.string(forKey: actionKey) ?? "None" }
    static var lastSeen: Date? {
        let value = defaults.double(forKey: seenKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}
