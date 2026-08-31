import Combine
import Foundation

struct DashboardMachine: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let status: String
    let platform: String
    let detail: String
}

struct DashboardJob: Identifiable, Equatable {
    let id: String
    let machine: String
    let name: String
    let status: String
    let updatedAt: String?
}

@MainActor
final class ControllerDashboardStore: ObservableObject {
    static let shared = ControllerDashboardStore()

    @Published private(set) var machines: [DashboardMachine] = []
    @Published private(set) var jobs: [DashboardJob] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var loading = false

    private init() {}

    func beginLoading() {
        loading = true
        error = nil
    }

    func apply(_ payload: [String: Any]) {
        let machineRows = payload["machines"] as? [[String: Any]] ?? []
        machines = machineRows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let status = (row["status"] as? String) ?? "unknown"
            let platform = (row["platform"] as? String) ?? "unknown"
            var pieces: [String] = []
            if let battery = (row["battery_percent"] as? NSNumber)?.intValue { pieces.append("battery \(battery)%") }
            if let cpu = (row["cpu_percent"] as? NSNumber)?.doubleValue { pieces.append(String(format: "CPU %.0f%%", cpu)) }
            if let memory = (row["memory_percent"] as? NSNumber)?.doubleValue { pieces.append(String(format: "RAM %.0f%%", memory)) }
            return DashboardMachine(name: name, status: status, platform: platform, detail: pieces.joined(separator: " · "))
        }
        let jobRows = payload["jobs"] as? [[String: Any]] ?? []
        jobs = jobRows.compactMap { row in
            guard let id = row["job_id"] as? String else { return nil }
            return DashboardJob(
                id: "\((row["machine"] as? String) ?? "controller"):\(id)",
                machine: (row["machine"] as? String) ?? "controller",
                name: (row["name"] as? String) ?? id,
                status: (row["status"] as? String) ?? "unknown",
                updatedAt: row["updated_at"] as? String
            )
        }
        updatedAt = Date()
        loading = false
        error = nil
    }

    func fail(_ message: String) {
        loading = false
        error = message
    }
}
