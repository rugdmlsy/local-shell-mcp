import SwiftUI

struct MobileDashboardView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var dashboard = ControllerDashboardStore.shared

    var body: some View {
        List {
            Section("Machines") {
                if dashboard.machines.isEmpty {
                    Text(dashboard.loading ? "Loading…" : "No machine status loaded.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dashboard.machines) { machine in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(machine.name)
                            Spacer()
                            Text(machine.status)
                                .foregroundStyle(machine.status == "online" ? .green : .secondary)
                        }
                        Text([machine.platform, machine.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Active jobs") {
                if dashboard.jobs.isEmpty {
                    Text(dashboard.loading ? "Loading…" : "No active jobs reported.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dashboard.jobs) { job in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.name)
                        Text("\(job.machine) · \(job.status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = dashboard.error {
                Section("Error") { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("LSM Controller")
        .toolbar {
            Button("Refresh") { Task { await model.refreshDashboard() } }
        }
        .task { await model.refreshDashboard() }
        .refreshable { await model.refreshDashboard() }
    }
}

struct MobileInboxView: View {
    @ObservedObject private var inbox = MobileInboxStore.shared

    var body: some View {
        List {
            if inbox.items.isEmpty {
                Text("No items have been sent to this iPhone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(inbox.items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.title).fontWeight(item.read ? .regular : .semibold)
                        Spacer()
                        Text(item.kind.uppercased()).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let text = item.text { Text(text).font(.footnote).lineLimit(5) }
                    if let url = item.url { Text(url).font(.caption).foregroundStyle(.blue).lineLimit(2) }
                    if let path = item.path { Text(path).font(.caption).foregroundStyle(.secondary) }
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { inbox.markRead(item.id) }
            }
        }
        .navigationTitle("LSM Inbox")
        .toolbar {
            if !inbox.items.isEmpty {
                Button("Clear", role: .destructive) { inbox.clear() }
            }
        }
    }
}

struct ControllerEventsView: View {
    @ObservedObject private var events = MobileEventStore.shared

    private struct EventPresentation {
        let label: String
        let tint: Color
        let badgeForeground: Color
        let cardBackground: Color
    }

    var body: some View {
        List {
            if events.items.isEmpty {
                Text("No controller notifications have been received.")
                    .foregroundStyle(.secondary)
            }
            ForEach(events.items) { event in
                eventCard(event)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Controller Events")
        .toolbar {
            if !events.items.isEmpty {
                Button("Clear", role: .destructive) { events.clear() }
            }
        }
    }

    @ViewBuilder
    private func eventCard(_ event: MobileControllerEvent) -> some View {
        let presentation = presentation(for: event)
        let sessionDescription = sessionDescription(for: event)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.title)
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                if let presentation {
                    Text(presentation.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(presentation.badgeForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(presentation.tint.opacity(0.22), in: Capsule())
                }
            }

            if let sessionDescription {
                Text(sessionDescription.session)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))

                Text(sessionDescription.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(event.body)
                    .font(.footnote)
            }

            Text("\(event.type) · \(event.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            presentation?.cardBackground ?? Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((presentation?.tint ?? Color.secondary).opacity(0.16), lineWidth: 0.75)
        }
    }

    private func presentation(for event: MobileControllerEvent) -> EventPresentation? {
        let body = event.body.lowercased()

        if event.type == "job_completed" {
            if body.hasPrefix("succeeded") {
                return EventPresentation(
                    label: "Succeeded",
                    tint: .green,
                    badgeForeground: .green,
                    cardBackground: Color.green.opacity(0.10)
                )
            }
            if body.hasPrefix("failed") || body.hasPrefix("lost") {
                return EventPresentation(
                    label: "Failed",
                    tint: .red,
                    badgeForeground: .red,
                    cardBackground: Color.red.opacity(0.08)
                )
            }
            if body.hasPrefix("stopped") {
                return EventPresentation(
                    label: "Stopped",
                    tint: .secondary,
                    badgeForeground: .secondary,
                    cardBackground: Color.secondary.opacity(0.08)
                )
            }
            return EventPresentation(
                label: "Completed",
                tint: .green,
                badgeForeground: .green,
                cardBackground: Color.green.opacity(0.08)
            )
        }

        if event.type == "agent_interrupted_or_expired" {
            return EventPresentation(
                label: "Execution paused",
                tint: .yellow,
                badgeForeground: .primary,
                cardBackground: Color.yellow.opacity(0.11)
            )
        }

        if event.type == "agent_continuation_exhausted" {
            return EventPresentation(
                label: "Needs attention",
                tint: .orange,
                badgeForeground: .orange,
                cardBackground: Color.orange.opacity(0.09)
            )
        }

        return nil
    }

    private func sessionDescription(for event: MobileControllerEvent) -> (session: String, message: String)? {
        guard event.type == "agent_interrupted_or_expired" || event.type == "agent_continuation_exhausted" else {
            return nil
        }

        let markers = [": no agent activity", ": automatic continuation"]
        for marker in markers {
            guard let range = event.body.range(of: marker, options: .caseInsensitive) else { continue }
            let session = event.body[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let messageStart = event.body.index(after: range.lowerBound)
            let message = event.body[messageStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !session.isEmpty, !message.isEmpty else { continue }
            return (session, message)
        }
        return nil
    }
}
