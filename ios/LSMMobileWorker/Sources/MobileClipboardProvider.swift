import Combine
import Foundation
import UIKit

@MainActor
final class MobileClipboardProvider: ObservableObject {
    enum ClipboardError: LocalizedError {
        case foregroundRequired
        case readNotEnabled
        case tooLarge
        case noText

        var errorDescription: String? {
            switch self {
            case .foregroundRequired: return "Clipboard read requires LSM Worker to be in the foreground."
            case .readNotEnabled: return "Remote clipboard read is disabled. Enable it locally in LSM Worker first."
            case .tooLarge: return "Clipboard text exceeds the 64 KiB mobile clipboard limit."
            case .noText: return "The clipboard does not currently contain text."
            }
        }
    }

    static let shared = MobileClipboardProvider()
    static let readEnabledKey = "mobile.clipboard.remote_read_enabled"
    private let maxBytes = 64 * 1024

    @Published var remoteReadEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteReadEnabled, forKey: Self.readEnabledKey) }
    }

    private init() {
        remoteReadEnabled = UserDefaults.standard.bool(forKey: Self.readEnabledKey)
    }

    func status() -> [String: Any] {
        // Status must not touch UIPasteboard itself: even presence checks can enter
        // iOS paste privacy flows. Only clipboard_read accesses pasteboard content,
        // and that action additionally requires explicit local opt-in + foreground.
        [
            "remote_read_enabled": remoteReadEnabled,
            "app_state": appStateName(UIApplication.shared.applicationState),
        ]
    }

    func write(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let text = arguments["text"] as? String else {
            throw MobileActionExecutor.ActionError.missingArgument("text")
        }
        let bytes = Data(text.utf8).count
        guard bytes <= maxBytes else { throw ClipboardError.tooLarge }
        UIPasteboard.general.string = text
        return ["written": true, "bytes": bytes]
    }

    func read() throws -> [String: Any] {
        guard UIApplication.shared.applicationState == .active else {
            throw ClipboardError.foregroundRequired
        }
        guard remoteReadEnabled else { throw ClipboardError.readNotEnabled }
        guard let text = UIPasteboard.general.string else { throw ClipboardError.noText }
        let bytes = Data(text.utf8).count
        guard bytes <= maxBytes else { throw ClipboardError.tooLarge }
        return ["text": text, "bytes": bytes]
    }

    private func appStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
