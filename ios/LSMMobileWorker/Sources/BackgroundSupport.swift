import BackgroundTasks
import Foundation
import UIKit

@MainActor
enum PushRegistrationStore {
    private static let defaults = UserDefaults.standard
    private static let tokenKey = "worker.push.device_token"
    private static let registeredKey = "worker.push.controller_registered"
    private static let errorKey = "worker.push.last_error"
    private static let wakeKey = "worker.push.last_wake"
    private static let reasonKey = "worker.push.last_wake_reason"

    static var environment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    static var pushBuildEnabled: Bool {
        #if LSM_PUSH_NOTIFICATIONS
        return true
        #else
        return false
        #endif
    }

    static var deviceToken: String? {
        let value = defaults.string(forKey: tokenKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static func recordDeviceToken(_ data: Data) {
        defaults.set(data.map { String(format: "%02x", $0) }.joined(), forKey: tokenKey)
        defaults.set(false, forKey: registeredKey)
        defaults.removeObject(forKey: errorKey)
    }

    static func recordRegistrationFailure(_ error: String) {
        defaults.set(false, forKey: registeredKey)
        defaults.set(error, forKey: errorKey)
    }

    static func recordControllerRegistration(success: Bool, error: String?) {
        defaults.set(success, forKey: registeredKey)
        if let error, !error.isEmpty {
            defaults.set(error, forKey: errorKey)
        } else if success {
            defaults.removeObject(forKey: errorKey)
        }
    }

    static func recordBackgroundWake(reason: String) {
        defaults.set(Date().timeIntervalSince1970, forKey: wakeKey)
        defaults.set(reason, forKey: reasonKey)
    }

    static func status() -> [String: Any] {
        let lastWake = defaults.double(forKey: wakeKey)
        return [
            "mode": pushBuildEnabled ? "apns_bgapprefresh_best_effort" : "bgapprefresh_best_effort",
            "push_build_enabled": pushBuildEnabled,
            "device_token_available": deviceToken != nil,
            "controller_registered": defaults.bool(forKey: registeredKey),
            "environment": environment,
            "last_wake_at": lastWake > 0 ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: lastWake)) : NSNull(),
            "last_wake_reason": defaults.string(forKey: reasonKey) ?? NSNull(),
            "last_error": defaults.string(forKey: errorKey) ?? NSNull(),
        ]
    }
}

final class LSMAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundWakeScheduler.register()
        #if LSM_PUSH_NOTIFICATIONS
        application.registerForRemoteNotifications()
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushRegistrationStore.recordDeviceToken(deviceToken)
            if let identity = WorkerBackgroundCoordinator.shared.savedIdentity() {
                await WorkerBackgroundCoordinator.shared.syncPushRegistration(identity: identity)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushRegistrationStore.recordRegistrationFailure(error.localizedDescription)
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let reason = (userInfo["lsm"] as? [String: Any])?["reason"] as? String ?? "apns"
        Task { @MainActor in
            let jobs = await WorkerBackgroundCoordinator.shared.performWake(reason: reason, maxDuration: 22)
            completionHandler(jobs > 0 ? .newData : .noData)
        }
    }
}

enum BackgroundWakeScheduler {
    static let refreshIdentifier = "com.xycdev.lsmmobileworker.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
        scheduleRefresh()
    }

    static func scheduleRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            let jobs = await WorkerBackgroundCoordinator.shared.performWake(reason: "bg_app_refresh", maxDuration: 20)
            task.setTaskCompleted(success: jobs >= 0)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
