import Combine
import Foundation
import UserNotifications

struct MobileControllerEvent: Identifiable, Codable, Equatable {
    let id: String
    let type: String
    let title: String
    let body: String
    let createdAt: Date
}

@MainActor
final class MobileEventStore: ObservableObject {
    static let shared = MobileEventStore()
    private static let key = "mobile.controller.events.v1"
    private static let retentionInterval: TimeInterval = 24 * 60 * 60
    private let maxItems = 100

    @Published private(set) var items: [MobileControllerEvent] = []

    private init() { load() }

    func process(_ rows: [[String: Any]]) async -> [String] {
        var ack: [String] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            ack.append(id)
            if items.contains(where: { $0.id == id }) { continue }
            let type = (row["type"] as? String) ?? "event"
            let title = (row["title"] as? String) ?? "LSM"
            let body = (row["body"] as? String) ?? "Controller event"
            let createdAt: Date
            if let seconds = (row["created_at"] as? NSNumber)?.doubleValue {
                createdAt = Date(timeIntervalSince1970: seconds)
            } else {
                createdAt = Date()
            }

            if type == "mobile_delivery", let data = row["data"] as? [String: Any] {
                _ = try? MobileInboxStore.shared.receive(data, id: id)
            }

            items.insert(MobileControllerEvent(id: id, type: type, title: title, body: body, createdAt: createdAt), at: 0)
            if items.count > maxItems { items.removeLast(items.count - maxItems) }
            save()
            await postLocalNotification(id: id, title: title, body: body)
        }
        return ack
    }

    func clear() {
        items = []
        save()
    }

    @discardableResult
    func pruneExpired(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        let originalCount = items.count
        items.removeAll { $0.createdAt < cutoff }
        let removed = originalCount - items.count
        if removed > 0 { save() }
        return removed
    }

    private func postLocalNotification(id: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "lsm-event-\(id)", content: content, trigger: nil))
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([MobileControllerEvent].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)
        let retained = decoded.filter { $0.createdAt >= cutoff }
        items = Array(retained.prefix(maxItems))
        if retained.count != decoded.count || items.count != decoded.count { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
