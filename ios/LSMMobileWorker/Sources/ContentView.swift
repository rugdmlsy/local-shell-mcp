import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var approvals = ApprovalPromptCoordinator.shared
    @ObservedObject private var externalFiles = ExternalFileAccessManager.shared
    @ObservedObject private var clipboard = MobileClipboardProvider.shared
    @State private var showFilePicker = false
    @State private var showDirectoryPicker = false
    @State private var fileAccessMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: model.status)
                    if !model.detail.isEmpty {
                        Text(model.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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

                    if model.connected {
                        Button("Disconnect") {
                            model.disconnect()
                        }
                    } else {
                        Button(model.paired ? "Connect" : "Pair & Connect") {
                            model.connect()
                        }
                        .disabled(model.server.isEmpty || model.workerName.isEmpty || (!model.paired && model.invite.isEmpty))
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

                Section("Files & clipboard") {
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

                Section("Mobile capabilities") {
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
                    #if LSM_SHARE_EXTENSION
                    capability("Share Extension", detail: "Send files, images, PDFs, URLs, or text from the iOS share sheet into Documents/LSM/Shared")
                    #endif
                    capability("Background wake", detail: "APNs + BGAppRefresh best effort; iOS still controls execution")
                    capability("Shortcuts", detail: "Check In, Status, and Open LSM Worker App Intents")
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
            .navigationTitle("LSM Worker")
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
