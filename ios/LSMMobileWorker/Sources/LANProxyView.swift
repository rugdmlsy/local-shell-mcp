import SwiftUI
import UIKit

struct LANProxyDiscoveryView: View {
    @ObservedObject private var store = LANProxyDiscoveryStore.shared
    @State private var copied = ""

    var body: some View {
        List {
            Section("Wi-Fi Network") {
                if let subnet = store.subnet {
                    LabeledContent("iPhone", value: subnet.address)
                    LabeledContent("Network", value: "\(subnet.network)/\(subnet.prefixLength)")
                    LabeledContent("Scan scope", value: subnet.scopeLabel)
                    if subnet.prefixLength < 24 {
                        Text("The Wi-Fi subnet is larger than /24. Automatic discovery is deliberately limited to the /24 containing this iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No usable Wi-Fi IPv4 network detected. Connect this iPhone to the same Wi-Fi/LAN as the proxy host.")
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Network") { store.refreshNetwork() }
            }

            Section("Discovery") {
                HStack {
                    if store.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(store.status)
                    Spacer()
                }

                if store.isScanning {
                    LabeledContent("Hosts attempted", value: String(store.attemptedHosts))
                    if let port = store.currentPort {
                        LabeledContent("Current port", value: String(port))
                    }
                    Button("Cancel Scan", role: .destructive) { store.cancel() }
                } else {
                    Button {
                        store.scan()
                    } label: {
                        Label("Scan for LAN Proxy", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(store.subnet == nil)
                }

                Text("Checks common Clash/Mihomo and proxy ports in stages. A result is accepted only after it can create an outbound tunnel through HTTP CONNECT or SOCKS5; an open TCP port alone is not enough.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let endpoint = store.endpoint {
                Section("Saved Proxy") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(endpoint.host):\(endpoint.port)")
                                .font(.headline)
                            Text(endpoint.protocolLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    LabeledContent("Tunnel latency", value: String(format: "%.0f ms", endpoint.latencyMS))
                    LabeledContent("Verified", value: endpoint.verifiedAt.formatted(date: .abbreviated, time: .standard))

                    if let url = endpoint.httpURL {
                        Button {
                            copy(url, label: "HTTP proxy copied")
                        } label: {
                            Label(copied == "HTTP proxy copied" ? copied : "Copy HTTP Proxy URL", systemImage: "doc.on.doc")
                        }
                    }
                    if let url = endpoint.socksURL {
                        Button {
                            copy(url, label: "SOCKS5 proxy copied")
                        } label: {
                            Label(copied == "SOCKS5 proxy copied" ? copied : "Copy SOCKS5 Proxy URL", systemImage: "doc.on.doc")
                        }
                    }

                    Button("Recheck") { store.recheck() }
                    Button("Forget Proxy", role: .destructive) { store.clearSavedProxy() }
                }
            }

            Section("Manual Endpoint") {
                TextField("Host or IPv4 address", text: $store.manualHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                TextField("Port", text: $store.manualPort)
                    .keyboardType(.numberPad)
                Button("Verify & Save") { store.verifyManual() }
                    .disabled(store.isScanning)
            }

            Section("About") {
                Text("This is a local utility inside LSM Worker. Discovery, verification, and saved proxy state do not use the LSM controller and are not exposed as remote worker actions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Saving a proxy here does not change the iPhone system-wide Wi-Fi proxy. The current Personal Team build has no Network Extension entitlement; use the copied endpoint in a client that accepts HTTP/SOCKS5 proxy settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("LAN Proxy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refreshNetwork() }
        .onDisappear { store.cancel() }
    }

    private func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        copied = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copied == label { copied = "" }
        }
    }
}
