import Foundation
import SwiftUI
import UIKit

struct ApprovalPromptRequest: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let details: String
    let riskLevel: String
    let expiresAt: Date
}

struct ApprovalPromptDecision {
    let requestID: String
    let approved: Bool
    let respondedAt: Date
}

@MainActor
final class ApprovalPromptCoordinator: ObservableObject {
    enum ApprovalError: LocalizedError {
        case foregroundRequired
        case alreadyPending
        case timedOut
        case cancelled
        case invalidRiskLevel

        var errorDescription: String? {
            switch self {
            case .foregroundRequired:
                return "Approval prompts require LSM Worker to be in the foreground."
            case .alreadyPending:
                return "Another approval request is already pending on this device."
            case .timedOut:
                return "The mobile approval request expired without a response."
            case .cancelled:
                return "The mobile approval request was cancelled."
            case .invalidRiskLevel:
                return "risk_level must be one of: low, medium, high, critical."
            }
        }
    }

    static let shared = ApprovalPromptCoordinator()

    @Published private(set) var request: ApprovalPromptRequest?

    private var continuation: CheckedContinuation<ApprovalPromptDecision, Error>?
    private var timeoutTask: Task<Void, Never>?

    private init() {}

    func prompt(_ arguments: [String: Any]) async throws -> ApprovalPromptDecision {
        guard UIApplication.shared.applicationState == .active else {
            throw ApprovalError.foregroundRequired
        }
        guard continuation == nil else {
            throw ApprovalError.alreadyPending
        }

        let title = boundedText(arguments["title"] as? String, fallback: "LSM approval required", limit: 120)
        let summary = boundedText(arguments["summary"] as? String, fallback: "A remote action is waiting for your approval.", limit: 600)
        let details = boundedText(arguments["details"] as? String, fallback: "", limit: 4_000)
        let riskLevel = ((arguments["risk_level"] as? String) ?? "medium").lowercased()
        guard ["low", "medium", "high", "critical"].contains(riskLevel) else {
            throw ApprovalError.invalidRiskLevel
        }
        let timeoutSeconds = min(max((arguments["timeout_s"] as? NSNumber)?.doubleValue ?? 120, 10), 300)
        let requestID = boundedText(arguments["request_id"] as? String, fallback: UUID().uuidString, limit: 160)
        let item = ApprovalPromptRequest(
            id: requestID,
            title: title,
            summary: summary,
            details: details,
            riskLevel: riskLevel,
            expiresAt: Date().addingTimeInterval(timeoutSeconds)
        )
        request = item

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    await self?.finish(error: ApprovalError.timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(error: ApprovalError.cancelled)
            }
        }
    }

    func approve() {
        finish(approved: true)
    }

    func reject() {
        finish(approved: false)
    }

    private func finish(approved: Bool) {
        guard let request, let continuation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        self.request = nil
        continuation.resume(returning: ApprovalPromptDecision(
            requestID: request.id,
            approved: approved,
            respondedAt: Date()
        ))
    }

    private func finish(error: Error) {
        guard let continuation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        request = nil
        continuation.resume(throwing: error)
    }

    private func boundedText(_ value: String?, fallback: String, limit: Int) -> String {
        let text = (value ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return fallback }
        return String(text.prefix(limit))
    }
}

struct ApprovalPromptView: View {
    let request: ApprovalPromptRequest
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Risk", value: request.riskLevel.uppercased())
                    Text(request.summary)
                }
                if !request.details.isEmpty {
                    Section("Details") {
                        Text(request.details)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button("Approve") { onApprove() }
                        .buttonStyle(.borderedProminent)
                    Button("Reject", role: .destructive) { onReject() }
                }
                Section {
                    Text("This request came from your paired LSM controller. LSM Worker will return your decision to the waiting action; it does not execute the requested action itself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}
