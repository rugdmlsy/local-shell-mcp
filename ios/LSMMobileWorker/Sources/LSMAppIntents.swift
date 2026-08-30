import AppIntents
import Foundation

struct LSMWorkerCheckInIntent: AppIntent {
    static var title: LocalizedStringResource = "Check In LSM Worker"
    static var description = IntentDescription("Reconnect the paired LSM mobile worker and process a bounded amount of pending work.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let jobs = await WorkerBackgroundCoordinator.shared.performWake(reason: "app_intent", maxDuration: 20)
        let message: String
        if await WorkerBackgroundCoordinator.shared.savedIdentity() == nil {
            message = "LSM Worker is not paired."
        } else if jobs == 0 {
            message = "LSM Worker checked in. No pending jobs were processed."
        } else {
            message = "LSM Worker checked in and processed \(jobs) pending job\(jobs == 1 ? "" : "s")."
        }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct LSMWorkerStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "LSM Worker Status"
    static var description = IntentDescription("Report the last locally known LSM Worker state without exposing its controller token.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let paired = await WorkerBackgroundCoordinator.shared.savedIdentity() != nil
        let connected = await MainActor.run { WorkerStatusStore.connected }
        let lastAction = await MainActor.run { WorkerStatusStore.lastAction }
        let lastSeen = await MainActor.run { WorkerStatusStore.lastSeen }
        var message = paired ? (connected ? "LSM Worker is paired and recently connected." : "LSM Worker is paired but not currently connected.") : "LSM Worker is not paired."
        if lastAction != "None" { message += " Last action: \(lastAction)." }
        if let lastSeen {
            message += " Last activity: \(lastSeen.formatted(date: .abbreviated, time: .shortened))."
        }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct OpenLSMWorkerIntent: AppIntent {
    static var title: LocalizedStringResource = "Open LSM Worker"
    static var description = IntentDescription("Open the LSM Worker app in the foreground.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct LSMWorkerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LSMWorkerCheckInIntent(),
            phrases: [
                "Check in \(.applicationName)",
                "Wake \(.applicationName)",
            ],
            shortTitle: "Check In Worker",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: LSMWorkerStatusIntent(),
            phrases: [
                "Status of \(.applicationName)",
                "Is \(.applicationName) online",
            ],
            shortTitle: "Worker Status",
            systemImageName: "network"
        )
        AppShortcut(
            intent: OpenLSMWorkerIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Worker",
            systemImageName: "iphone"
        )
    }
}
