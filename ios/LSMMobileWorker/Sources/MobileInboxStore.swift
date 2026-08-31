import Combine
import Foundation

struct MobileInboxItem: Identifiable, Codable, Equatable {
    let id: String
    let kind: String
    let title: String
    let text: String?
    let url: String?
    let path: String?
    let createdAt: Date
    var read: Bool
}

@MainActor
final class MobileInboxStore: ObservableObject {
    enum InboxError: LocalizedError {
        case unsupportedKind
        case missingPayload
        case unsafeURL
        case missingFile
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedKind: return "send_to_mobile kind must be text, url, or file."
            case .missingPayload: return "The mobile inbox payload is incomplete."
            case .unsafeURL: return "Only HTTP and HTTPS URLs are accepted by the mobile inbox."
            case .missingFile: return "The referenced sandbox file does not exist."
            case .tooLarge: return "The mobile inbox text exceeds 64 KiB."
            }
        }
    }

    static let shared = MobileInboxStore()
    private static let key = "mobile.inbox.items.v1"
    private let maxItems = 100
    private let maxTextBytes = 64 * 1024

    @Published private(set) var items: [MobileInboxItem] = []

    private init() {
        load()
    }

    func receive(_ arguments: [String: Any], id explicitID: String? = nil) throws -> MobileInboxItem {
        let kind = ((arguments["kind"] as? String) ?? "text").lowercased()
        let title = ((arguments["title"] as? String) ?? "LSM").prefix(200)
        let itemID = explicitID ?? ((arguments["id"] as? String) ?? UUID().uuidString)
        if let existing = items.first(where: { $0.id == itemID }) { return existing }

        let item: MobileInboxItem
        switch kind {
        case "text":
            guard let text = arguments["text"] as? String else { throw InboxError.missingPayload }
            guard Data(text.utf8).count <= maxTextBytes else { throw InboxError.tooLarge }
            item = MobileInboxItem(id: itemID, kind: kind, title: String(title), text: text, url: nil, path: nil, createdAt: Date(), read: false)
        case "url":
            guard let raw = arguments["url"] as? String,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                throw InboxError.unsafeURL
            }
            item = MobileInboxItem(id: itemID, kind: kind, title: String(title), text: arguments["text"] as? String, url: raw, path: nil, createdAt: Date(), read: false)
        case "file":
            guard let path = arguments["path"] as? String else { throw InboxError.missingPayload }
            let resolved = try MobileFileStore.resolve(path)
            guard FileManager.default.fileExists(atPath: resolved.path) else { throw InboxError.missingFile }
            item = MobileInboxItem(id: itemID, kind: kind, title: String(title), text: arguments["text"] as? String, url: nil, path: MobileFileStore.relativePath(resolved), createdAt: Date(), read: false)
        default:
            throw InboxError.unsupportedKind
        }
        items.insert(item, at: 0)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        save()
        return item
    }

    func listInfo() -> [String: Any] {
        [
            "count": items.count,
            "unread_count": items.filter { !$0.read }.count,
            "items": items.prefix(50).map { item in
                var row: [String: Any] = [
                    "id": item.id,
                    "kind": item.kind,
                    "title": item.title,
                    "created_at": ISO8601DateFormatter().string(from: item.createdAt),
                    "read": item.read,
                ]
                if let text = item.text { row["text"] = text }
                if let url = item.url { row["url"] = url }
                if let path = item.path { row["path"] = path }
                return row
            },
        ]
    }

    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].read = true
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([MobileInboxItem].self, from: data) else { return }
        items = Array(decoded.prefix(maxItems))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
