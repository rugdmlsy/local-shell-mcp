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

    var body: some View {
        List {
            if events.items.isEmpty {
                Text("No controller notifications have been received.")
                    .foregroundStyle(.secondary)
            }
            ForEach(events.items) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).fontWeight(.semibold)
                    Text(event.body).font(.footnote)
                    Text("\(event.type) · \(event.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Controller Events")
        .toolbar {
            if !events.items.isEmpty {
                Button("Clear", role: .destructive) { events.clear() }
            }
        }
    }
}
