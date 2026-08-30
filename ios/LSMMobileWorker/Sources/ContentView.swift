import SwiftUI

struct ContentView: View {
    @ObservedObject var model: WorkerViewModel

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
                    capability("Mobile network probe", detail: "Path status and bounded public HTTP/HTTPS probes")
                    capability("Background wake", detail: "APNs + BGAppRefresh best effort; iOS still controls execution")
                    capability("Shortcuts", detail: "Check In, Status, and Open LSM Worker App Intents")
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
