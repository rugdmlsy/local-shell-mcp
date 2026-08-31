import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var approvals = ApprovalPromptCoordinator.shared
    @ObservedObject private var scanner = CodeScannerCoordinator.shared
    @ObservedObject private var inbox = MobileInboxStore.shared
    @ObservedObject private var events = MobileEventStore.shared
    @State private var showSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                WorkerHomeView(
                    model: model,
                    scanner: scanner,
                    showSettings: $showSettings
                )
            }
            .tabItem {
                Label("Worker", systemImage: "antenna.radiowaves.left.and.right")
            }

            NavigationStack {
                MobileDashboardView(model: model)
            }
            .tabItem {
                Label("Machines", systemImage: "desktopcomputer")
            }

            NavigationStack {
                MobileInboxView()
            }
            .tabItem {
                Label("Inbox", systemImage: "tray.full")
            }
            .badge(inbox.items.filter { !$0.read }.count)

            NavigationStack {
                ControllerEventsView()
            }
            .tabItem {
                Label("Events", systemImage: "bell.badge")
            }
            .badge(events.items.count)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                WorkerSettingsView(model: model)
            }
        }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "mobile.intent.open_scanner") {
                UserDefaults.standard.removeObject(forKey: "mobile.intent.open_scanner")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    scanner.startLocalScan()
                }
            }
        }
        .sheet(isPresented: $scanner.presenting) {
            CodeScannerSheet(
                onScan: { value, type in scanner.record(value: value, type: type) },
                onCancel: { scanner.cancel() }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(
            get: { approvals.request != nil },
            set: { presented in
                if !presented, approvals.request != nil { approvals.reject() }
            }
        )) {
            if let request = approvals.request {
                ApprovalPromptView(
                    request: request,
                    onApprove: { approvals.approve() },
                    onReject: { approvals.reject() }
                )
            }
        }
    }
}

private struct WorkerHomeView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject var scanner: CodeScannerCoordinator
    @Binding var showSettings: Bool

    var body: some View {
        List {
            Section("Connection") {
                HStack(spacing: 12) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)

                    Text(model.status)
                        .fontWeight(.medium)

                    Spacer()

                    Button(model.connected ? "Disconnect" : "Connect") {
                        if model.connected {
                            model.disconnect()
                        } else {
                            model.connect()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.connected && !canConnect)
                }
            }

            Section {
                DisclosureGroup {
                    Button {
                        scanner.startLocalScan()
                    } label: {
                        Label("Scan QR / Barcode", systemImage: "qrcode.viewfinder")
                    }

                    if let scan = scanner.lastScan {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Last scan")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(scan.value)
                                .font(.footnote)
                                .lineLimit(3)
                        }
                    }

                    if !scanner.message.isEmpty {
                        Text(scanner.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("Code scanning is always started locally. Remote actions can only read the last scan result.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .navigationTitle("LSM Worker")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private var canConnect: Bool {
        !model.server.isEmpty
            && !model.workerName.isEmpty
            && (model.paired || !model.invite.isEmpty)
    }

    private var statusColor: Color {
        if model.connected { return .green }
        switch model.status.lowercased() {
        case "connecting", "reconnecting": return .yellow
        case "error": return .red
        default: return .secondary
        }
    }
}

private struct WorkerSettingsView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var externalFiles = ExternalFileAccessManager.shared
    @ObservedObject private var clipboard = MobileClipboardProvider.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @State private var showDirectoryPicker = false
    @State private var fileAccessMessage = ""

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Controller", text: $model.server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(model.paired)

                TextField("Worker name", text: $model.workerName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(model.paired)

                if !model.paired {
                    SecureField("Invite code", text: $model.invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if model.paired {
                    Button("Unpair Device", role: .destructive) {
                        model.unpair()
                    }
                }
            }

            Section("Permissions") {
                Button("Allow Notifications") {
                    Task { await model.requestNotificationPermission() }
                }
                Button("Allow Location While Using App") {
                    model.requestLocationPermission()
                }
                Button("Allow Camera") {
                    Task { await model.requestCameraPermission() }
                }
                Button("Allow Photo Library") {
                    Task { await model.requestPhotoPermission() }
                }
                Text("Remote commands never trigger a new iOS privacy prompt. Grant permissions here first, then LSM may use only the capabilities you enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Files & Clipboard") {
                Button("Grant Access to File") { showFilePicker = true }
                Button("Grant Access to Folder") { showDirectoryPicker = true }

                if externalFiles.bookmarks.isEmpty {
                    Text("No external Files access has been granted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(externalFiles.bookmarks) { bookmark in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(bookmark.name)
                                Text(bookmark.isDirectory ? "Folder" : "File")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                externalFiles.remove(id: bookmark.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }

                Toggle("Allow Remote Clipboard Read", isOn: $clipboard.remoteReadEnabled)
                Text("File/folder selection can only be initiated here. Remote actions may use only bookmarks you granted. Clipboard writes are allowed; reads require this switch and the app foreground, and iOS may still show its paste privacy UI.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !fileAccessMessage.isEmpty {
                    Text(fileAccessMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Mobile Capabilities") {
                capability("Device information", detail: "Model, iOS version, CPU/memory summary")
                capability("Battery", detail: "Charge state, percentage, Low Power Mode")
                capability("Notifications", detail: "Post a local notification after permission")
                capability("Location", detail: "One-shot location while the app is permitted to access it")
                capability("Open URL", detail: "Foreground only")
                capability("Sandbox files", detail: "Documents/LSM, visible in Files")
                capability("Binary transfer", detail: "Stream sandbox files/images through LSM transfer tickets")
                capability("Camera", detail: "Foreground still capture after explicit camera permission")
                capability("Photos", detail: "List/export permitted Photo Library assets into the sandbox")
                capability("Mobile network probe", detail: "Path history plus bounded public DNS/TCP/TLS/HTTP probes")
                capability("External Files", detail: "Import/export only through files or folders explicitly selected in this app")
                capability("Clipboard", detail: "Remote write; foreground read only after explicit local opt-in")
                capability("Device status", detail: "Storage, thermal state, display, locale, uptime, battery and power state")
                capability("Motion sensors", detail: "Bounded foreground accelerometer, gyro, magnetometer and attitude snapshot")
                capability("QR / barcode scanner", detail: "Local-user initiated camera scan; remote side can only read the last scan")
                capability("Mobile inbox", detail: "Receive text, URL and sandbox-file handoffs from LSM")
                capability("Controller dashboard", detail: "Read-only machine status and active-job overview")
                #if LSM_SHARE_EXTENSION
                capability("Share Extension", detail: "Send files, images, PDFs, URLs, or text from the iOS share sheet into Documents/LSM/Shared")
                #endif
                capability("Background wake", detail: "APNs + BGAppRefresh best effort; iOS still controls execution")
                capability("Shortcuts", detail: "Check In, Status, Open, Inbox, Controller and Scanner App Intents")
                capability("Approval terminal", detail: "Foreground approve/reject prompts for controller actions; the phone returns only the decision")
            }

            Section("Runtime") {
                LabeledContent("Last action", value: model.lastAction)
                LabeledContent("Worker protocol", value: "LSM poll v2")
                LabeledContent("Background model", value: "APNs + BGAppRefresh")
                Text("iOS may still suspend this app or throttle silent pushes. Background wake is best effort and bounded; the worker automatically reconnects when the app becomes active again and is not a 24/7 daemon like a Mac or Linux worker.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .fileImporter(
            isPresented: $showDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            try externalFiles.add(url: url)
            fileAccessMessage = "Granted access to \(url.lastPathComponent)."
        } catch {
            fileAccessMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func capability(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
