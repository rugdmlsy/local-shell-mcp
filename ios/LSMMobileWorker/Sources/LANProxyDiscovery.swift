import Combine
import Darwin
import Foundation
import Network

struct LANProxyEndpoint: Codable, Hashable, Identifiable {
    let host: String
    let port: UInt16
    let supportsHTTP: Bool
    let supportsSOCKS5: Bool
    let latencyMS: Double
    let verifiedAt: Date

    var id: String { "\(host):\(port)" }

    var protocolLabel: String {
        switch (supportsHTTP, supportsSOCKS5) {
        case (true, true): return "HTTP + SOCKS5"
        case (true, false): return "HTTP"
        case (false, true): return "SOCKS5"
        default: return "Unknown"
        }
    }

    var httpURL: String? {
        supportsHTTP ? "http://\(host):\(port)" : nil
    }

    var socksURL: String? {
        supportsSOCKS5 ? "socks5://\(host):\(port)" : nil
    }
}

struct LANProxySubnet: Equatable {
    let interfaceName: String
    let address: String
    let network: String
    let prefixLength: Int
    let scanNetwork: String
    let scanPrefixLength: Int
    let hosts: [String]

    var scopeLabel: String { "\(scanNetwork)/\(scanPrefixLength)" }

    static func current() -> LANProxySubnet? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }

        struct Candidate {
            let name: String
            let address: UInt32
            let mask: UInt32
            let score: Int
        }

        var candidates: [Candidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor?.pointee {
            defer { cursor = item.ifa_next }
            guard let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(item.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: item.ifa_name)
            guard !name.hasPrefix("pdp_ip"), !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else {
                continue
            }
            guard let maskAddr = item.ifa_netmask else { continue }
            let sin = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
            let maskSin = UnsafeRawPointer(maskAddr).assumingMemoryBound(to: sockaddr_in.self).pointee
            let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
            let mask = UInt32(bigEndian: maskSin.sin_addr.s_addr)
            let octet = UInt8((ip >> 24) & 0xff)
            guard octet != 127, octet != 169 else { continue }

            let score: Int
            if name == "en0" { score = 100 }
            else if name.hasPrefix("en") { score = 80 }
            else { score = 20 }
            candidates.append(Candidate(name: name, address: ip, mask: mask, score: score))
        }

        guard let selected = candidates.sorted(by: { $0.score > $1.score }).first else { return nil }
        let prefix = selected.mask.nonzeroBitCount
        guard prefix >= 16 && prefix <= 30 else { return nil }

        let actualNetwork = selected.address & selected.mask
        // Keep an automatic discovery bounded to at most one /24. Large campus/home
        // subnets should not turn a local convenience feature into a broad scanner.
        let scanPrefix = max(prefix, 24)
        let scanMask: UInt32 = scanPrefix == 0 ? 0 : UInt32.max << UInt32(32 - scanPrefix)
        let scanNetwork = selected.address & scanMask
        let hostCount = min((1 << (32 - scanPrefix)) - 2, 254)
        guard hostCount > 0 else { return nil }

        var hosts: [String] = []
        hosts.reserveCapacity(hostCount)
        for offset in 1...hostCount {
            let value = scanNetwork &+ UInt32(offset)
            if value != selected.address { hosts.append(ipv4String(value)) }
        }

        return LANProxySubnet(
            interfaceName: selected.name,
            address: ipv4String(selected.address),
            network: ipv4String(actualNetwork),
            prefixLength: prefix,
            scanNetwork: ipv4String(scanNetwork),
            scanPrefixLength: scanPrefix,
            hosts: hosts
        )
    }

    private static func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xff).\((value >> 16) & 0xff).\((value >> 8) & 0xff).\(value & 0xff)"
    }
}

private final class LANProxyProtocolProbe: @unchecked Sendable {
    enum Kind { case socks5, http }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    private let queue = DispatchQueue(label: "com.xycdev.lsmmobileworker.lan-proxy-probe", attributes: .concurrent)
    private let targetHost = "cp.cloudflare.com"

    func probe(host: String, port: UInt16, kind: Kind, timeout: TimeInterval) async -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = ContinuousClock.now

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let gate = CompletionGate()

                @Sendable func finish(_ result: Double?) {
                    guard gate.claim() else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: result)
                }

                @Sendable func receiveHTTP(_ accumulated: Data = Data()) {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                        if error != nil { finish(nil); return }
                        var buffer = accumulated
                        if let data { buffer.append(data) }
                        if buffer.count > 4096 { finish(nil); return }
                        if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                            let statusLine = text.split(separator: "\n", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let pieces = statusLine.split(separator: " ")
                            guard pieces.count >= 2, Int(pieces[1]) == 200 else { finish(nil); return }
                            finish(start.duration(to: .now).milliseconds)
                            return
                        }
                        if isComplete { finish(nil); return }
                        receiveHTTP(buffer)
                    }
                }

                @Sendable func sendHTTPConnect() {
                    let text = "CONNECT \(targetHost):443 HTTP/1.1\r\nHost: \(targetHost):443\r\nProxy-Connection: keep-alive\r\n\r\n"
                    connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                        if error != nil { finish(nil); return }
                        receiveHTTP()
                    })
                }

                @Sendable func receiveSOCKSConnectReply() {
                    connection.receive(minimumIncompleteLength: 5, maximumLength: 512) { data, _, _, error in
                        guard error == nil, let data, data.count >= 2 else { finish(nil); return }
                        let bytes = [UInt8](data)
                        guard bytes[0] == 0x05, bytes[1] == 0x00 else { finish(nil); return }
                        finish(start.duration(to: .now).milliseconds)
                    }
                }

                @Sendable func sendSOCKSConnect() {
                    let domain = Array(targetHost.utf8)
                    guard domain.count <= 255 else { finish(nil); return }
                    var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(domain.count)]
                    request.append(contentsOf: domain)
                    request.append(contentsOf: [0x01, 0xbb]) // 443
                    connection.send(content: Data(request), completion: .contentProcessed { error in
                        if error != nil { finish(nil); return }
                        receiveSOCKSConnectReply()
                    })
                }

                @Sendable func receiveSOCKSGreeting() {
                    connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                        guard error == nil, let data, data.count == 2 else { finish(nil); return }
                        let bytes = [UInt8](data)
                        guard bytes[0] == 0x05, bytes[1] == 0x00 else { finish(nil); return }
                        sendSOCKSConnect()
                    }
                }

                @Sendable func sendSOCKSGreeting() {
                    connection.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { error in
                        if error != nil { finish(nil); return }
                        receiveSOCKSGreeting()
                    })
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        switch kind {
                        case .socks5: sendSOCKSGreeting()
                        case .http: sendHTTPConnect()
                        }
                    case .failed, .cancelled:
                        finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            }
        }, onCancel: {
            connection.cancel()
        })
    }
}

private final class LANLocalNetworkAccessProbe: @unchecked Sendable {
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    private let queue = DispatchQueue(label: "com.xycdev.lsmmobileworker.lan-access")

    func check(host: String, timeout: TimeInterval = 12) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: 1) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let gate = CompletionGate()

                @Sendable func finish(_ allowed: Bool) {
                    guard gate.claim() else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: allowed)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .preparing, .ready:
                        // Reaching preparation means local-network policy allowed this path;
                        // the destination itself does not need to accept the TCP connection.
                        finish(true)
                    case .waiting:
                        if case .localNetworkDenied? = connection.currentPath?.unsatisfiedReason {
                            // Keep the connection alive. If this is the first access, iOS is
                            // presenting the Local Network prompt and retries automatically
                            // after the user grants permission.
                            return
                        }
                    case .failed:
                        // A normal TCP failure without the policy-denied path still proves
                        // the app was allowed to attempt local-network traffic.
                        if case .localNetworkDenied? = connection.currentPath?.unsatisfiedReason {
                            return
                        }
                        finish(true)
                    case .cancelled:
                        finish(false)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            }
        }, onCancel: {
            connection.cancel()
        })
    }
}

@MainActor
final class LANProxyDiscoveryStore: ObservableObject {
    static let shared = LANProxyDiscoveryStore()

    @Published private(set) var subnet: LANProxySubnet?
    @Published private(set) var endpoint: LANProxyEndpoint?
    @Published private(set) var isScanning = false
    @Published private(set) var status = "Ready"
    @Published private(set) var attemptedHosts = 0
    @Published private(set) var currentPort: UInt16?
    @Published var manualHost = ""
    @Published var manualPort = "7890"

    private let probe = LANProxyProtocolProbe()
    private let localAccessProbe = LANLocalNetworkAccessProbe()
    private let defaults = UserDefaults.standard
    private let cacheKeyPrefix = "lan_proxy.endpoint."
    private let activeKey = "lan_proxy.active"
    private var scanTask: Task<Void, Never>?

    // Most Clash/Mihomo setups are found in the first two stages.
    private let commonPorts: [UInt16] = [7890, 7891, 7897, 1080, 10808, 8080, 8888, 8118]
    private let concurrency = 48
    private let probeTimeout: TimeInterval = 0.75

    private init() {
        refreshNetwork()
        endpoint = loadActiveEndpoint()
    }

    func refreshNetwork() {
        subnet = LANProxySubnet.current()
    }

    func scan() {
        cancel()
        refreshNetwork()
        scanTask = Task { [weak self] in
            await self?.runScan()
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            isScanning = false
            status = "Scan cancelled"
        }
    }

    func verifyManual() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let value = UInt16(manualPort) else {
            status = "Enter a valid host and port"
            return
        }
        cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            isScanning = true
            status = "Verifying \(host):\(value)…"
            let result = await verify(host: host, port: value, timeout: 2.0)
            if Task.isCancelled { return }
            isScanning = false
            if let result {
                save(result)
                status = "Proxy available"
            } else {
                status = "No usable HTTP/SOCKS5 proxy found at that endpoint"
            }
        }
    }

    func recheck() {
        guard let endpoint else { return }
        manualHost = endpoint.host
        manualPort = String(endpoint.port)
        verifyManual()
    }

    func clearSavedProxy() {
        if let subnet { defaults.removeObject(forKey: cacheKeyPrefix + subnet.scopeLabel) }
        defaults.removeObject(forKey: activeKey)
        endpoint = nil
        status = "Saved proxy cleared"
    }

    private func runScan() async {
        guard let subnet else {
            status = "Connect to Wi-Fi before scanning"
            isScanning = false
            return
        }
        isScanning = true
        attemptedHosts = 0
        currentPort = nil
        status = "Checking Local Network access…"

        guard let permissionTarget = subnet.hosts.first,
              await localAccessProbe.check(host: permissionTarget) else {
            guard !Task.isCancelled else { return }
            isScanning = false
            status = "Local Network access was not granted. Enable LSM Worker in Settings → Privacy & Security → Local Network, then scan again."
            return
        }
        guard !Task.isCancelled else { return }
        status = "Checking saved proxy…"

        if let cached = loadCachedEndpoint(for: subnet.scopeLabel),
           let verified = await verify(host: cached.host, port: cached.port, timeout: 1.2) {
            guard !Task.isCancelled else { return }
            save(verified)
            isScanning = false
            currentPort = nil
            status = "Saved proxy is available"
            return
        }

        let hosts = subnet.hosts
        for port in commonPorts {
            guard !Task.isCancelled else { return }
            currentPort = port
            status = "Scanning \(subnet.scopeLabel) on port \(port)…"

            for start in stride(from: 0, to: hosts.count, by: concurrency) {
                guard !Task.isCancelled else { return }
                let end = min(start + concurrency, hosts.count)
                let chunk = Array(hosts[start..<end])
                let found = await withTaskGroup(of: LANProxyEndpoint?.self, returning: LANProxyEndpoint?.self) { group in
                    for host in chunk {
                        group.addTask { [probe, probeTimeout] in
                            if Task.isCancelled { return nil }
                            if let socks = await probe.probe(host: host, port: port, kind: .socks5, timeout: probeTimeout) {
                                let http = await probe.probe(host: host, port: port, kind: .http, timeout: probeTimeout)
                                return LANProxyEndpoint(
                                    host: host,
                                    port: port,
                                    supportsHTTP: http != nil,
                                    supportsSOCKS5: true,
                                    latencyMS: min(socks, http ?? socks),
                                    verifiedAt: Date()
                                )
                            }
                            if let http = await probe.probe(host: host, port: port, kind: .http, timeout: probeTimeout) {
                                return LANProxyEndpoint(
                                    host: host,
                                    port: port,
                                    supportsHTTP: true,
                                    supportsSOCKS5: false,
                                    latencyMS: http,
                                    verifiedAt: Date()
                                )
                            }
                            return nil
                        }
                    }
                    var result: LANProxyEndpoint?
                    for await item in group {
                        if let item {
                            result = item
                            group.cancelAll()
                            break
                        }
                    }
                    return result
                }
                attemptedHosts += chunk.count
                if let found {
                    guard !Task.isCancelled else { return }
                    save(found)
                    isScanning = false
                    currentPort = nil
                    status = "Proxy found"
                    return
                }
            }
        }

        guard !Task.isCancelled else { return }
        isScanning = false
        currentPort = nil
        status = "No proxy found on common ports"
    }

    private func verify(host: String, port: UInt16, timeout: TimeInterval) async -> LANProxyEndpoint? {
        async let socks = probe.probe(host: host, port: port, kind: .socks5, timeout: timeout)
        async let http = probe.probe(host: host, port: port, kind: .http, timeout: timeout)
        let (socksLatency, httpLatency) = await (socks, http)
        guard socksLatency != nil || httpLatency != nil else { return nil }
        let latencies = [socksLatency, httpLatency].compactMap { $0 }
        return LANProxyEndpoint(
            host: host,
            port: port,
            supportsHTTP: httpLatency != nil,
            supportsSOCKS5: socksLatency != nil,
            latencyMS: latencies.min() ?? 0,
            verifiedAt: Date()
        )
    }

    private func save(_ value: LANProxyEndpoint) {
        endpoint = value
        if let subnet {
            persist(value, key: cacheKeyPrefix + subnet.scopeLabel)
        }
        persist(value, key: activeKey)
    }

    private func loadCachedEndpoint(for scope: String) -> LANProxyEndpoint? {
        load(key: cacheKeyPrefix + scope)
    }

    private func loadActiveEndpoint() -> LANProxyEndpoint? {
        load(key: activeKey)
    }

    private func persist(_ value: LANProxyEndpoint, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func load(key: String) -> LANProxyEndpoint? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LANProxyEndpoint.self, from: data)
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
