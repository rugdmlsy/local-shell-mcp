import Darwin
import Foundation
import Network
import Security

@MainActor
final class MobileNetworkProvider {
    enum NetworkError: LocalizedError {
        case invalidURL
        case invalidHost
        case invalidPort
        case localNetworkTargetDenied
        case invalidMethod
        case responseTooLarge
        case dnsFailed(String)
        case connectionFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "http_probe requires an absolute HTTP or HTTPS URL."
            case .invalidHost: return "A non-empty public hostname or IP address is required."
            case .invalidPort: return "port must be between 1 and 65535."
            case .localNetworkTargetDenied: return "Mobile network probes are internet-only and refuse loopback/private/local-network targets."
            case .invalidMethod: return "http_probe method must be GET or HEAD."
            case .responseTooLarge: return "The HTTP response sample exceeded the mobile probe limit."
            case .dnsFailed(let detail): return "DNS resolution failed: \(detail)"
            case .connectionFailed(let detail): return "Connection failed: \(detail)"
            case .timedOut: return "The network probe timed out."
            }
        }
    }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.xycdev.lsmmobileworker.network-path")
    private let connectionQueue = DispatchQueue(label: "com.xycdev.lsmmobileworker.network-probe")
    private var path: NWPath?
    private var history: [[String: Any]] = []

    init() {
        monitor.pathUpdateHandler = { [weak self] value in
            Task { @MainActor in
                self?.path = value
                self?.recordPath(value)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    func status() -> [String: Any] {
        guard let path else {
            return ["status": "initializing", "interfaces": []]
        }
        return snapshot(path)
    }

    func historyInfo() -> [String: Any] {
        ["items": history, "count": history.count]
    }

    func dnsProbe(_ arguments: [String: Any]) async throws -> [String: Any] {
        let host = try validatedHost(arguments)
        guard !isLocalNetworkHost(host) else { throw NetworkError.localNetworkTargetDenied }
        let start = ContinuousClock.now
        let addresses = try await resolveAddresses(host)
        let elapsed = start.duration(to: .now).milliseconds
        return [
            "host": host,
            "addresses": addresses.map { ["address": $0, "family": $0.contains(":") ? "ipv6" : "ipv4"] },
            "count": addresses.count,
            "elapsed_ms": elapsed,
        ]
    }

    func tcpProbe(_ arguments: [String: Any]) async throws -> [String: Any] {
        let host = try validatedHost(arguments)
        let port = try validatedPort(arguments)
        let timeout = boundedTimeout(arguments)
        let addresses = try await publicResolvedAddresses(host)
        let selected = addresses[0]
        let elapsed = try await connectionProbe(address: selected, port: port, serverName: nil, timeout: timeout)
        return [
            "host": host,
            "address": selected,
            "port": Int(port),
            "connected": true,
            "elapsed_ms": elapsed,
            "transport": "tcp",
        ]
    }

    func tlsProbe(_ arguments: [String: Any]) async throws -> [String: Any] {
        let host = try validatedHost(arguments)
        let port = try validatedPort(arguments, defaultPort: 443)
        let timeout = boundedTimeout(arguments)
        let addresses = try await publicResolvedAddresses(host)
        let selected = addresses[0]
        let elapsed = try await connectionProbe(address: selected, port: port, serverName: host, timeout: timeout)
        return [
            "host": host,
            "address": selected,
            "port": Int(port),
            "handshake": true,
            "elapsed_ms": elapsed,
            "transport": "tls",
        ]
    }

    func httpProbe(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let raw = arguments["url"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            throw NetworkError.invalidURL
        }
        _ = try await publicResolvedAddresses(host)
        let method = ((arguments["method"] as? String) ?? "HEAD").uppercased()
        guard method == "GET" || method == "HEAD" else { throw NetworkError.invalidMethod }
        let timeout = boundedTimeout(arguments)
        let maxSample = min(max((arguments["max_sample_bytes"] as? NSNumber)?.intValue ?? 4096, 0), 64 * 1024)
        let includeSample = (arguments["include_sample"] as? Bool) ?? false

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("LSMMobileWorker/1", forHTTPHeaderField: "User-Agent")

        let start = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        let headersMs = start.duration(to: .now).milliseconds
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidURL }
        var sample = Data()
        if method == "GET" && maxSample > 0 {
            for try await byte in bytes {
                if sample.count >= maxSample { break }
                sample.append(byte)
            }
        }
        let totalMs = start.duration(to: .now).milliseconds
        var result: [String: Any] = [
            "url": raw,
            "final_url": http.url?.absoluteString ?? raw,
            "method": method,
            "status_code": http.statusCode,
            "headers_latency_ms": headersMs,
            "elapsed_ms": totalMs,
            "content_type": http.value(forHTTPHeaderField: "Content-Type") ?? NSNull(),
            "sample_bytes": sample.count,
        ]
        if includeSample, !sample.isEmpty,
           let text = String(data: sample, encoding: .utf8) {
            result["sample_text"] = text
        }
        return result
    }

    private func recordPath(_ path: NWPath) {
        var row = snapshot(path)
        row["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let signature = "\(row["status"] ?? "")|\(row["interfaces"] ?? "")|\(row["expensive"] ?? "")|\(row["constrained"] ?? "")"
        if let last = history.last,
           last["signature"] as? String == signature {
            return
        }
        row["signature"] = signature
        history.append(row)
        if history.count > 32 { history.removeFirst(history.count - 32) }
    }

    private func snapshot(_ path: NWPath) -> [String: Any] {
        var interfaces: [String] = []
        for (name, type) in [
            ("wifi", NWInterface.InterfaceType.wifi),
            ("cellular", .cellular),
            ("wired_ethernet", .wiredEthernet),
            ("loopback", .loopback),
            ("other", .other),
        ] where path.usesInterfaceType(type) {
            interfaces.append(name)
        }
        return [
            "status": pathStatusName(path.status),
            "interfaces": interfaces,
            "expensive": path.isExpensive,
            "constrained": path.isConstrained,
            "supports_ipv4": path.supportsIPv4,
            "supports_ipv6": path.supportsIPv6,
            "supports_dns": path.supportsDNS,
        ]
    }

    private func validatedHost(_ arguments: [String: Any]) throws -> String {
        guard let raw = arguments["host"] as? String else { throw NetworkError.invalidHost }
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253 else { throw NetworkError.invalidHost }
        return host
    }

    private func validatedPort(_ arguments: [String: Any], defaultPort: UInt16? = nil) throws -> UInt16 {
        let number = arguments["port"] as? NSNumber
        if number == nil, let defaultPort { return defaultPort }
        let value = number?.intValue ?? 0
        guard (1...65_535).contains(value), let port = UInt16(exactly: value) else {
            throw NetworkError.invalidPort
        }
        return port
    }

    private func boundedTimeout(_ arguments: [String: Any]) -> TimeInterval {
        min(max((arguments["timeout_s"] as? NSNumber)?.doubleValue ?? 10, 1), 20)
    }

    private func publicResolvedAddresses(_ host: String) async throws -> [String] {
        guard !isLocalNetworkHost(host) else { throw NetworkError.localNetworkTargetDenied }
        let addresses = try await resolveAddresses(host)
        guard !addresses.isEmpty else { throw NetworkError.dnsFailed("no addresses returned") }
        guard addresses.allSatisfy({ !isLocalNetworkHost($0) }) else {
            throw NetworkError.localNetworkTargetDenied
        }
        return addresses
    }

    private func resolveAddresses(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_flags = AI_ADDRCONFIG
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP
                var result: UnsafeMutablePointer<addrinfo>?
                let code = getaddrinfo(host, nil, &hints, &result)
                guard code == 0, let first = result else {
                    let detail = code == 0 ? "no addresses returned" : String(cString: gai_strerror(code))
                    continuation.resume(throwing: NetworkError.dnsFailed(detail))
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor?.pointee {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let value = String(cString: buffer)
                        if !addresses.contains(value) { addresses.append(value) }
                    }
                    cursor = info.ai_next
                }
                if addresses.isEmpty {
                    continuation.resume(throwing: NetworkError.dnsFailed("no addresses returned"))
                } else {
                    continuation.resume(returning: addresses)
                }
            }
        }
    }

    private func connectionProbe(
        address: String,
        port: UInt16,
        serverName: String?,
        timeout: TimeInterval
    ) async throws -> Double {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NetworkError.invalidPort }
        let parameters: NWParameters
        if let serverName {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: parameters)
        let start = ContinuousClock.now
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            func finish(_ result: Result<Double, Error>) {
                guard !completed else { return }
                completed = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                self.connectionQueue.async {
                    switch state {
                    case .ready:
                        finish(.success(start.duration(to: .now).milliseconds))
                    case .failed(let error):
                        finish(.failure(NetworkError.connectionFailed(error.localizedDescription)))
                    case .cancelled:
                        finish(.failure(NetworkError.connectionFailed("cancelled")))
                    default:
                        break
                    }
                }
            }
            connection.start(queue: connectionQueue)
            connectionQueue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(NetworkError.timedOut))
            }
        }
    }

    private func isLocalNetworkHost(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value.hasSuffix(".localhost") || value.hasSuffix(".local") || value.hasSuffix(".home.arpa") {
            return true
        }
        if let address = IPv4Address(value) {
            let b = [UInt8](address.rawValue)
            guard b.count == 4 else { return true }
            return b[0] == 0 || b[0] == 10 || b[0] == 127 ||
                (b[0] == 169 && b[1] == 254) ||
                (b[0] == 172 && (16...31).contains(Int(b[1]))) ||
                (b[0] == 192 && b[1] == 168) ||
                (b[0] == 100 && (64...127).contains(Int(b[1])))
        }
        if let address = IPv6Address(value) {
            let b = [UInt8](address.rawValue)
            guard b.count == 16 else { return true }
            let unspecified = b.allSatisfy { $0 == 0 }
            let loopback = b.dropLast().allSatisfy { $0 == 0 } && b.last == 1
            let uniqueLocal = (b[0] & 0xfe) == 0xfc
            let linkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80
            return unspecified || loopback || uniqueLocal || linkLocal
        }
        return false
    }

    private func pathStatusName(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .requiresConnection: return "requires_connection"
        @unknown default: return "unknown"
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
